// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/*---------- IMPORT LIBRARIES & TYPES ----------*/
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
/*---------- IMPORT INTERFACES ----------*/
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IWETH} from "@yolo/contracts/interfaces/IWETH.sol";
import {IYoloOracle} from "@yolo/contracts/interfaces/IYoloOracle.sol";
import {IYoloSyntheticAsset} from "@yolo/contracts/interfaces/IYoloSyntheticAsset.sol";
import {IPoolManager, ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
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

    /**
     * @notice  Callback data structure for the hook to handle different actions
     */
    struct CallbackData {
        uint8 action; // 0 = Add Liquidity, 1 = Remove Liquidity
        bytes data;
    }

    struct AddLiquidityCallbackData {
        address sender; // User who add liquidity
        address receiver; // User receive the LP tokens
        uint256 usdcUsed;
        uint256 usyUsed;
        uint256 liquidity; // LP tokens minted
    }

    struct RemoveLiquidityCallbackData {
        address initiator; // User who remove liquidity
        address receiver; // User receive the USDC and USY
        uint256 usdcAmount;
        uint256 usyAmount;
        uint256 liquidity; // LP tokens burnt
    }

    struct SwapCallbackData {
        address sender;
        address tokenIn;
        uint256 amountInFromUser;
        address tokenOut;
        uint256 amountOutToUser;
        bool zeroForOne;
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
    address public swapRouter;

    /*----- Fees Configuration -----*/
    uint256 public stableSwapFee; // Swap fee for the anchor pool, in basis points (e.g., 100 = 1%)
    uint256 public syntheticSwapFee; // Swap fee for synthetic assets, in basis points (e.g., 100 = 1%)
    uint256 public flashLoanFee; // Flash loan fee for synthetic assets, in basis points (e.g., 100 = 1%)

    /*----- Anchor Pool & Stableswap Variables -----*/
    IYoloSyntheticAsset public anchor;
    address public usdc; // USDC address, used in the anchor pool to pair with USY
    bytes32 public anchorPoolId; // Anchor pool ID, used to identify the pool in the PoolManager
    address public anchorPoolToken0; // Token0 address of the anchor pool, set in initialize
    address public anchorPoolToken1; // Token1 address of the anchor pool, set in initialize

    mapping(bytes32 => bool) public isAnchorPool;
    uint256 public anchorPoolLiquiditySupply; // Total LP tokens for anchor pool
    mapping(address => uint256) public anchorPoolLPBalance; // User LP balances

    /*----- Synthetic Pools -----*/
    mapping(bytes32 => bool) public isSyntheticPool;

    uint256 private USDC_SCALE_UP; // Make sure USDC is scaled up to 18 decimals

    // Anchor pool reserves
    uint256 public totalAnchorReserveUSDC;
    uint256 public totalAnchorReserveUSY;

    // Constants for stableswap math
    uint256 private constant MINIMUM_LIQUIDITY = 1000;
    uint256 private constant MATH_PRECISION = 1e18;
    uint8 private constant STABLESWAP_ITERATIONS = 255; // Maximum iterations for stable swap Newton-Raphson method

    /*----- Aseet & Collateral Configurations -----*/
    mapping(address => bool) public isYoloAsset; // Mapping to check if an address is a Yolo asset
    mapping(address => bool) public isWhiteListedCollateral; // Mapping to check if an address is a whitelisted collateral asset

    mapping(address => YoloAssetConfiguration) public yoloAssetConfigs; // Maps Yolo assets to its configuration
    mapping(address => CollateralConfiguration) public collateralConfigs; // Maps collateral to its configuration

    // ***************//
    // *** EVENTS *** //
    // ************** //

    /**
     * @notice  Emitted when liquidity is added or removed from the hook. Complies with Uniswap V4 best practice guidance.
     */
    event HookModifyLiquidity(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1);

    event AnchorLiquidityAdded(
        address indexed sender,
        address indexed receiver,
        uint256 usdcAmount,
        uint256 usyAmount,
        uint256 liquidityMintedToUser
    );

    event AnchorLiquidityRemoved(
        address indexed sender, address indexed receiver, uint256 usdcAmount, uint256 usyAmount, uint256 liquidityBurned
    );

    event AnchorSwapExecuted(
        bytes32 indexed poolId,
        address indexed sender,
        address indexed receiver,
        bool zeroForOne,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut,
        uint256 feeAmount
    );

    // ***************//
    // *** ERRORS *** //
    // ************** //
    error Ownable__AlreadyInitialized();
    error YoloHook__ZeroAddress();
    error YoloHook__MustAddLiquidityThroughHook();
    error YoloHook__InvalidAddLiuidityParams();
    error YoloHook__InsufficientLiquidityMinted();
    error YoloHook__InsufficientLiquidityBalance();
    error YoloHook__InsufficientAmount();
    error YoloHook__KInvariantViolation();
    error YoloHook__UnknownUnlockActionError();
    error YoloHook__InvalidPoolId();
    error YoloHook__InsufficientReserves();
    error YoloHook__MathOverflow();
    error YoloHook__StableswapConvergenceError();
    error YoloHook__InvalidOutput();
    error YoloHook__InvalidSwapAmounts();

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
     * @param   _usdcAddress        Address of the USDC contract, used in the anchor pool.
     */
    function initialize(
        address _wethAddress,
        address _treasury,
        address _yoloOracle,
        uint256 _stableSwapFee,
        uint256 _syntheticSwapFee,
        uint256 _flashLoanFee,
        address _usdcAddress
    ) external {
        // Guard clause: ensure that the addresses are not zero
        if (
            _wethAddress == address(0) || _treasury == address(0) || _yoloOracle == address(0)
                || _usdcAddress == address(0)
        ) {
            revert YoloHook__ZeroAddress();
        }

        // For proxy's owner initialization
        if (owner() != address(0)) revert Ownable__AlreadyInitialized();
        _transferOwnership(msg.sender);

        // Initialize the BaseHook with paramaters
        weth = IWETH(_wethAddress);
        treasury = _treasury;
        yoloOracle = IYoloOracle(_yoloOracle);
        stableSwapFee = _stableSwapFee;
        syntheticSwapFee = _syntheticSwapFee;
        flashLoanFee = _flashLoanFee;
        usdc = _usdcAddress;

        // Determine USDC scale factor
        uint8 usdcDecimals = IERC20Metadata(_usdcAddress).decimals();
        USDC_SCALE_UP = 10 ** (18 - usdcDecimals);

        // Create the anchor synthetic asset (USY)
        anchor = IYoloSyntheticAsset(address(new YoloSyntheticAsset("Yolo USD", "USY", 18)));

        // Initialize the anchor asset configuration
        yoloAssetConfigs[address(anchor)] = YoloAssetConfiguration(address(anchor), 0, 0); // Initialize with 0 cap

        // Initialize the WETH collateral configuration
        isWhiteListedCollateral[_wethAddress] = true;
        collateralConfigs[_wethAddress] = CollateralConfiguration(_wethAddress, 0); // Initialize with 0 cap

        /*----- Initialize Anchor Pool on Pool Manager -----*/

        address tokenA = usdc;
        address tokenB = address(anchor);

        // Sort the tokens for the anchor pool
        Currency c0;
        Currency c1;
        if (tokenA < tokenB) {
            c0 = Currency.wrap(tokenA);
            c1 = Currency.wrap(tokenB);
            anchorPoolToken0 = tokenA;
            anchorPoolToken1 = tokenB;
        } else {
            c0 = Currency.wrap(tokenB);
            c1 = Currency.wrap(tokenA);
            anchorPoolToken0 = tokenB;
            anchorPoolToken1 = tokenA;
        }

        // Initialize the anchor pool with the sorted tokens and fee
        PoolKey memory pk =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(this))});
        // let PM burn any USDC or USY claim-tokens we mint later
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
    /**
     * @notice  Add liquidity to the anchor pool pair (USDC/USY) with ratio enforcement
     * @param   _maxUsdcAmount Maximum USDC amount user wants to add
     * @param   _maxUsyAmount Maximum USY amount user wants to add
     * @param   _minLiquidityReceive Minimum LP tokens to receive
     */
    function addLiquidity(
        uint256 _maxUsdcAmount,
        uint256 _maxUsyAmount,
        uint256 _minLiquidityReceive,
        address _receiver
    )
        external
        returns (uint256 actualUsdcUsed, uint256 actualUsyUsed, uint256 actualLiquidityMinted, address actualReceiver)
    {
        // Guard clause: ensure that the amounts are greater than zero, and the receiver is not zero address
        if (_maxUsdcAmount == 0 || _maxUsyAmount == 0 || _receiver == address(0)) {
            revert YoloHook__InvalidAddLiuidityParams();
        }
        uint256 maxUsdcAmountInWad = _toWadUSDC(_maxUsdcAmount); // Convert raw USDC to WAD (18 decimals)
        uint256 maxUsyAmountInWad = _maxUsyAmount; // USY is already in 18 decimals

        uint256 usdcUsed;
        uint256 usdcUsedInWad;
        uint256 usyUsed;
        uint256 usyUsedInWad;
        uint256 liquidity;

        if (anchorPoolLiquiditySupply == 0) {
            // CASE A: If first time adding liquidity, ensure that the liquidity ratio is 1:1

            // Check and use the smaller of the two amounts
            usdcUsedInWad = maxUsdcAmountInWad > maxUsyAmountInWad ? maxUsyAmountInWad : maxUsdcAmountInWad; // Use the smaller of the two amounts
            usyUsedInWad = usdcUsedInWad; // Use the same amount for USY

            // Calculate liquidity using the square root formula
            liquidity = _sqrt(usdcUsedInWad * usyUsedInWad) - MINIMUM_LIQUIDITY; // Calculate liquidity

            // Ensure that the liquidity is above the minimum requirement
            if (liquidity < _minLiquidityReceive) revert YoloHook__InsufficientLiquidityMinted();

            // anchorPoolLiquiditySupply = liquidity + MINIMUM_LIQUIDITY; // Update the total supply of LP tokens
            // anchorPoolLPBalance[address(0)] += MINIMUM_LIQUIDITY; // Assign the minimum liquidity to a dummy address (0) for first time liquidity provision

            usdcUsed = _fromWadUSDC(usdcUsedInWad); // Convert WAD USDC back to raw USDC
            usyUsed = usyUsedInWad; // USY is already in raw format
        } else {
            // CASE B: If not first time, ensure that the liquidity used is optimal according to the proportions
            uint256 totalReserveUsdcInWad = _toWadUSDC(totalAnchorReserveUSDC);
            uint256 totalReserveUsyInWad = totalAnchorReserveUSY;

            // Calculate required amounts to maintain ratio
            uint256 usdcRequiredInWad =
                (maxUsyAmountInWad * totalReserveUsdcInWad + totalReserveUsyInWad - 1) / totalReserveUsyInWad;
            uint256 usyRequiredInWad =
                (maxUsdcAmountInWad * totalReserveUsyInWad + totalReserveUsdcInWad - 1) / totalReserveUsdcInWad;

            if (usdcRequiredInWad <= maxUsdcAmountInWad) {
                // USY is the limiting factor
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
            if (liquidity < _minLiquidityReceive) revert YoloHook__InsufficientLiquidityMinted();

            // Update the anchor pool state
            // anchorPoolLiquiditySupply += liquidity; // Update the total supply of LP tokens
        }

        // Call the PoolManager to unlock and execute accounting settlement
        bytes memory data = poolManager.unlock(
            abi.encode(
                CallbackData(
                    0, abi.encode(AddLiquidityCallbackData(msg.sender, _receiver, usdcUsed, usyUsed, liquidity))
                )
            )
        );

        // Decode the callback data to get the actual amounts used and liquidity minted
        (
            address sender,
            address receiver,
            uint256 _actualUsdcUsed,
            uint256 _actualUsyUsed,
            uint256 _actualLiquidityMinted
        ) = abi.decode(data, (address, address, uint256, uint256, uint256));

        // Emit Hook Event
        if (anchorPoolToken0 == usdc) {
            emit HookModifyLiquidity(
                anchorPoolId, _receiver, int128(int256(_actualUsdcUsed)), int128(int256(_actualUsyUsed))
            );
        } else {
            // anchorPoolToken0 is USY
            emit HookModifyLiquidity(
                anchorPoolId, _receiver, int128(int256(_actualUsyUsed)), int128(int256(_actualUsdcUsed))
            );
        }

        return (_actualUsdcUsed, _actualUsyUsed, _actualLiquidityMinted, receiver);
    }

    function unlockCallback(bytes calldata _callbackData) external onlyPoolManager returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(_callbackData, (CallbackData));
        uint8 action = callbackData.action;

        if (action == 0) {
            // CASE A: Add Liquidity
            AddLiquidityCallbackData memory data = abi.decode(callbackData.data, (AddLiquidityCallbackData));
            address sender = data.sender;
            address receiver = data.receiver; // Receiver of LP tokens, not used in this hook
            uint256 usdcUsed = data.usdcUsed; // USDC used in raw format
            uint256 usyUsed = data.usyUsed; // USY used in raw format
            uint256 liquidity = data.liquidity; // LP tokens minted

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

            if (anchorPoolLiquiditySupply == 0) {
                anchorPoolLPBalance[address(0)] += MINIMUM_LIQUIDITY;
                anchorPoolLPBalance[receiver] += liquidity;
                anchorPoolLiquiditySupply = liquidity + MINIMUM_LIQUIDITY; // Set initial liquidity supply
            } else {
                anchorPoolLPBalance[receiver] += liquidity;
                anchorPoolLiquiditySupply += liquidity;
            }
            emit AnchorLiquidityAdded(sender, receiver, usdcUsed, usyUsed, liquidity);

            return abi.encode(sender, receiver, usdcUsed, usyUsed, liquidity);
        } else if (action == 1) {
            // CASE B: Remove Liquidity
            RemoveLiquidityCallbackData memory data = abi.decode(callbackData.data, (RemoveLiquidityCallbackData));
            address initiator = data.initiator; // User who initiated the removal
            address receiver = data.receiver; // User who receives the USDC and USY
            uint256 usdcAmount = data.usdcAmount; // USDC amount to return
            uint256 usyAmount = data.usyAmount; // USY amount to return
            uint256 liquidity = data.liquidity; // LP tokens burnt

            // Update state
            anchorPoolLPBalance[initiator] -= liquidity;
            anchorPoolLiquiditySupply -= liquidity;
            totalAnchorReserveUSDC -= usdcAmount;
            totalAnchorReserveUSY -= usyAmount;

            // Transfer tokens back to user using PoolManager's accounting systems
            Currency usdcCurrency = Currency.wrap(usdc);
            Currency usyCurrency = Currency.wrap(address(anchor));

            usdcCurrency.settle(poolManager, address(this), usdcAmount, true);
            usyCurrency.settle(poolManager, address(this), usyAmount, true);

            // For USDC: Burn our claim tokens and give real USDC to user
            usdcCurrency.take(poolManager, receiver, usdcAmount, false);
            // For USY: Burn our claim tokens and give real USY to user
            usyCurrency.take(poolManager, receiver, usyAmount, false);

            emit AnchorLiquidityRemoved(initiator, receiver, usdcAmount, usyAmount, liquidity);

            return abi.encode(initiator, receiver, usdcAmount, usyAmount, liquidity);

            // } else if (action == 2) {
            //     // Case C: Anchor Swap

            //     SwapCallbackData memory data = abi.decode(callbackData.data, (SwapCallbackData));

            //     Currency cIn = Currency.wrap(data.tokenIn);
            //     Currency cOut = Currency.wrap(data.tokenOut);

            //     /* 1. user pays gross input to PM */
            //     cIn.settle(poolManager, data.sender, data.amountInFromUser, false);

            //     /* 2. split into fee + net (same formula used in _beforeSwap) */
            //     uint256 feeRaw = (data.amountInFromUser * stableSwapFee) / PRECISION_DIVISOR;
            //     uint256 netRaw = data.amountInFromUser - feeRaw;

            //     /* 3. mint claim-tokens */
            //     cIn.take(poolManager, address(this), netRaw, true); // backs reserve
            //     if (feeRaw != 0) {
            //         cIn.take(poolManager, treasury, feeRaw, true); // fee to treasury
            //     }

            //     /* 4. provide output & pay user */
            //     cOut.settle(poolManager, address(this), data.amountOutToUser, true);
            //     cOut.take(poolManager, data.sender, data.amountOutToUser, false);

            //     /* 5. build BalanceDelta in (currency0, currency1) order */
            //     int128 d0;
            //     int128 d1;
            //     if (data.zeroForOne) {
            //         d0 = int128(uint128(data.amountInFromUser));
            //         d1 = -int128(uint128(data.amountOutToUser));
            //     } else {
            //         d1 = int128(uint128(data.amountInFromUser));
            //         d0 = -int128(uint128(data.amountOutToUser));
            //     }

            //     return abi.encode(d0, d1);

            // // Case C: Anchor Swap
            // SwapCallbackData memory data = abi.decode(callbackData.data, (SwapCallbackData));

            // Currency cIn = Currency.wrap(data.tokenIn);
            // Currency cOut = Currency.wrap(data.tokenOut);

            // // Creates a debit of `amountInFromUser` in the PM
            // cIn.settle(poolManager, data.sender, data.amountInFromUser, false);

            // // Split gross input into fee & net
            // uint256 feeRaw = (data.amountInFromUser * stableSwapFee) / PRECISION_DIVISOR;
            // uint256 netRaw = data.amountInFromUser - feeRaw;

            // // Hook takes the net part (backs the reserve increase)
            // cIn.take(poolManager, address(this), netRaw, true);

            // // Treasury takes the fee part
            // if (feeRaw > 0) {
            //     cIn.take(poolManager, treasury, feeRaw, true);
            // }

            // // Gives the PM a credit of `amountOutToUser`
            // cOut.settle(poolManager, address(this), data.amountOutToUser, true);

            // // PM pays tokenOut to the user
            // cOut.take(poolManager, data.sender, data.amountOutToUser, false);

            // // Build & return BalanceDelta -------- */
            // // Delta is expressed in (currency0, currency1) order
            // int128 delta0;
            // int128 delta1;
            // if (data.zeroForOne) {
            //     // user sold currency0, bought currency1
            //     delta0 = int128(uint128(data.amountInFromUser)); // PM net + token0
            //     delta1 = -int128(uint128(data.amountOutToUser)); // PM net – token1
            // } else {
            //     // user sold currency1, bought currency0
            //     delta1 = int128(uint128(data.amountInFromUser)); // PM net + token1
            //     delta0 = -int128(uint128(data.amountOutToUser)); // PM net – token0
            // }

            // return abi.encode(delta0, delta1);
        } else {
            revert YoloHook__UnknownUnlockActionError();
        }
    }

    /**
     * @notice  Remove liquidity from the anchor pool
     * @param   _minUSDC    Minimum USDC to receive
     * @param   _minUSY     Minimum USY to receive
     * @param   _liquidity  Amount of LP tokens to burn
     * @param   _receiver   Address to receive the USDC and USY
     */
    function removeLiquidity(uint256 _minUSDC, uint256 _minUSY, uint256 _liquidity, address _receiver)
        external
        returns (uint256 usdcAmount, uint256 usyAmount, uint256 liquidity, address receiver)
    {
        // Guard clause: ensure that the liquidity burnt is greater than zero
        if (_liquidity == 0) revert YoloHook__InvalidAddLiuidityParams();
        // Guard Claise: check user has enough LP tokens
        if (anchorPoolLPBalance[msg.sender] < _liquidity) revert YoloHook__InsufficientLiquidityBalance();
        // Guard clause: ensure that the anchor pool has enough liquidity
        if (anchorPoolLiquiditySupply == 0) revert YoloHook__InsufficientLiquidityBalance();

        // Calculate proportional amounts with rounding DOWN to benefit pool
        // User gets slightly less, pool keeps the dust
        usdcAmount = (_liquidity * totalAnchorReserveUSDC) / anchorPoolLiquiditySupply;
        usyAmount = (_liquidity * totalAnchorReserveUSY) / anchorPoolLiquiditySupply;

        if (usdcAmount < _minUSDC || usyAmount < _minUSY) revert YoloHook__InsufficientAmount();

        bytes memory data = poolManager.unlock(
            abi.encode(
                CallbackData(
                    1, abi.encode(RemoveLiquidityCallbackData(msg.sender, _receiver, usdcAmount, usyAmount, _liquidity))
                )
            )
        );

        // Decode the callback data to get the actual amounts used and liquidity minted
        (address initiator, address receiver_, uint256 usdcAmount_, uint256 usyAmount_, uint256 liquidity_) =
            abi.decode(data, (address, address, uint256, uint256, uint256));

        if (anchorPoolToken0 == usdc) {
            emit HookModifyLiquidity(anchorPoolId, receiver, -int128(int256(usdcAmount_)), -int128(int256(usyAmount_)));
        } else {
            // anchorPoolToken0 is USY
            emit HookModifyLiquidity(anchorPoolId, receiver, -int128(int256(usyAmount_)), -int128(int256(usdcAmount_)));
        }

        // Return the actual amounts and receiver
        return (usdcAmount_, usyAmount_, liquidity_, receiver_);
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
    function beforeModifyLiquidity(PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        // Guard clause: revert if someone tries to add liquidity directly through PoolManager / PositionsManager
        revert YoloHook__MustAddLiquidityThroughHook();
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
        // Guard clause: revert if someone tries to add liquidity directly through PoolManager / PositionsManager
        revert YoloHook__MustAddLiquidityThroughHook();
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Determine and examine the pool
        bytes32 poolId = PoolId.unwrap(key.toId());

        // BeforeSwapDelta to be returned to the PoolManager and bypass the default pool swap logic
        BeforeSwapDelta beforeSwapDelta;

        // Tokens Instance
        Currency currencyIn;
        Currency currencyOut;
        address tokenInAddr;
        address tokenOutAddr;

        if (isAnchorPool[poolId]) {
            // A. Execute stable swap if it's anchor pool

            // 1. Parse Input
            if (totalAnchorReserveUSDC == 0 || totalAnchorReserveUSY == 0) {
                revert YoloHook__InsufficientReserves();
            }

            bool usdcToUsy = (params.zeroForOne == (anchorPoolToken0 == usdc));
            currencyIn = usdcToUsy ? Currency.wrap(usdc) : Currency.wrap(address(anchor));
            currencyOut = usdcToUsy ? Currency.wrap(address(anchor)) : Currency.wrap(usdc);

            uint256 reserveInRaw = usdcToUsy ? totalAnchorReserveUSDC : totalAnchorReserveUSY;
            uint256 reserveOutRaw = usdcToUsy ? totalAnchorReserveUSY : totalAnchorReserveUSDC;

            uint256 scaleUpIn = usdcToUsy ? USDC_SCALE_UP : 1;
            uint256 scaleUpOut = usdcToUsy ? 1 : USDC_SCALE_UP;

            uint256 reserveInWad = reserveInRaw * scaleUpIn;
            uint256 reserveOutWad = reserveOutRaw * scaleUpOut;

            // 2. Quote
            uint256 grossInRaw;
            uint256 netInRaw;
            uint256 feeRaw;
            uint256 amountOutRaw;

            if (params.amountSpecified < 0) {
                // 2A. Exact Input
                grossInRaw = uint256(-params.amountSpecified);
                uint256 grossInWad = grossInRaw * scaleUpIn;

                uint256 feeWad = (grossInWad * stableSwapFee) / PRECISION_DIVISOR;
                uint256 netInWad = grossInWad - feeWad;

                uint256 outWad = _calculateStableSwapOutputInternal(netInWad, reserveInWad, reserveOutWad);
                if (outWad == 0) revert YoloHook__InvalidOutput();

                amountOutRaw = outWad / scaleUpOut;
                feeRaw = feeWad / scaleUpIn;
                netInRaw = grossInRaw - feeRaw;
            } else {
                // 2B. Exact Output
                amountOutRaw = uint256(params.amountSpecified);
                uint256 desiredOutWad = amountOutRaw * scaleUpOut;

                uint256 netInWad = _calculateStableSwapInputInternal(desiredOutWad, reserveInWad, reserveOutWad);

                uint256 grossInWad =
                    (netInWad * PRECISION_DIVISOR + (PRECISION_DIVISOR - 1)) / (PRECISION_DIVISOR - stableSwapFee); // ceil-div
                uint256 feeWad = grossInWad - netInWad;

                grossInRaw = grossInWad / scaleUpIn;
                feeRaw = feeWad / scaleUpIn;
                netInRaw = grossInRaw - feeRaw;
            }

            // 3. Update Reserves
            if (usdcToUsy) {
                totalAnchorReserveUSDC = reserveInRaw + netInRaw;
                totalAnchorReserveUSY = reserveOutRaw - amountOutRaw;
            } else {
                totalAnchorReserveUSY = reserveInRaw + netInRaw;
                totalAnchorReserveUSDC = reserveOutRaw - amountOutRaw;
            }

            // 4. Construct BeforeSwapDelta
            int128 dSpecified;
            int128 dUnspecified;

            if (params.amountSpecified < 0) {
                dSpecified = int128(uint128(grossInRaw));
                dUnspecified = -int128(uint128(amountOutRaw));
            } else {
                dSpecified = -int128(uint128(amountOutRaw));
                dUnspecified = int128(uint128(grossInRaw));
            }
            beforeSwapDelta = toBeforeSwapDelta(dSpecified, dUnspecified);

            // 5. Currency Settlement

            Currency cIn = currencyIn;
            Currency cOut = currencyOut;

            cIn.take(poolManager, address(this), netInRaw, true);
            if (feeRaw != 0) {
                cIn.take(poolManager, treasury, feeRaw, false);
            }
            cOut.settle(poolManager, address(this), amountOutRaw, true);

            emit AnchorSwapExecuted(
                poolId,
                sender,
                sender,
                params.zeroForOne,
                Currency.unwrap(currencyIn),
                grossInRaw,
                Currency.unwrap(currencyOut),
                amountOutRaw,
                feeRaw
            );

            return (this.beforeSwap.selector, beforeSwapDelta, 0);
        } else if (isSyntheticPool[poolId]) {
            // Execute stynthetic swap (oracle swap) if it's synthetic pool
        } else {
            revert YoloHook__InvalidPoolId();
        }

        // Call to unlockcall back for currency settlement

        return (this.beforeSwap.selector, beforeSwapDelta, 0);
    }

    function _afterSwap(
        address, // sender   (unused)
        PoolKey calldata, // key      (unused)
        SwapParams calldata, // params   (unused)
        BalanceDelta, // delta    (unused)
        bytes calldata // hookData (unused)
    ) internal override returns (bytes4, int128) {
        // return our external afterSwap selector and “zero” delta
        return (this.afterSwap.selector, int128(0));
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

    // ***********************************//
    // *** STABLESWAP MATH FUNCTIONS *** //
    // ********************************** //

    function _getK_stable(uint256 x_18d, uint256 y_18d) internal pure returns (uint256 k_18d) {
        if (x_18d == 0 || y_18d == 0) return 0;
        uint256 xy_P = (x_18d * y_18d) / MATH_PRECISION;
        uint256 x_sq_P = (x_18d * x_18d) / MATH_PRECISION;
        uint256 y_sq_P = (y_18d * y_18d) / MATH_PRECISION;
        k_18d = (xy_P * (x_sq_P + y_sq_P)) / MATH_PRECISION;
        return k_18d;
    }

    function _f_stable(uint256 x0_18d, uint256 y_18d) private pure returns (uint256) {
        uint256 y_sq_P = (y_18d * y_18d) / MATH_PRECISION;
        uint256 y_cubed_P2 = (y_sq_P * y_18d) / MATH_PRECISION;
        uint256 term1 = (x0_18d * y_cubed_P2) / MATH_PRECISION;

        uint256 x0_sq_P = (x0_18d * x0_18d) / MATH_PRECISION;
        uint256 x0_cubed_P2 = (x0_sq_P * x0_18d) / MATH_PRECISION;
        uint256 term2 = (y_18d * x0_cubed_P2) / MATH_PRECISION;
        return term1 + term2;
    }

    function _d_stable(uint256 x0_18d, uint256 y_18d) internal pure returns (uint256) {
        uint256 x0_cubed_P2 = (((x0_18d * x0_18d) / MATH_PRECISION) * x0_18d) / MATH_PRECISION;

        uint256 y_sq_P = (y_18d * y_18d) / MATH_PRECISION;
        uint256 x0_y_sq_P2 = (x0_18d * y_sq_P) / MATH_PRECISION;

        if (x0_y_sq_P2 > type(uint256).max / 3) {
            revert YoloHook__MathOverflow();
        }
        uint256 term2_3x = 3 * x0_y_sq_P2;

        uint256 derivative = x0_cubed_P2 + term2_3x;
        if (derivative == 0) revert YoloHook__StableswapConvergenceError();
        return derivative;
    }

    function _getY_stable(uint256 x0_18d, uint256 k_18d, uint256 y_guess_18d)
        internal
        pure
        returns (uint256 y_new_18d)
    {
        y_new_18d = y_guess_18d;
        if (x0_18d == 0) {
            if (k_18d > 0) revert YoloHook__StableswapConvergenceError();
            return 0;
        }

        for (uint256 i = 0; i < STABLESWAP_ITERATIONS; i++) {
            uint256 y_prev = y_new_18d;
            uint256 f_val = _f_stable(x0_18d, y_new_18d);
            uint256 d_val = _d_stable(x0_18d, y_new_18d);

            uint256 dy;
            if (f_val < k_18d) {
                dy = ((k_18d - f_val) * MATH_PRECISION) / d_val;
                y_new_18d = y_new_18d + dy;
            } else {
                dy = ((f_val - k_18d) * MATH_PRECISION) / d_val;
                if (dy > y_new_18d) {
                    y_new_18d = 0;
                } else {
                    y_new_18d = y_new_18d - dy;
                }
            }

            if (y_new_18d > y_prev) {
                if (y_new_18d - y_prev <= 1) break;
            } else {
                if (y_prev - y_new_18d <= 1) break;
            }
        }
        return y_new_18d;
    }

    function _calculateStableSwapOutputInternal(uint256 netAmountIn_18d, uint256 reserveIn_18d, uint256 reserveOut_18d)
        internal
        pure
        returns (uint256 amountOut_18d)
    {
        if (netAmountIn_18d == 0) return 0;
        uint256 k_val = _getK_stable(reserveIn_18d, reserveOut_18d);

        if (k_val == 0) {
            revert YoloHook__InsufficientReserves();
        }

        uint256 newReserveIn_18d = reserveIn_18d + netAmountIn_18d;
        uint256 newReserveOut_18d = _getY_stable(newReserveIn_18d, k_val, reserveOut_18d);

        if (newReserveOut_18d >= reserveOut_18d) return 0;
        amountOut_18d = reserveOut_18d - newReserveOut_18d;
    }

    function _calculateStableSwapInputInternal(uint256 amountOut_18d, uint256 reserveIn_18d, uint256 reserveOut_18d)
        internal
        pure
        returns (uint256 netAmountIn_18d)
    {
        if (amountOut_18d == 0) return 0;
        if (amountOut_18d >= reserveOut_18d) {
            revert YoloHook__InsufficientReserves();
        }

        uint256 k_val = _getK_stable(reserveIn_18d, reserveOut_18d);
        if (k_val == 0) {
            revert YoloHook__InsufficientReserves();
        }

        uint256 newReserveOut_18d = reserveOut_18d - amountOut_18d;
        uint256 newReserveIn_18d = _getY_stable(newReserveOut_18d, k_val, reserveIn_18d);

        if (newReserveIn_18d <= reserveIn_18d) {
            revert YoloHook__InvalidSwapAmounts();
        }
        netAmountIn_18d = newReserveIn_18d - reserveIn_18d;
    }
}
