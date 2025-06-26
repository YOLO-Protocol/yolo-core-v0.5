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
import {FullMath} from "@yolo/contracts/libraries/FullMath.sol";
import {StableMathLib} from "@yolo/contracts/libraries/StableMathLib.sol";
/*---------- IMPORT INTERFACES ----------*/
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IWETH} from "@yolo/contracts/interfaces/IWETH.sol";
import {IYoloOracle} from "@yolo/contracts/interfaces/IYoloOracle.sol";
import {IYoloSyntheticAsset} from "@yolo/contracts/interfaces/IYoloSyntheticAsset.sol";
import {IPoolManager, ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IFlashBorrower} from "@yolo/contracts/interfaces/IFlashBorrower.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
/*---------- IMPORT CONTRACTS ----------*/
import {YoloSyntheticAsset} from "@yolo/contracts/tokenization/YoloSyntheticAsset.sol";
/*---------- IMPORT BASE CONTRACTS ----------*/
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

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
contract YoloHook is BaseHook, ReentrancyGuard, Ownable, Pausable {
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
    uint256 private constant YEAR = 365 days;

    // ***************************//
    // *** CONTRACT VARIABLES *** //
    // ************************** //

    address public treasury; // Address of the treasury to collect fees
    // IWETH public weth;
    IYoloOracle public yoloOracle;

    /*----- Fees Configuration -----*/
    uint256 public stableSwapFee; // Swap fee for the anchor pool, in basis points (e.g., 100 = 1%)
    uint256 public syntheticSwapFee; // Swap fee for synthetic assets, in basis points (e.g., 100 = 1%)
    uint256 public flashLoanFee; // Flash loan fee for synthetic assets, in basis points (e.g., 100 = 1%)

    /*----- Anchor Pool & Stableswap Variables -----*/
    IYoloSyntheticAsset public anchor;
    address public usdc; // USDC address, used in the anchor pool to pair with USY
    bytes32 public anchorPoolId; // Anchor pool ID, used to identify the pool in the PoolManager
    address public anchorPoolToken0; // Token0 address of the anchor pool, set in initialize

    mapping(bytes32 => bool) public isAnchorPool;
    uint256 public anchorPoolLiquiditySupply; // Total LP tokens for anchor pool
    mapping(address => uint256) public anchorPoolLPBalance; // User LP balances

    /*----- Synthetic Pools -----*/
    mapping(bytes32 => bool) public isSyntheticPool;

    /*----- Synthetic Swap Placeholders -----*/
    // => To be used in afterSwap to burn the pulled YoloAssets after settlement
    address public assetToBurn;
    uint256 public amountToBurn;

    uint256 private USDC_SCALE_UP; // Make sure USDC is scaled up to 18 decimals

    // Anchor pool reserves
    uint256 public totalAnchorReserveUSDC;
    uint256 public totalAnchorReserveUSY;

    // Constants for stableswap
    uint256 private constant MINIMUM_LIQUIDITY = 1000;

    /*----- Asset & Collateral Configurations -----*/
    mapping(address => bool) public isYoloAsset; // Mapping to check if an address is a Yolo asset
    mapping(address => bool) public isWhiteListedCollateral; // Mapping to check if an address is a whitelisted collateral asset

    mapping(address => YoloAssetConfiguration) public yoloAssetConfigs; // Maps Yolo assets to its configuration
    mapping(address => CollateralConfiguration) public collateralConfigs; // Maps collateral to its configuration

    mapping(address => address[]) yoloAssetsToSupportedCollateral; // List of collaterals can be used to mint a Yolo Asset
    mapping(address => address[]) collateralToSupportedYoloAssets; // List of Yolo assets can be minted with a particular asset
    mapping(address => mapping(address => CollateralToYoloAssetConfiguration)) public pairConfigs; // Pair Configs of (collateral => asset)

    /*----- User Positions -----*/
    mapping(address => mapping(address => mapping(address => UserPosition))) public positions;
    mapping(address => UserPositionKey[]) public userPositionKeys;

    /*----- Delegation Logic Contract -----*/
    address public syntheticAssetLogic;

    // ***************//
    // *** EVENTS *** //
    // ************** //

    /**
     * @notice  Emitted when liquidity is added or removed from the hook. Complies with Uniswap V4 best practice guidance.
     */
    event HookModifyLiquidity(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1);

    /**
     * @notice  Emitted when a swap is confucted through the hook. Complies with Uniswap V4 best practice guidance.
     */
    event HookSwap(
        bytes32 indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint128 hookLPfeeAmount0,
        uint128 hookLPfeeAmount1
    );

    event UpdateStableSwapFee(uint256 newStableSwapFee, uint256 oldStableSwapFee);

    event UpdateSyntheticSwapFee(uint256 newSyntheticSwapFee, uint256 oldSynthethicSwapFee);

    event UpdateFlashLoanFee(uint256 newFlashLoanFee, uint256 oldFlashLoanFee);

    event YoloAssetCreated(address indexed asset, string name, string symbol, uint8 decimals, address priceSource);

    event YoloAssetConfigurationUpdated(
        address yoloAsset, uint256 newMaxMintableCap, uint256 newMaxFlashLoanableAmount
    );

    event CollateralConfigurationUpdated(address indexed collateral, uint256 newSupplyCap, address newPriceSource);

    event PairConfigUpdated(
        address indexed collateral,
        address indexed yoloAsset,
        uint256 interestRate,
        uint256 ltv,
        uint256 liquidationPenalty
    );

    event PairDropped(address collateral, address yoloAsset);

    event Borrowed(
        address indexed user,
        address indexed collateral,
        uint256 collateralAmount,
        address indexed yoloAsset,
        uint256 borrowAmount
    );

    event PositionPartiallyRepaid(
        address indexed user,
        address indexed collateral,
        address indexed yoloAsset,
        uint256 totalRepaid,
        uint256 interestPaid,
        uint256 principalPaid,
        uint256 remainingPrincipal,
        uint256 remainingInterest
    );

    event PositionFullyRepaid(
        address indexed user,
        address indexed collateral,
        address indexed yoloAsset,
        uint256 totalRepaid,
        uint256 collateralReturned
    );

    event Withdrawn(address indexed user, address indexed collateral, address indexed yoloAsset, uint256 amount);

    event Liquidated(
        address indexed user,
        address indexed collateral,
        address indexed yoloAsset,
        uint256 repayAmount,
        uint256 collateralSeized
    );

    event FlashLoanExecuted(address indexed flashBorrower, address[] yoloAssets, uint256[] amounts, uint256[] fees);

    // ***************//
    // *** ERRORS *** //
    // ************** //
    error Ownable__AlreadyInitialized();
    error YoloHook__ParamsLengthMismatched();
    error YoloHook__ZeroAddress();
    error YoloHook__MustAddLiquidityThroughHook();
    error YoloHook__InvalidAddLiuidityParams();
    error YoloHook__InsufficientLiquidityMinted();
    error YoloHook__InsufficientLiquidityBalance();
    error YoloHook__InsufficientAmount();
    error YoloHook__UnknownUnlockActionError();
    error YoloHook__InvalidPoolId();
    error YoloHook__InsufficientReserves();
    error YoloHook__StableswapConvergenceError();
    error YoloHook__InvalidOutput();
    error YoloHook__InvalidSwapAmounts();
    error YoloHook__NotYoloAsset();
    error YoloHook__CollateralNotRecognized();
    error YoloHook__InvalidPriceSource();
    error YoloHook__InvalidPair();
    error YoloHook__NoDebt();
    error YoloHook__RepayExceedsDebt();
    error YoloHook__YoloAssetPaused();
    error YoloHook__CollateralPaused();
    error YoloHook__Solvent();
    error YoloHook__NotSolvent();
    error YoloHook__ExceedsYoloAssetMintCap();
    error YoloHook__ExceedsCollateralCap();
    error YoloHook__InvalidPosition();
    error YoloHook__InvalidSeizeAmount();
    error YoloHook__ExceedsFlashLoanCap();
    error YoloHook__NoPendingBurns();

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
        // weth = IWETH(_wethAddress);
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
        isYoloAsset[address(anchor)] = true;

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
        } else {
            c0 = Currency.wrap(tokenB);
            c1 = Currency.wrap(tokenA);
            anchorPoolToken0 = tokenB;
        }

        // Initialize the anchor pool with the sorted tokens and fee
        PoolKey memory pk =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(this))});
        // let PM burn any USDC or USY claim-tokens we mint later
        poolManager.initialize(pk, uint160(1) << 96);
        anchorPoolId = PoolId.unwrap(pk.toId());
        isAnchorPool[PoolId.unwrap(pk.toId())] = true;
    }

    // *********************** //
    // *** ADMIN FUNCTIONS *** //
    // *********************** //

    function pause(bool _isPause) external onlyOwner {
        if (_isPause) _pause();
        else _unpause();
    }

    function setFee(uint256 _newFee, uint8 _feeType) external onlyOwner {
        if (_feeType == 0) {
            emit UpdateStableSwapFee(_newFee, stableSwapFee);
            stableSwapFee = _newFee;
        }
        if (_feeType == 1) {
            emit UpdateSyntheticSwapFee(_newFee, syntheticSwapFee);
            syntheticSwapFee = _newFee;
        }
        if (_feeType == 2) {
            emit UpdateFlashLoanFee(_newFee, flashLoanFee);
            flashLoanFee = _newFee;
        }
    }

    /**
     * @notice  Set the synthetic asset logic contract address
     * @param   _syntheticAssetLogic The address of the synthetic asset logic contract
     */
    function setSyntheticAssetLogic(address _syntheticAssetLogic) external onlyOwner {
        if (_syntheticAssetLogic == address(0)) revert YoloHook__ZeroAddress();
        syntheticAssetLogic = _syntheticAssetLogic;
    }

    function createNewYoloAsset(string calldata _name, string calldata _symbol, uint8 _decimals, address _priceSource)
        external
        onlyOwner
        returns (address)
    {
        // 1. Deploy the token
        YoloSyntheticAsset asset = new YoloSyntheticAsset(_name, _symbol, _decimals);
        address a = address(asset);

        // 2. Register it
        isYoloAsset[a] = true;
        yoloAssetConfigs[a] =
            YoloAssetConfiguration({yoloAssetAddress: a, maxMintableCap: 0, maxFlashLoanableAmount: 0});

        // 3. Wire its price feed in the Oracle
        address[] memory assets = new address[](1);
        address[] memory priceSources = new address[](1);
        assets[0] = a;
        priceSources[0] = _priceSource;
        yoloOracle.setAssetSources(assets, priceSources);

        emit YoloAssetCreated(a, _name, _symbol, _decimals, _priceSource);

        // 4. Automatically create a synthetic pool vs. the anchor (USY)
        //    and mark it in our mapping so _beforeSwap kicks in correctly.
        bool anchorIs0 = address(anchor) < a;
        Currency c0 = Currency.wrap(anchorIs0 ? address(anchor) : a);
        Currency c1 = Currency.wrap(anchorIs0 ? a : address(anchor));

        PoolKey memory pk =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(this))});

        // initialize price at 1:1 (sqrtPriceX96 = 2^96)
        poolManager.initialize(pk, uint160(1) << 96);

        // mark it synthetic
        isSyntheticPool[PoolId.unwrap(pk.toId())] = true;

        return a;
    }

    function setYoloAssetConfig(address _asset, uint256 _newMintCap, uint256 _newFlashLoanCap) external onlyOwner {
        if (!isYoloAsset[_asset]) revert YoloHook__NotYoloAsset();
        YoloAssetConfiguration storage cfg = yoloAssetConfigs[_asset];
        cfg.maxMintableCap = _newMintCap;
        cfg.maxFlashLoanableAmount = _newFlashLoanCap;
        emit YoloAssetConfigurationUpdated(_asset, _newMintCap, _newFlashLoanCap);
    }

    function setCollateralConfig(address _collateral, uint256 _newSupplyCap, address _priceSource) external onlyOwner {
        isWhiteListedCollateral[_collateral] = true;
        CollateralConfiguration storage cfg = collateralConfigs[_collateral];
        cfg.collateralAsset = _collateral;
        cfg.maxSupplyCap = _newSupplyCap;
        if (_priceSource != address(0)) {
            address[] memory assets = new address[](1);
            address[] memory priceSources = new address[](1);
            assets[0] = _collateral;
            priceSources[0] = _priceSource;

            yoloOracle.setAssetSources(assets, priceSources);
        }
        emit CollateralConfigurationUpdated(_collateral, _newSupplyCap, _priceSource);
    }

    function setPairConfig(
        address _collateral,
        address _yoloAsset,
        uint256 _interestRate,
        uint256 _ltv,
        uint256 _liquidationPenalty
    ) external onlyOwner {
        if (!isWhiteListedCollateral[_collateral]) revert YoloHook__CollateralNotRecognized();
        if (!isYoloAsset[_yoloAsset]) revert YoloHook__NotYoloAsset();

        bool isNewPair = pairConfigs[_collateral][_yoloAsset].collateral == address(0);

        pairConfigs[_collateral][_yoloAsset] = CollateralToYoloAssetConfiguration({
            collateral: _collateral,
            yoloAsset: _yoloAsset,
            interestRate: _interestRate,
            ltv: _ltv,
            liquidationPenalty: _liquidationPenalty
        });

        // Only push to arrays if this is a new pair
        if (isNewPair) {
            collateralToSupportedYoloAssets[_collateral].push(_yoloAsset);
            yoloAssetsToSupportedCollateral[_yoloAsset].push(_collateral);
        }

        emit PairConfigUpdated(_collateral, _yoloAsset, _interestRate, _ltv, _liquidationPenalty);
    }

    function removePairConfig(address _collateral, address _yoloAsset) external onlyOwner {
        // 1) remove the config mapping
        delete pairConfigs[_collateral][_yoloAsset];

        // 2) remove from collateral→assets list
        _removeFromArray(collateralToSupportedYoloAssets[_collateral], _yoloAsset);

        // 3) remove from asset→collaterals list
        _removeFromArray(yoloAssetsToSupportedCollateral[_yoloAsset], _collateral);

        emit PairDropped(_collateral, _yoloAsset);
    }

    function setNewPriceSource(address _asset, address _priceSource) external onlyOwner {
        if (_priceSource == address(0)) revert YoloHook__InvalidPriceSource();

        address oldPriceSource = yoloOracle.getSourceOfAsset(_asset);

        address[] memory assets = new address[](1);
        address[] memory priceSources = new address[](1);
        assets[0] = _asset;
        priceSources[0] = _priceSource;

        yoloOracle.setAssetSources(assets, priceSources);

        // emit PriceSourceUpdated(_asset, _priceSource, oldPriceSource);
    }

    // ***************************** //
    // *** USER FACING FUNCTIONS *** //
    // ***************************** //

    /**
     * @notice  Allow users to deposit collateral and mint yolo assets
     * @param   _yoloAsset          The yolo asset to mint
     * @param   _borrowAmount       The amount of yolo asset to mint
     * @param   _collateral         The collateral asset to deposit
     * @param   _collateralAmount   The amount of collateral to deposit
     */
    function borrow(address _yoloAsset, uint256 _borrowAmount, address _collateral, uint256 _collateralAmount)
        external
        nonReentrant
        whenNotPaused
    {
        (bool success,) = syntheticAssetLogic.delegatecall(
            abi.encodeWithSignature(
                "borrow(address,uint256,address,uint256)", _yoloAsset, _borrowAmount, _collateral, _collateralAmount
            )
        );
        require(success, "Borrow delegatecall failed");
    }

    /**
     * @notice  Allows users to repay their borrowed YoloAssets
     * @param   _collateral         The collateral asset address
     * @param   _yoloAsset          The yolo asset address being repaid
     * @param   _repayAmount        The amount to repay (0 for full repayment)
     * @param   _claimCollateral    Whether to withdraw collateral after full repayment
     */
    function repay(address _collateral, address _yoloAsset, uint256 _repayAmount, bool _claimCollateral)
        external
        nonReentrant
    {
        (bool success,) = syntheticAssetLogic.delegatecall(
            abi.encodeWithSignature(
                "repay(address,address,uint256,bool)", _collateral, _yoloAsset, _repayAmount, _claimCollateral
            )
        );
        require(success, "Repay delegatecall failed");
    }

    /**
     * @notice  Redeem up to `amount` of your collateral, provided your loan stays solvent
     * @param   _collateral    The collateral token address
     * @param   _yoloAsset     The YoloAsset token address
     * @param   _amount        How much collateral to withdraw
     */
    function withdraw(address _collateral, address _yoloAsset, uint256 _amount) external nonReentrant whenNotPaused {
        (bool success,) = syntheticAssetLogic.delegatecall(
            abi.encodeWithSignature("withdraw(address,address,uint256)", _collateral, _yoloAsset, _amount)
        );
        require(success, "Withdraw delegatecall failed");
    }

    /**
     * @dev     Liquidate an under‐collateralized position
     * @param   _user        The borrower whose position is being liquidated
     * @param   _collateral  The collateral token address
     * @param   _yoloAsset   The YoloAsset token address
     * @param   _repayAmount How much of the borrower's debt to cover (0 == full debt)
     */
    function liquidate(address _user, address _collateral, address _yoloAsset, uint256 _repayAmount)
        external
        nonReentrant
    {
        (bool success,) = syntheticAssetLogic.delegatecall(
            abi.encodeWithSignature(
                "liquidate(address,address,address,uint256)", _user, _collateral, _yoloAsset, _repayAmount
            )
        );
        require(success, "Liquidate delegatecall failed");
    }

    /**
     * @dev     Executes a batch flash loan for multiple YoloAssets.
     * @param   _yoloAssets  Array of YoloAsset addresses to borrow.
     * @param   _amounts     Array of amounts to borrow per asset.
     * @param   _data        Arbitrary call data passed to the borrower.
     */
    function flashLoan(address[] calldata _yoloAssets, uint256[] calldata _amounts, bytes calldata _data)
        external
        nonReentrant
        whenNotPaused
    {
        if (_yoloAssets.length != _amounts.length) revert YoloHook__ParamsLengthMismatched();

        uint256[] memory fees = new uint256[](_yoloAssets.length);
        uint256[] memory totalRepayments = new uint256[](_yoloAssets.length);

        // Mint flash loans to the borrower
        for (uint256 i = 0; i < _yoloAssets.length;) {
            if (!isYoloAsset[_yoloAssets[i]]) revert YoloHook__NotYoloAsset();

            YoloAssetConfiguration storage assetConfig = yoloAssetConfigs[_yoloAssets[i]];
            if (assetConfig.maxMintableCap <= 0) revert YoloHook__YoloAssetPaused();

            // Check if flash loan amount exceeds the cap
            if (assetConfig.maxFlashLoanableAmount > 0 && _amounts[i] > assetConfig.maxFlashLoanableAmount) {
                revert YoloHook__ExceedsFlashLoanCap();
            }

            // Calculate the fee and total repayment
            uint256 fee = (_amounts[i] * flashLoanFee) / PRECISION_DIVISOR;
            fees[i] = fee;
            totalRepayments[i] = _amounts[i] + fee;

            // Mint the YoloAsset to the borrower
            IYoloSyntheticAsset(_yoloAssets[i]).mint(msg.sender, _amounts[i]);

            unchecked {
                ++i;
            }
        }

        // Call the borrower's callback function
        IFlashBorrower(msg.sender).onBatchFlashLoan(msg.sender, _yoloAssets, _amounts, fees, _data);

        // Burn the amount + fee from the borrower and mint fee to the treasury
        for (uint256 i = 0; i < _yoloAssets.length;) {
            // Ensure repayment
            IYoloSyntheticAsset(_yoloAssets[i]).burn(msg.sender, totalRepayments[i]);

            // Mint the fee to the protocol treasury
            IYoloSyntheticAsset(_yoloAssets[i]).mint(treasury, fees[i]);
            unchecked {
                ++i;
            }
        }

        emit FlashLoanExecuted(msg.sender, _yoloAssets, _amounts, fees);
    }

    function burnPendings() external {
        if (assetToBurn == address(0)) revert YoloHook__NoPendingBurns();

        poolManager.unlock(abi.encode(CallbackData(2, "0x")));
    }

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
        whenNotPaused
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
            // emit AnchorLiquidityAdded(sender, receiver, usdcUsed, usyUsed, liquidity);

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

            // emit AnchorLiquidityRemoved(initiator, receiver, usdcAmount, usyAmount, liquidity);

            return abi.encode(initiator, receiver, usdcAmount, usyAmount, liquidity);
        } else if (action == 2) {
            // Case C: Burn pending burnt tokens
            _burnPending();
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
        whenNotPaused
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
     * @dev     Enable all actions to enture future upgradability.
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
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

    // Backup
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Burn pending if needed
        if (assetToBurn != address(0)) _burnPending();

        bytes32 poolId = PoolId.unwrap(key.toId());
        bool exactIn = params.amountSpecified < 0;

        if (isAnchorPool[poolId]) {
            // Scoped variables for anchor pool
            if (totalAnchorReserveUSDC == 0 || totalAnchorReserveUSY == 0) {
                revert YoloHook__InsufficientReserves();
            }

            bool usdcToUsy = params.zeroForOne == (anchorPoolToken0 == usdc);
            Currency cIn = usdcToUsy ? Currency.wrap(usdc) : Currency.wrap(address(anchor));
            Currency cOut = usdcToUsy ? Currency.wrap(address(anchor)) : Currency.wrap(usdc);

            uint256 rIn = usdcToUsy ? totalAnchorReserveUSDC : totalAnchorReserveUSY;
            uint256 rOut = usdcToUsy ? totalAnchorReserveUSY : totalAnchorReserveUSDC;
            uint256 sIn = usdcToUsy ? USDC_SCALE_UP : 1;
            uint256 sOut = usdcToUsy ? 1 : USDC_SCALE_UP;

            uint256 gIn;
            uint256 nIn;
            uint256 f;
            uint256 out;

            if (exactIn) {
                gIn = uint256(-params.amountSpecified);
                uint256 gInW = gIn * sIn;
                uint256 fW = (gInW * stableSwapFee) / PRECISION_DIVISOR;
                uint256 nInW = gInW - fW;
                uint256 outW = StableMathLib.calculateStableSwapOutput(nInW, rIn * sIn, rOut * sOut);
                if (outW == 0) revert YoloHook__InvalidOutput();
                out = outW / sOut;
                f = fW / sIn;
                nIn = gIn - f;
            } else {
                out = uint256(params.amountSpecified);
                uint256 nInW = StableMathLib.calculateStableSwapInput(out * sOut, rIn * sIn, rOut * sOut);
                uint256 gInW = (nInW * PRECISION_DIVISOR + PRECISION_DIVISOR - 1) / (PRECISION_DIVISOR - stableSwapFee);
                gIn = gInW / sIn;
                f = (gInW - nInW) / sIn;
                nIn = gIn - f;
            }

            // Update reserves
            if (usdcToUsy) {
                totalAnchorReserveUSDC = rIn + nIn;
                totalAnchorReserveUSY = rOut - out;
            } else {
                totalAnchorReserveUSY = rIn + nIn;
                totalAnchorReserveUSDC = rOut - out;
            }

            // Settlement
            cIn.take(poolManager, address(this), nIn, true);
            if (f > 0) cIn.take(poolManager, treasury, f, false);
            cOut.settle(poolManager, address(this), out, true);

            // Emit and return
            emit HookSwap(
                poolId,
                sender,
                params.zeroForOne ? int128(uint128(gIn)) : -int128(uint128(out)),
                params.zeroForOne ? -int128(uint128(out)) : int128(uint128(gIn)),
                params.zeroForOne ? uint128(f) : 0,
                params.zeroForOne ? 0 : uint128(f)
            );

            return (
                this.beforeSwap.selector,
                toBeforeSwapDelta(
                    exactIn ? int128(uint128(gIn)) : -int128(uint128(out)),
                    exactIn ? -int128(uint128(out)) : int128(uint128(gIn))
                ),
                0
            );
        } else if (isSyntheticPool[poolId]) {
            // Scoped variables for synthetic pool
            Currency cIn;
            Currency cOut;
            (cIn, cOut) = params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

            address tIn = Currency.unwrap(cIn);
            address tOut = Currency.unwrap(cOut);

            uint256 gIn;
            uint256 nIn;
            uint256 f;
            uint256 out;

            if (exactIn) {
                gIn = uint256(-int256(params.amountSpecified));
                f = gIn * syntheticSwapFee / PRECISION_DIVISOR;
                nIn = gIn - f;
                out = yoloOracle.getAssetPrice(tIn) * nIn / yoloOracle.getAssetPrice(tOut);
            } else {
                out = uint256(int256(params.amountSpecified));
                nIn = yoloOracle.getAssetPrice(tOut) * out / yoloOracle.getAssetPrice(tIn);
                f = (nIn * syntheticSwapFee + PRECISION_DIVISOR - syntheticSwapFee - 1)
                    / (PRECISION_DIVISOR - syntheticSwapFee);
                gIn = nIn + f;
            }

            // Settlement
            cIn.take(poolManager, address(this), nIn, true);
            if (f > 0) cIn.take(poolManager, treasury, f, true);
            IYoloSyntheticAsset(tOut).mint(address(this), out);
            cOut.settle(poolManager, address(this), out, false);

            assetToBurn = tIn;
            amountToBurn = nIn;

            // Emit and return
            emit HookSwap(
                poolId,
                sender,
                params.zeroForOne ? int128(uint128(gIn)) : -int128(uint128(out)),
                params.zeroForOne ? -int128(uint128(out)) : int128(uint128(gIn)),
                params.zeroForOne ? uint128(f) : 0,
                params.zeroForOne ? 0 : uint128(f)
            );

            return (
                this.beforeSwap.selector,
                toBeforeSwapDelta(
                    exactIn ? int128(uint128(gIn)) : -int128(uint128(out)),
                    exactIn ? -int128(uint128(out)) : int128(uint128(gIn))
                ),
                0
            );
        } else {
            revert YoloHook__InvalidPoolId();
        }
    }

    function _afterSwap(
        address, // unused
        PoolKey calldata, // unused
        SwapParams calldata, // unused
        BalanceDelta, // unused
        bytes calldata // unused
    ) internal override returns (bytes4, int128) {
        return (this.afterSwap.selector, int128(0));
    }

    // ***********************//
    // *** VIEW FUNCTIONS *** //
    // ********************** //

    // ***************************//
    // *** INTERNAL FUNCTIONS *** //
    // ************************** //

    function _removeFromArray(address[] storage arr, address elem) internal {
        uint256 len = arr.length;
        for (uint256 i = 0; i < len;) {
            if (arr[i] == elem) {
                // swap with last element and pop
                arr[i] = arr[len - 1];
                arr.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice  Helper function to remove a position key from a user's positions array
     * @param   _user           The user address
     * @param   _collateral     The collateral asset address
     * @param   _yoloAsset      The yolo asset address
     */
    function _removeUserPositionKey(address _user, address _collateral, address _yoloAsset) internal {
        UserPositionKey[] storage keys = userPositionKeys[_user];
        for (uint256 i = 0; i < keys.length;) {
            if (keys[i].collateral == _collateral && keys[i].yoloAsset == _yoloAsset) {
                // Swap with last element and pop
                keys[i] = keys[keys.length - 1];
                keys.pop();
                break;
            }
            unchecked {
                ++i;
            }
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

    // ***************************//
    // *** INTERNAL FUNCTIONS *** //
    //*************************** //

    /**
     * @notice  Internal function to accrue interest for a user's position.
     * @dev     This function changes state.
     * @param   _pos        The position of the user from storage.
     * @param   _rate       The interest rate to apply.
     */
    function _accrueInterest(UserPosition storage _pos, uint256 _rate) internal {
        if (_pos.yoloAssetMinted == 0) {
            _pos.lastUpdatedTimeStamp = block.timestamp;
            return;
        }
        uint256 dt = block.timestamp - _pos.lastUpdatedTimeStamp;
        // simple pro-rata APR: principal * rate * dt / (1yr * PRECISION_DIVISOR)
        _pos.accruedInterest += (_pos.yoloAssetMinted * _rate * dt) / (YEAR * PRECISION_DIVISOR);
        _pos.lastUpdatedTimeStamp = block.timestamp;
    }

    /**
     * @notice  Internal function check whether user is solvent at a given state.
     * @dev     This function changes state.
     * @param   _pos            The position of the user from at the given timeframe & state.
     * @param   _collateral     The collateral asset address.
     * @param   _yoloAsset      The yolo asset address.
     * @param   _ltv            The loan-to-value ratio to check against.
     */
    function _isSolvent(UserPosition storage _pos, address _collateral, address _yoloAsset, uint256 _ltv)
        internal
        view
        returns (bool)
    {
        uint256 collateralDecimals = IERC20Metadata(_collateral).decimals();
        uint256 yoloAssetDecimals = IERC20Metadata(_yoloAsset).decimals();

        uint256 colVal =
            yoloOracle.getAssetPrice(_collateral) * _pos.collateralSuppliedAmount / (10 ** collateralDecimals);
        uint256 debtVal = yoloOracle.getAssetPrice(_yoloAsset) * (_pos.yoloAssetMinted + _pos.accruedInterest)
            / (10 ** yoloAssetDecimals);

        return debtVal * PRECISION_DIVISOR <= colVal * _ltv;
    }

    /**
     * @notice  Internal function to burn pending tokens.
     * @dev     Since the asset settlement only happens after the router has settled, we need to
     *          keep pending tokens in memory and burn in either independantly or in the next swap.
     */
    function _burnPending() internal {
        Currency c = Currency.wrap(assetToBurn);
        c.settle(poolManager, address(this), amountToBurn, true); // burn the claim-tokens
        c.take(poolManager, address(this), amountToBurn, false); // pull the real tokens
        IYoloSyntheticAsset(assetToBurn).burn(address(this), amountToBurn); // burn the real tokens

        assetToBurn = address(0);
        amountToBurn = 0;
    }
}