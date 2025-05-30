// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/*---------- IMPORT LIBRARIES & TYPES ----------*/
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

/*---------- IMPORT INTERFACES ----------*/
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IWETH} from "@yolo/contracts/interfaces/IWETH.sol";
import {IYoloOracle} from "@yolo/contracts/interfaces/IYoloOracle.sol";
import {IYoloSyntheticAsset} from "@yolo/contracts/interfaces/IYoloSyntheticAsset.sol";
import {IPoolManager, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
/*---------- IMPORT CONTRACTS ----------*/
import {YoloSyntheticAsset} from "@yolo/contracts/tokenization/YoloSyntheticAsset.sol";
/*---------- IMPORT BASE CONTRACTS ----------*/
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

/**
 * @title   YoloHook
 * @author  0xyolodev.eth
 * @notice  Function as the main entry point for user to mint collateral, repay debt, flash-loaning, as
 *          well as functioning as a UniswapV4 hook to store and manages the all of the swap logics of
 *          Yolo assets.
 * @dev     This is the V0 version of the hook, further built based on the hackathon project:
 *          https://devfolio.co/projects/yolo-protocol-univ-hook-b899
 *
 */
contract YoloHook is BaseHook, Ownable {
    // ***************** //
    // *** LIBRARIES *** //
    // ***************** //
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    // ***************** //
    // *** DATATYPES *** //
    // ***************** //

    struct AddLiquidityCallBackData {
        uint8 action; // 0 = Add Liquidity
        address sender; // User who add liquidity
        uint256 maxUsdcAmount; // Max USDC amount to add
        uint256 maxUsyAmount; // Max USY amount to add
        uint256 minLiquidity; // Minimum LP tokens to receive
    }

    struct YoloAssetConfiguration {
        address yoloAssetAddress;
        uint256 maxMintableCap; // 0 == Pause
        uint256 maxFlashLoanableAmount;
    }

    struct CollateralConfiguration {
        address collateralAsset;
        uint256 maxSupplyCap; // 0 == Pause
    }

    struct CollateralToYoloAssetConfiguration {
        address collateral;
        address yoloAsset;
        uint256 interestRate;
        uint256 ltv;
        uint256 liquidationPenalty;
    }

    struct UserPosition {
        address borrower;
        address collateral;
        uint256 collateralSuppliedAmount;
        address yoloAsset;
        uint256 yoloAssetMinted;
        uint256 lastUpdatedTimeStamp;
        uint256 storedInterestRate;
        uint256 accruedInterest;
    }

    struct UserPositionKey {
        address collateral;
        address yoloAsset;
    }

    // ******************************//
    // *** CONSTANT & IMMUTABLES *** //
    // ***************************** //
    uint256 public constant PRECISION_DIVISOR = 10000; // 100%

    // ***************************//
    // *** CONTRACT VARIABLES *** //
    // ************************** //

    address public treasury; // Address of the treasury to collect fees
    IWETH public weth;
    IYoloOracle public yoloOracle;

    /*----- Fees Configuration -----*/
    uint256 public stableSwapFee; // Swap fee for the anchor pool, in basis points (e.g., 100 = 1%)
    uint256 public syntheticSwapFee; // Swap fee for synthetic assets, in basis points (e.g., 100 = 1%)
    uint256 public flashLoanFee; // Flash loan fee for synthetic assets, in basis points (e.g., 100 = 1%)

    /*----- Anchor Pool & Stableswap Variables -----*/
    IYoloSyntheticAsset public anchor;
    address public usdc; // USDC address, used in the anchor pool to pair with USY
    bytes32 public anchorPoolId; // Anchor pool ID, used to identify the pool in the PoolManager
    mapping(bytes32 => bool) public isAnchorPool;
    uint256 public anchorPoolLiquiditySupply; // Total LP tokens for anchor pool
    mapping(address => uint256) public anchorPoolLPBalance; // User LP balances
    // mapping(address => uint256) public anchorPoolReserveUSDC; // USDC reserves
    // mapping(address => uint256) public anchorPoolReserveUSY; // USY reserves

    uint256 private USDC_SCALE_UP; // Make sure USDC is scaled up to 18 decimals

    // Anchor pool reserves
    uint256 public totalAnchorReserveUSDC;
    uint256 public totalAnchorReserveUSY;

    // Constants for stableswap math
    uint256 private constant MINIMUM_LIQUIDITY = 1000;
    uint256 private constant PRECISION = 1e18;

    /*----- Aseet & Collateral Configurations -----*/
    mapping(address => bool) public isYoloAsset; // Mapping to check if an address is a Yolo asset
    mapping(address => bool) public isWhiteListedCollateral; // Mapping to check if an address is a whitelisted collateral asset

    mapping(address => YoloAssetConfiguration) public yoloAssetConfigs; // Maps Yolo assets to its configuration
    mapping(address => CollateralConfiguration) public collateralConfigs; // Maps collateral to its configuration

    // ***************//
    // *** EVENTS *** //
    // ************** //

    event AnchorLiquidityAdded(address indexed provider, uint256 usdcAmount, uint256 usyAmount, uint256 liquidity);

    /**
     * @notice  Emitted when liquidity is added on the hook. Complies with Uniswap V4 best practice guidance.
     */
    event HookModifyLiquidity(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1);

    event AnchorLiquidityRemoved(address indexed provider, uint256 usdcAmount, uint256 usyAmount, uint256 liquidity);

    event AnchorSwapExecuted(address indexed sender, bool usdcForUSY, uint256 amountIn, uint256 amountOut, uint256 fee);

    // ***************//
    // *** ERRORS *** //
    // ************** //
    error Ownable__AlreadyInitialized();
    error YoloHook_ZeroAddress();
    error YoloHook_MustAddLiquidityThroughHook();
    error YoloHook_InvalidAddLiuidityParams();
    error YoloHook__InsufficientLiquidityMinted();
    error YoloHook_InsuficcientLiquidityBalance();
    error YoloHook__InsufficientAmount();
    error YoloHook__KInvariantViolation();

    // ********************//
    // *** CONSTRUCTOR *** //
    // ******************* //
    /**
     * @notice  Constructor to initialize the YoloProtocolHook with the V4 Pool Manager address.
     * @param   _v4PoolManager  Address of the Uniswap V4 Pool Manager contract.
     */
    constructor(address _v4PoolManager) Ownable(msg.sender) BaseHook(IPoolManager(_v4PoolManager)) {}

    /**
     * @notice  Functions as the actual constructor for the hook, complying with proxy patterns.
     * @dev     This function is called only once, during the deployment of the hook.
     * @param   _wethAddress        Address of the WETH contract.
     * @param   _treasury           Address of the treasury to collect fees.
     * @param   _yoloOracle         Address of the Yolo Oracle contract.
     * @param   _stableSwapFee      Swap fee for the anchor pool, in basis points (e.g., 100 = 1%).
     * @param   _syntheticSwapFee   Swap fee for the hook, in basis points (e.g., 100 = 1%).
     * @param   _flashLoanFee       Flash loan fee for the hook, in basis points (e.g., 100 = 1%).
     * @param   _usdc               Address of the USDC contract, used in the anchor pool.
     */
    function initialize(
        address _wethAddress,
        address _treasury,
        address _yoloOracle,
        uint256 _stableSwapFee,
        uint256 _syntheticSwapFee,
        uint256 _flashLoanFee,
        address _usdc
    ) external {
        // Guard clause: ensure that the addresses are not zero
        if (_wethAddress == address(0) || _treasury == address(0) || _yoloOracle == address(0) || _usdc == address(0)) {
            revert YoloHook_ZeroAddress();
        }
        if (owner() != address(0)) revert Ownable__AlreadyInitialized();
        _transferOwnership(msg.sender);
        // Initialize the BaseHook with paramaters
        weth = IWETH(_wethAddress);
        treasury = _treasury;
        yoloOracle = IYoloOracle(_yoloOracle);
        stableSwapFee = _stableSwapFee;
        syntheticSwapFee = _syntheticSwapFee;
        flashLoanFee = _flashLoanFee;
        usdc = _usdc;

        // Determine USDC scale factor
        uint8 usdcDecimals = IERC20Metadata(_usdc).decimals();
        USDC_SCALE_UP = 10 ** (18 - usdcDecimals);

        // Create the anchor synthetic asset (USY)
        anchor = IYoloSyntheticAsset(address(new YoloSyntheticAsset("Yolo USD", "USY", 18)));

        // Initialize the anchor asset configuration
        yoloAssetConfigs[address(anchor)] = YoloAssetConfiguration(address(anchor), 0, 0); // Initialize with 0 cap

        // Initialize the WETH collateral configuration
        isWhiteListedCollateral[_wethAddress] = true;
        collateralConfigs[_wethAddress] = CollateralConfiguration(_wethAddress, 0); // Initialize with 0 cap

        /*----- Initialize Anchor Pool on Pool Manager -----*/

        // Sort the tokens for the anchor pool
        address tokenA = address(usdc);
        address tokenB = address(anchor);
        bool usdcIs0 = tokenA < tokenB;
        Currency c0 = Currency.wrap(usdcIs0 ? tokenA : tokenB);
        Currency c1 = Currency.wrap(usdcIs0 ? tokenB : tokenA);

        PoolKey memory pk =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(this))});
        poolManager.initialize(pk, uint160(1) << 96);
        anchorPoolId = PoolId.unwrap(pk.toId());
        isAnchorPool[PoolId.unwrap(pk.toId())] = true;
    }

    // ***************************** //
    // *** USER FACING FUNCTIONS *** //
    // ***************************** //

    // ******************************//
    // *** ANCHOR POOL FUNCTIONS *** //
    // ***************************** //

    // ******************************//
    // *** ANCHOR POOL FUNCTIONS *** //
    // ***************************** //
    /**
     * @notice  Add liquidity to the anchor pool pair (USDC/USY) with ratio enforcement
     * @param   _maxUsdcAmount Maximum USDC amount user wants to add
     * @param   _maxUsyAmount Maximum USY amount user wants to add
     * @param   _minLiquidityReceive Minimum LP tokens to receive
     */
    function addLiquidity(uint256 _maxUsdcAmount, uint256 _maxUsyAmount, uint256 _minLiquidityReceive)
        external
        returns (uint256 usdcUsed, uint256 usyUsed, uint256 liquidityMinted)
    {
        // Guard clause: ensure that the amounts are greater than zero
        if (_maxUsdcAmount == 0 || _maxUsyAmount == 0) revert YoloHook_InvalidAddLiuidityParams();

        // Call the PoolManater to unlock with AddLiquidityCallBackData
        bytes memory data = poolManager.unlock(
            abi.encode(AddLiquidityCallBackData(0, msg.sender, _maxUsdcAmount, _maxUsyAmount, _minLiquidityReceive))
        );

        // Decode the callback data to get the actual amounts used and liquidity minted
        (address sender, usdcUsed, usyUsed, liquidityMinted) = abi.decode(data, (address, uint256, uint256, uint256));

        // Emit Hook Event
        emit HookModifyLiquidity(
            anchorPoolId,
            sender,
            int128(int256(usdcUsed)), // Convert to int128 for PoolManager
            int128(int256(usyUsed)) // Convert to int128 for PoolManager
        );

        return (usdcUsed, usyUsed, liquidityMinted);
    }

    function unlockCallback(bytes calldata _callbackData) external onlyPoolManager returns (bytes memory) {
        // Decode the callback data
        AddLiquidityCallBackData memory data = abi.decode(_callbackData, (AddLiquidityCallBackData));

        address sender = data.sender;
        uint256 maxUsdcAmountInWad = _toWadUSDC(data.maxUsdcAmount); // Convert raw USDC to WAD (18 decimals)
        uint256 maxUsyAmountInWad = data.maxUsyAmount; // USY is already in 18 decimals
        uint256 minLiquidity = data.minLiquidity; // Minimum LP tokens to receive

        uint256 usdcUsed;
        uint256 usdcUsedInWad;
        uint256 usyUsed;
        uint256 usyUsedInWad;
        uint256 liquidity;

        if (anchorPoolLiquiditySupply == 0) {
            // If first time adding liquidity, ensure that the liquidity ratio is 1:1

            // Check and use the smaller of the two amounts
            usdcUsedInWad = maxUsdcAmountInWad > maxUsyAmountInWad ? maxUsyAmountInWad : maxUsdcAmountInWad; // Use the smaller of the two amounts
            usyUsedInWad = usdcUsedInWad; // Use the same amount for USY

            // Calculate liquidity using the square root formula
            liquidity = _sqrt(usdcUsedInWad * usyUsedInWad) - MINIMUM_LIQUIDITY; // Calculate liquidity

            // Ensure that the liquidity is above the minimum threshold
            if (liquidity < minLiquidity) revert YoloHook__InsufficientLiquidityMinted();

            // Update the anchor pool state
            anchorPoolLiquiditySupply = liquidity + MINIMUM_LIQUIDITY; // Update the total supply of LP tokens
            // totalAnchorReserveUSDC += _fromWadUSDC(usdcUsedInWad); // Update USDC reserve
            // totalAnchorReserveUSY += usyUsedInWad; // Update USY reserve

            usdcUsed = _fromWadUSDC(usdcUsedInWad); // Convert WAD USDC back to raw USDC
            usyUsed = usyUsedInWad; // USY is already in raw format

            anchorPoolLPBalance[address(0)] += MINIMUM_LIQUIDITY; // Assign the minimum liquidity to a dummy address (0) for first time liquidity provision
        } else {
            // If not first time, ensure that the liquidity used is optimal according to the proportions
            uint256 totalReserveUsdcInWad = _toWadUSDC(totalAnchorReserveUSDC);
            uint256 totalReserveUsyInWad = totalAnchorReserveUSY;

            // Calculate required amounts to maintain ratio
            uint256 usdcRequiredInWad =
                (maxUsyAmountInWad * totalReserveUsdcInWad + totalReserveUsyInWad - 1) / totalReserveUsyInWad;
            uint256 usyRequiredInWad =
                (maxUsdcAmountInWad * totalReserveUsyInWad + totalReserveUsdcInWad - 1) / totalReserveUsdcInWad;

            if (usdcRequiredInWad <= maxUsdcAmountInWad) {
                // USY is the limiting factor
                // usdcUsed = _fromWadUSDC(usdcRequiredInWad);
                usdcUsed = (usdcRequiredInWad + USDC_SCALE_UP - 1) / USDC_SCALE_UP; // Round up to ensure we use enough USDC
                usyUsed = maxUsyAmountInWad; // Use the full USY amount
            } else {
                // USDC is the limiting factor
                // usdcUsed = _fromWadUSDC(maxUsdcAmountInWad); // Use the full USDC amount
                usdcUsed = (maxUsdcAmountInWad + USDC_SCALE_UP - 1) / USDC_SCALE_UP;

                usyUsed = usyRequiredInWad; // Use the required USY amount
            }

            // Calculate liquidity using the square root formula
            uint256 lp0 = _toWadUSDC(usdcUsed) * anchorPoolLiquiditySupply / totalReserveUsdcInWad;
            uint256 lp1 = usyUsed * anchorPoolLiquiditySupply / totalReserveUsyInWad;
            liquidity = lp0 < lp1 ? lp0 : lp1; // Use the minimum of the two calculations

            // Ensure that the liquidity is above the minimum threshold
            if (liquidity < minLiquidity) revert YoloHook__InsufficientLiquidityMinted();
            // Update the anchor pool state
            anchorPoolLiquiditySupply += liquidity; // Update the total supply of LP tokens
        }

        // Pull tokens from user and update hook's claims
        Currency cUSDC = Currency.wrap(usdc);
        Currency cUSY = Currency.wrap(address(anchor));

        // Settle = user pays tokens to PoolManager
        cUSDC.settle(poolManager, sender, usdcUsed, false);
        cUSY.settle(poolManager, sender, usyUsed, false);

        // Take = hook claims the tokens from PoolManager
        cUSDC.take(poolManager, address(this), usdcUsed, true);
        cUSY.take(poolManager, address(this), usyUsed, true);

        // Update state
        totalAnchorReserveUSDC += usdcUsed; // raw USDC (6-dec)
        totalAnchorReserveUSY += usyUsed; // USY (18-dec)
        anchorPoolLPBalance[sender] += liquidity;

        // Emit event
        emit AnchorLiquidityAdded(sender, usdcUsed, usyUsed, liquidity);

        return abi.encode(sender, usdcUsed, usyUsed, liquidity);
    }

    /**
     * @notice  Add liquidity to the anchor pool pair (USDC/USY) with ratio enforcement
     * @param   _usdcAmount Maximum USDC amount user wants to add
     * @param   _usyAmount Maximum USY amount user wants to add
     * @param   _minLiquidity Minimum LP tokens to receive
     */
    function addAnchorLiquidity(uint256 _usdcAmount, uint256 _usyAmount, uint256 _minLiquidity)
        external
        returns (uint256 liquidity, uint256 usdcUsed, uint256 usyUsed)
    {
        // Guard clause: ensure that the amounts are greater than zero
        if (_usdcAmount == 0 || _usyAmount == 0) revert YoloHook_InvalidAddLiuidityParams();

        uint256 wadResUsdc = _toWadUSDC(totalAnchorReserveUSDC); // 18-dec view
        uint256 wadResUsy = totalAnchorReserveUSY; // already 18-dec

        if (anchorPoolLiquiditySupply == 0) {
            usdcUsed = _usdcAmount; // raw (6-dec)
            usyUsed = _usyAmount; // raw (18-dec)
            liquidity = _sqrt(_toWadUSDC(usdcUsed) * usyUsed) - MINIMUM_LIQUIDITY;
            anchorPoolLiquiditySupply = liquidity + MINIMUM_LIQUIDITY;
        } else {
            // round-up helpers
            uint256 usdcReq = (_usyAmount * wadResUsdc + wadResUsy - 1) / wadResUsy;
            uint256 usyReq = (_usdcAmount * wadResUsy + wadResUsdc - 1) / wadResUsdc;

            if (usdcReq <= _usdcAmount) {
                // USY limited
                usdcUsed = usdcReq;
                usyUsed = _usyAmount;
            } else {
                usdcUsed = _usdcAmount;
                usyUsed = usyReq;
            }

            // ---------- 2. LP mint (min of the two) ----------
            uint256 lp0 = _toWadUSDC(usdcUsed) * anchorPoolLiquiditySupply / wadResUsdc;
            uint256 lp1 = usyUsed * anchorPoolLiquiditySupply / wadResUsy;
            liquidity = lp0 < lp1 ? lp0 : lp1;
            anchorPoolLiquiditySupply += liquidity;
        }

        if (liquidity < _minLiquidity) revert YoloHook__InsufficientLiquidityMinted();

        // ---------- 3. pull tokens & mint claim ----------
        Currency cUSDC = Currency.wrap(usdc);
        Currency cUSY = Currency.wrap(address(anchor));

        cUSDC.settle(poolManager, msg.sender, usdcUsed, false);
        cUSDC.take(poolManager, address(this), usdcUsed, true);

        cUSY.settle(poolManager, msg.sender, usyUsed, false);
        cUSY.take(poolManager, address(this), usyUsed, true);

        // ---------- 4. book-keeping ----------
        totalAnchorReserveUSDC += usdcUsed; // raw 6-dec
        totalAnchorReserveUSY += usyUsed; // 18-dec
        anchorPoolLPBalance[msg.sender] += liquidity;

        emit AnchorLiquidityAdded(msg.sender, usdcUsed, usyUsed, liquidity);

        // uint256 _totalSupply = anchorPoolLiquiditySupply;

        // if (_totalSupply == 0) {
        //     // First liquidity provision - use both amounts as provided
        //     usdcUsed = _usdcAmount;
        //     usyUsed = _usyAmount;
        //     liquidity = _sqrt(_toWadUSDC(_usdcAmount) * _usyAmount) - MINIMUM_LIQUIDITY;
        //     anchorPoolLiquiditySupply = liquidity + MINIMUM_LIQUIDITY;
        // } else {
        //     // Add safety check for zero reserves
        //     if (totalAnchorReserveUSDC == 0 || totalAnchorReserveUSY == 0) {
        //         revert YoloHook_InsuficcientLiquidityBalance();
        //     }

        //     // Calculate optimal amounts with rounding that benefits the pool
        //     // Round UP the required amounts to ensure pool gets slightly more
        //     uint256 usdcRequired =
        //         (_usyAmount * _toWadUSDC(totalAnchorReserveUSDC) + totalAnchorReserveUSY - 1) / totalAnchorReserveUSY;
        //     uint256 usyRequired =
        //         (_usdcAmount * totalAnchorReserveUSY + _toWadUSDC(totalAnchorReserveUSDC) - 1) /_toWadUSDC(totalAnchorReserveUSDC);

        //     if (usdcRequired <= _usdcAmount) {
        //         // USY is the limiting factor
        //         usdcUsed = usdcRequired;
        //         usyUsed = _usyAmount;
        //     } else {
        //         // USDC is the limiting factor
        //         usdcUsed = _usdcAmount;
        //         usyUsed = usyRequired;
        //     }

        //     // ✅ FIXED: Calculate liquidity with rounding DOWN to benefit pool
        //     // User gets slightly fewer LP tokens
        //     liquidity = (usdcUsed * _totalSupply) / totalAnchorReserveUSDC;
        //     anchorPoolLiquiditySupply += liquidity;
        // }

        // if (liquidity < _minLiquidity) revert YoloHook__InsufficientLiquidityMinted();

        // // Create currency objects
        // Currency usdcCurrency = Currency.wrap(usdc);
        // Currency usyCurrency = Currency.wrap(address(anchor));

        // // Pull only the required amounts from user
        // usdcCurrency.settle(poolManager, msg.sender, usdcUsed, false);
        // usdcCurrency.take(poolManager, address(this), usdcUsed, true);
        // usyCurrency.settle(poolManager, msg.sender, usyUsed, false);
        // usyCurrency.take(poolManager, address(this), usyUsed, true);

        // // Update reserves with actual amounts used
        // totalAnchorReserveUSDC += usdcUsed;
        // totalAnchorReserveUSY += usyUsed;

        // // Update user balance
        // anchorPoolLPBalance[msg.sender] += liquidity;

        // emit AnchorLiquidityAdded(msg.sender, usdcUsed, usyUsed, liquidity);
    }

    /**
     * @notice  Remove liquidity from the anchor pool
     * @param   _liquidity  Amount of LP tokens to burn
     * @param   _minUSDC    Minimum USDC to receive
     * @param   _minUSY     Minimum USY to receive
     */
    function removeAnchorLiquidity(uint256 _liquidity, uint256 _minUSDC, uint256 _minUSY)
        external
        returns (uint256 usdcAmount, uint256 usyAmount)
    {
        if (_liquidity == 0) revert YoloHook_InvalidAddLiuidityParams();

        // Check user has enough LP tokens
        if (anchorPoolLPBalance[msg.sender] < _liquidity) revert YoloHook_InsuficcientLiquidityBalance();

        if (anchorPoolLiquiditySupply == 0) revert YoloHook_InsuficcientLiquidityBalance();

        // Calculate proportional amounts with rounding DOWN to benefit pool
        // User gets slightly less, pool keeps the dust
        usdcAmount = (_liquidity * totalAnchorReserveUSDC) / anchorPoolLiquiditySupply;
        usyAmount = (_liquidity * totalAnchorReserveUSY) / anchorPoolLiquiditySupply;

        if (usdcAmount < _minUSDC || usyAmount < _minUSY) revert YoloHook__InsufficientAmount();

        // Update state
        anchorPoolLPBalance[msg.sender] -= _liquidity;
        anchorPoolLiquiditySupply -= _liquidity;
        totalAnchorReserveUSDC -= usdcAmount;
        totalAnchorReserveUSY -= usyAmount;

        // Transfer tokens back to user using PoolManager's accounting systems
        Currency usdcCurrency = Currency.wrap(usdc);
        Currency usyCurrency = Currency.wrap(address(anchor));

        usdcCurrency.settle(poolManager, address(this), usdcAmount, true);
        usyCurrency.settle(poolManager, address(this), usyAmount, true);
        // For USDC: Burn our claim tokens and give real USDC to user
        usdcCurrency.take(poolManager, msg.sender, usdcAmount, false);
        // For USY: Burn our claim tokens and give real USY to user
        usyCurrency.take(poolManager, msg.sender, usyAmount, false);

        emit AnchorLiquidityRemoved(msg.sender, usdcAmount, usyAmount, _liquidity);
    }

    // ***********************//
    // *** HOOK FUNCTIONS *** //
    // ********************** //
    /**
     * @notice  Returns the permissions for this hook.
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true, // Blocks directly adding liquidity
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: true,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    /**
     * @notice  Revert to avoid directly adding liquidity to the PoolManager.
     */
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        // Guard clause: revert if someone tries to add liquidity directly on PoolManager
        revert YoloHook_MustAddLiquidityThroughHook();
    }

    // ***********************//
    // *** VIEW FUNCTIONS *** //
    // ********************** //
    /**
     * @notice Get anchor pool reserves
     */
    function getAnchorReserves() external view returns (uint256 usdcReserve, uint256 usyReserve) {
        return (totalAnchorReserveUSDC, totalAnchorReserveUSY);
    }

    /**
     * @notice  Calculate optimal liquidity amounts (view function)
     * @param   _usdcAmount  Max USDC user wants to provide
     * @param   _usyAmount   Max USY user wants to provide
     * @return  usdcUsed    Actual USDC that will be used
     * @return  usyUsed     Actual USY that will be used
     * @return  liquidity   LP tokens that will be minted
     */
    function calculateOptimalLiquidity(uint256 _usdcAmount, uint256 _usyAmount)
        external
        view
        returns (uint256 usdcUsed, uint256 usyUsed, uint256 liquidity)
    {
        return _quoteAdd(_usdcAmount, _usyAmount);
        // if (anchorPoolLiquiditySupply == 0) {
        //     // First liquidity provision
        //     usdcUsed = _usdcAmount;
        //     usyUsed = _usyAmount;
        //     liquidity = _sqrt(_toWadUSDC(_usdcAmount) * _usyAmount) - MINIMUM_LIQUIDITY;
        // } else {
        //     // Add safety check and proper rounding
        //     if (totalAnchorReserveUSDC == 0 || totalAnchorReserveUSY == 0) {
        //         return (0, 0, 0);
        //     }

        //     // Calculate optimal amounts with rounding UP (user pays slightly more)
        //     uint256 usdcRequired =
        //         (_usyAmount * totalAnchorReserveUSDC + totalAnchorReserveUSY - 1) / totalAnchorReserveUSY;
        //     uint256 usyRequired =
        //         (_usdcAmount * totalAnchorReserveUSY + totalAnchorReserveUSDC - 1) / totalAnchorReserveUSDC;

        //     if (usdcRequired <= _usdcAmount) {
        //         // USY is the limiting factor
        //         usdcUsed = usdcRequired;
        //         usyUsed = _usyAmount;
        //     } else {
        //         // USDC is the limiting factor
        //         usdcUsed = _usdcAmount;
        //         usyUsed = usyRequired;
        //     }

        //     // Calculate liquidity with rounding DOWN (user gets slightly fewer LP tokens)
        //     liquidity = (usdcUsed * anchorPoolLiquiditySupply) / totalAnchorReserveUSDC;
        // }
    }

    // ***************************//
    // *** INTERNAL FUNCTIONS *** //
    // ************************** //
    function _quoteAdd(uint256 rawUsdc, uint256 usy)
        internal
        view
        returns (uint256 usdcOut, uint256 usyOut, uint256 lpOut)
    {
        if (anchorPoolLiquiditySupply == 0) {
            usdcOut = rawUsdc;
            usyOut = usy;
            lpOut = _sqrt(_toWadUSDC(usdcOut) * usyOut) - MINIMUM_LIQUIDITY;
        } else {
            uint256 wadResUsdc = _toWadUSDC(totalAnchorReserveUSDC);
            uint256 wadResUsy = totalAnchorReserveUSY;

            uint256 usdcReq = (usy * wadResUsdc + wadResUsy - 1) / wadResUsy;
            uint256 usyReq = (rawUsdc * wadResUsy + wadResUsdc - 1) / wadResUsdc;

            if (usdcReq <= rawUsdc) {
                usdcOut = usdcReq;
                usyOut = usy;
            } else {
                usdcOut = rawUsdc;
                usyOut = usyReq;
            }

            uint256 lp0 = _toWadUSDC(usdcOut) * anchorPoolLiquiditySupply / wadResUsdc;
            uint256 lp1 = usyOut * anchorPoolLiquiditySupply / wadResUsy;
            lpOut = lp0 < lp1 ? lp0 : lp1;
        }
    }

    /**
     * @notice Square root function for liquidity calculation
     */
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        // initial guess: (x >> 1) + 1  ==  ceil(x/2)
        uint256 z = (x >> 1) + 1;
        uint256 y = x;
        unchecked {
            while (z < y) {
                y = z;
                z = (x / z + z) >> 1; // same as /2, slightly cheaper
            }
        }
        return y; // floor(sqrt(x))
    }

    /**
     * @notice Convert raw USDC amount to WAD (18 decimals)
     */
    function _toWadUSDC(uint256 _raw) internal view returns (uint256) {
        return _raw * USDC_SCALE_UP;
    }

    /**
     * @notice Convert WAD (18 decimals) to raw USDC's native decimals (usually 6 decimals)
     */
    function _fromWadUSDC(uint256 _wad) internal view returns (uint256) {
        return _wad / USDC_SCALE_UP;
    }
}
