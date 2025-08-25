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
import {ITeller} from "@yolo/contracts/interfaces/ITeller.sol";
/*---------- IMPORT CONTRACTS ----------*/
import {YoloSyntheticAsset} from "@yolo/contracts/tokenization/YoloSyntheticAsset.sol";
import {InterestMath} from "../libraries/InterestMath.sol";
import {IStakedYoloUSD} from "../interfaces/IStakedYoloUSD.sol";
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
 *          https://devfolio.co/projects/yolo-protocol-06fe
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

    // ========================
    // STORAGE LAYOUT - MUST MATCH YoloStorage EXACTLY
    // ========================

    // --- YoloHook Core Storage ---
    address public treasury;
    IYoloOracle public yoloOracle;

    // Fee Configuration
    uint256 public stableSwapFee;
    uint256 public syntheticSwapFee;
    uint256 public flashLoanFee;

    // Anchor Pool & Stableswap
    IYoloSyntheticAsset public anchor;
    address public usdc;
    bytes32 public anchorPoolId;
    address public anchorPoolToken0;

    mapping(bytes32 => bool) public isAnchorPool;

    // NEW: sUSY Receipt Token Integration
    IStakedYoloUSD public sUSY;

    // Synthetic Pools
    mapping(bytes32 => bool) public isSyntheticPool;

    // Synthetic Swap Placeholders
    address public assetToBurn;
    uint256 public amountToBurn;

    uint256 internal USDC_SCALE_UP;

    // Anchor pool reserves
    uint256 public totalAnchorReserveUSDC;
    uint256 public totalAnchorReserveUSY;

    // Asset & Collateral Configurations
    mapping(address => bool) public isYoloAsset;
    mapping(address => bool) public isWhiteListedCollateral;

    mapping(address => YoloAssetConfiguration) public yoloAssetConfigs;
    mapping(address => CollateralConfiguration) public collateralConfigs;

    mapping(address => address[]) internal yoloAssetsToSupportedCollateral;
    mapping(address => address[]) internal collateralToSupportedYoloAssets;
    mapping(address => mapping(address => CollateralToYoloAssetConfiguration)) public pairConfigs;

    // User Positions
    mapping(address => mapping(address => mapping(address => UserPosition))) public positions;
    mapping(address => UserPositionKey[]) public userPositionKeys;

    // Delegation Logic Contracts
    address public syntheticAssetLogic;
    address public rehypothecationLogic;

    // Rehypothecation Configuration
    ITeller public usycTeller;
    IERC20 public usyc;
    bool public rehypothecationEnabled;
    uint256 public rehypothecationRatio;
    uint256 public usycBalance;

    // Storage variables for cost basis tracking
    uint256 internal usycCostBasisUSDC;
    uint256 internal usycQuantity;

    // Storage variables for pending rehypothecation
    uint256 internal _pendingRehypoUSDC;
    uint256 internal _pendingDehypoUSDC;

    // Additional storage (not in YoloStorage)
    address public registeredBridge;

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

    // Storage struct definitions (must match YoloStorage exactly)
    struct YoloAssetConfiguration {
        address yoloAssetAddress;
        uint256 maxMintableCap;
        uint256 maxFlashLoanableAmount;
    }

    struct CollateralConfiguration {
        address collateralAsset;
        uint256 maxSupplyCap;
    }

    struct CollateralToYoloAssetConfiguration {
        address collateral;
        address yoloAsset;
        uint256 interestRate;
        uint256 ltv;
        uint256 liquidationPenalty;
        // NEW: Global liquidity index tracking (27 decimal precision)
        uint256 liquidityIndexRay; // Current cumulative index
        uint256 lastUpdateTimestamp; // Last time index was updated
        // NEW: Expiration features
        bool isExpirable; // Whether positions in this pair expire
        uint256 expirePeriod; // Duration in seconds (e.g., 365 days, 6 months)
    }

    struct UserPosition {
        address borrower;
        address collateral;
        uint256 collateralSuppliedAmount;
        address yoloAsset;
        // UPDATED: Clean interest accounting for compound interest
        uint256 normalizedDebtRay; // Normalized total debt (includes principal + interest)
        uint256 normalizedPrincipalRay; // Normalized principal only (for interest calculation)
        uint256 userLiquidityIndexRay; // User's index when last updated
        uint256 lastUpdatedTimeStamp;
        uint256 storedInterestRate; // User's locked rate until renewal
        // NEW: Expiration tracking
        uint256 expiryTimestamp; // When position expires (0 if non-expirable)
    }

    struct UserPositionKey {
        address collateral;
        address yoloAsset;
    }

    // ==============================
    // CONSTANTS (must match YoloStorage)
    // ==============================
    uint256 public constant PRECISION_DIVISOR = 10000;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant MINIMUM_LIQUIDITY = 1000;

    // NEW: Constants for compound interest calculations
    uint256 public constant RAY = 1e27; // Aave's 27 decimal precision
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    // ==============================
    // ERRORS (must match YoloStorage)
    // ==============================

    // Synthetic Asset Errors
    error YoloHook__InsufficientAmount();
    error YoloHook__NotYoloAsset();
    error YoloHook__CollateralNotRecognized();
    error YoloHook__InvalidPair();
    error YoloHook__YoloAssetPaused();
    error YoloHook__CollateralPaused();
    error YoloHook__NotSolvent();
    error YoloHook__ExceedsYoloAssetMintCap();
    error YoloHook__ExceedsCollateralCap();
    error YoloHook__InvalidPosition();
    error YoloHook__NoDebt();
    error YoloHook__RepayExceedsDebt();
    error YoloHook__Solvent();
    error YoloHook__InvalidSeizeAmount();

    // NEW: Expiration errors
    error YoloHook__PositionNotExpirable();
    error YoloHook__PositionExpired();

    // Rehypothecation Errors
    error YoloHook__InvalidRehypothecationRatio();
    error YoloHook__RehypothecationDisabled();
    error YoloHook__ZeroAddress();

    // ***************//
    // *** EVENTS *** //
    // ************** //

    // Synthetic Asset Events (must match YoloStorage)
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
        uint256 collateralSeized,
        bool isExpiredLiquidation
    );

    // NEW: Expiration events
    event ExpirationConfigUpdated(
        address indexed collateral, address indexed yoloAsset, bool isExpirable, uint256 expirePeriod
    );
    event PositionRenewed(
        address indexed user,
        address indexed collateral,
        address indexed yoloAsset,
        uint256 newExpiryTime,
        uint256 feesPaid
    );

    // NEW: sUSY events
    event sUSYDeployed(address indexed sUSYAddress);

    // Rehypothecation Events
    event RehypothecationStatusUpdated(bool enabled);
    event RehypothecationConfigured(address indexed teller, address indexed usyc, uint256 ratio);
    event RehypothecationExecuted(bool isBuy, uint256 amount, uint256 received);
    event RehypothecationRebalanced(bool isBuy, uint256 amount, uint256 received);
    event EmergencyUSYCWithdrawal(uint256 usycAmount, uint256 usdcReceived);
    event RehypothecationGain(uint256 profit);
    event RehypothecationLoss(uint256 loss);

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

    // Events for borrow/repay/withdraw/liquidate are declared in YoloStorage

    event FlashLoanExecuted(address indexed flashBorrower, address[] yoloAssets, uint256[] amounts, uint256[] fees);

    // Rehypothecation events are declared in YoloStorage

    event BridgeRegistered(address indexed bridge);

    event CrossChainBurn(address indexed bridge, address indexed yoloAsset, uint256 amount, address indexed sender);

    event CrossChainMint(address indexed bridge, address indexed yoloAsset, uint256 amount, address indexed receiver);

    // Expiration and sUSY events are declared in YoloStorage
    event LiquidityIndexUpdated(
        address indexed collateral, address indexed yoloAsset, uint256 oldIndex, uint256 newIndex
    );

    // ***************//
    // *** ERRORS *** //
    // ************** //
    error Ownable__AlreadyInitialized();
    // Main errors inherited from YoloStorage, Hook-specific errors:
    error YoloHook__ParamsLengthMismatched();
    error YoloHook__MustAddLiquidityThroughHook();
    error YoloHook__InvalidAddLiuidityParams();
    error YoloHook__InsufficientLiquidityMinted();
    error YoloHook__InsufficientLiquidityBalance();
    error YoloHook__UnknownUnlockActionError();
    error YoloHook__InvalidPoolId();
    error YoloHook__InsufficientReserves();
    error YoloHook__StableswapConvergenceError();
    error YoloHook__InvalidOutput();
    error YoloHook__InvalidSwapAmounts();
    error YoloHook__InvalidPriceSource();
    error YoloHook__ExceedsFlashLoanCap();
    error YoloHook__NoPendingBurns();
    error YoloHook__NotBridge();

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

        // Approve PoolManager to spend hook's tokens for claim token management
        IERC20(_usdcAddress).approve(address(poolManager), type(uint256).max);
        IERC20(address(anchor)).approve(address(poolManager), type(uint256).max);

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

    /**
     * @notice  Set the rehypothecation logic contract address
     * @param   _rehypothecationLogic The address of the rehypothecation logic contract
     */
    function setRehypothecationLogic(address _rehypothecationLogic) external onlyOwner {
        if (_rehypothecationLogic == address(0)) revert YoloHook__ZeroAddress();
        rehypothecationLogic = _rehypothecationLogic;
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

        CollateralToYoloAssetConfiguration storage config = pairConfigs[_collateral][_yoloAsset];
        bool isNewPair = (config.collateral == address(0));

        if (!isNewPair) {
            // For existing pair, update global index with old rate first
            _updateGlobalLiquidityIndex(config, config.interestRate);
        }

        // Set/update configuration
        config.collateral = _collateral;
        config.yoloAsset = _yoloAsset;
        config.interestRate = _interestRate;
        config.ltv = _ltv;
        config.liquidationPenalty = _liquidationPenalty;

        if (isNewPair) {
            // Initialize liquidity index to RAY (1.0 in 27 decimals)
            config.liquidityIndexRay = RAY;
            config.lastUpdateTimestamp = block.timestamp;

            // Default expiration settings (can be updated later)
            config.isExpirable = false;
            config.expirePeriod = 0;

            // Only push to arrays if this is a new pair
            collateralToSupportedYoloAssets[_collateral].push(_yoloAsset);
            yoloAssetsToSupportedCollateral[_yoloAsset].push(_collateral);
        } else {
            // Update timestamp for new rate
            config.lastUpdateTimestamp = block.timestamp;
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

        // address oldPriceSource = yoloOracle.getSourceOfAsset(_asset);

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
        (bool success, bytes memory ret) = syntheticAssetLogic.delegatecall(
            abi.encodeWithSignature(
                "borrow(address,uint256,address,uint256)", _yoloAsset, _borrowAmount, _collateral, _collateralAmount
            )
        );
        if (!success) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
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
        (bool success, bytes memory ret) = syntheticAssetLogic.delegatecall(
            abi.encodeWithSignature(
                "repay(address,address,uint256,bool)", _collateral, _yoloAsset, _repayAmount, _claimCollateral
            )
        );
        if (!success) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /**
     * @notice  Redeem up to `amount` of your collateral, provided your loan stays solvent
     * @param   _collateral    The collateral token address
     * @param   _yoloAsset     The YoloAsset token address
     * @param   _amount        How much collateral to withdraw
     */
    function withdraw(address _collateral, address _yoloAsset, uint256 _amount) external nonReentrant whenNotPaused {
        (bool success, bytes memory ret) = syntheticAssetLogic.delegatecall(
            abi.encodeWithSignature("withdraw(address,address,uint256)", _collateral, _yoloAsset, _amount)
        );
        if (!success) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
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
        (bool success, bytes memory ret) = syntheticAssetLogic.delegatecall(
            abi.encodeWithSignature(
                "liquidate(address,address,address,uint256)", _user, _collateral, _yoloAsset, _repayAmount
            )
        );
        if (!success) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
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
        // Validation
        if (_maxUsdcAmount == 0 || _maxUsyAmount == 0 || _receiver == address(0)) {
            revert YoloHook__InvalidAddLiuidityParams();
        }
        require(address(sUSY) != address(0), "sUSY not initialized");

        uint256 maxUsdcAmountInWad = _toWadUSDC(_maxUsdcAmount);
        uint256 maxUsyAmountInWad = _maxUsyAmount;

        uint256 usdcUsed;
        uint256 usyUsed;
        uint256 liquidity;

        uint256 currentTotalSupply = sUSY.totalSupply();

        if (currentTotalSupply == 0) {
            // First liquidity - use the smaller side to enforce 1:1 ratio and mint sUSY 1:1 vs USD value
            uint256 minInWad = maxUsdcAmountInWad < maxUsyAmountInWad ? maxUsdcAmountInWad : maxUsyAmountInWad;
            usdcUsed = _fromWadUSDC(minInWad);
            usyUsed = minInWad;

            // Mint amount equals total USD value (USDC+USY) minus MINIMUM_LIQUIDITY
            uint256 valueAdded = minInWad + minInWad; // both sides equal in WAD
            if (valueAdded <= MINIMUM_LIQUIDITY) revert YoloHook__InsufficientAmount();
            liquidity = valueAdded - MINIMUM_LIQUIDITY;
            if (liquidity < _minLiquidityReceive) revert YoloHook__InsufficientLiquidityMinted();
            // Lock MINIMUM_LIQUIDITY permanently (non-zero burn address)
            sUSY.mint(address(1), MINIMUM_LIQUIDITY);
        } else {
            // Proportional liquidity to maintain pool ratio; mint sUSY based on USD value share
            uint256 totalReserveUsdcInWad = _toWadUSDC(totalAnchorReserveUSDC);
            uint256 totalReserveUsyInWad = totalAnchorReserveUSY;

            // Calculate optimal amounts maintaining current ratio
            uint256 optimalUsyInWad = (maxUsdcAmountInWad * totalReserveUsyInWad) / totalReserveUsdcInWad;
            if (optimalUsyInWad <= maxUsyAmountInWad) {
                usdcUsed = _fromWadUSDC(maxUsdcAmountInWad);
                usyUsed = optimalUsyInWad;
            } else {
                uint256 optimalUsdcInWad = (maxUsyAmountInWad * totalReserveUsdcInWad) / totalReserveUsyInWad;
                usdcUsed = _fromWadUSDC(optimalUsdcInWad);
                usyUsed = maxUsyAmountInWad;
            }

            // Mint sUSY in proportion to value share
            uint256 valueAdded = _toWadUSDC(usdcUsed) + usyUsed;
            uint256 totalValueBefore = totalReserveUsdcInWad + totalReserveUsyInWad;
            liquidity = (valueAdded * currentTotalSupply) / totalValueBefore;
            if (liquidity < _minLiquidityReceive) revert YoloHook__InsufficientLiquidityMinted();
        }

        // Execute transfers - hook receives the tokens
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcUsed);
        IERC20(address(anchor)).safeTransferFrom(msg.sender, address(this), usyUsed);

        // Convert real tokens to PM claim-tokens and update reserves via unlock callback
        poolManager.unlock(
            abi.encode(
                CallbackData({
                    action: 0,
                    data: abi.encode(
                        AddLiquidityCallbackData({
                            sender: msg.sender,
                            receiver: _receiver,
                            usdcUsed: usdcUsed,
                            usyUsed: usyUsed,
                            liquidity: liquidity
                        })
                    )
                })
            )
        );

        // Mint sUSY receipt tokens after successful settlement
        sUSY.mint(_receiver, liquidity);

        return (usdcUsed, usyUsed, liquidity, _receiver);
    }

    function unlockCallback(bytes calldata _callbackData) external onlyPoolManager returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(_callbackData, (CallbackData));
        uint8 action = callbackData.action;

        if (action == 0) {
            // CASE A: Add Liquidity
            AddLiquidityCallbackData memory data = abi.decode(callbackData.data, (AddLiquidityCallbackData));
            address receiver = data.receiver; // Receiver of LP tokens, not used in this hook
            uint256 usdcUsed = data.usdcUsed; // USDC used in raw format
            uint256 usyUsed = data.usyUsed; // USY used in raw format
            uint256 liquidity = data.liquidity; // LP tokens minted

            // Handle claim tokens properly
            Currency cUSDC = Currency.wrap(usdc);
            Currency cUSY = Currency.wrap(address(anchor));

            // The hook already has the real tokens from addLiquidity
            // Now deposit them to PoolManager to get claim tokens
            
            // Settle = hook pays real tokens to PoolManager
            cUSDC.settle(poolManager, address(this), usdcUsed, false);
            cUSY.settle(poolManager, address(this), usyUsed, false);

            // Take = hook receives claim tokens from PoolManager
            cUSDC.take(poolManager, address(this), usdcUsed, true);
            cUSY.take(poolManager, address(this), usyUsed, true);

            // NOW we have the USDC, so rehypothecate

            // Update state
            totalAnchorReserveUSDC += usdcUsed; // raw USDC (6-dec)
            totalAnchorReserveUSY += usyUsed; // USY (18-dec)

            // Note: sUSY minting is handled in addLiquidity function, not here
            // This callback only handles the token transfers via PoolManager
            // emit AnchorLiquidityAdded(sender, receiver, usdcUsed, usyUsed, liquidity);

            return abi.encode(address(this), receiver, usdcUsed, usyUsed, liquidity);
        } else if (action == 1) {
            // CASE B: Remove Liquidity
            RemoveLiquidityCallbackData memory data = abi.decode(callbackData.data, (RemoveLiquidityCallbackData));
            address initiator = data.initiator; // User who initiated the removal
            address receiver = data.receiver; // User who receives the USDC and USY
            uint256 usdcAmount = data.usdcAmount; // USDC amount to return
            uint256 usyAmount = data.usyAmount; // USY amount to return
            uint256 liquidity = data.liquidity; // LP tokens burnt

            // Note: sUSY burning is handled in removeLiquidity function, not here
            // This callback only handles the token transfers

            // Update reserves
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
        } else if (action == 3) {
            // CASE D: Pull Real USDC
            uint256 amt = abi.decode(callbackData.data, (uint256));
            Currency cUSDC = Currency.wrap(usdc);

            // burn claim-tokens we currently hold
            cUSDC.settle(poolManager, address(this), amt, true);
            // receive the underlying ERC-20
            cUSDC.take(poolManager, address(this), amt, false);
            return abi.encode(amt);
        } else if (action == 4) {
            // CASE E: Push Real USDC
            uint256 amt = abi.decode(callbackData.data, (uint256));
            Currency cUSDC = Currency.wrap(usdc);

            // hand ERC-20 back to PM and get fresh claim-tokens
            cUSDC.settle(poolManager, address(this), amt, false);
            return abi.encode(amt);
        } else {
            revert YoloHook__UnknownUnlockActionError();
        }
    }

    /**
     * @notice  Remove liquidity from the anchor pool
     * @param   _minUSDC    Minimum USDC to receive
     * @param   _minUSY     Minimum USY to receive
     * @param   _liquidity  Amount of sUSY tokens to burn
     * @param   _receiver   Address to receive the USDC and USY
     */
    function removeLiquidity(uint256 _minUSDC, uint256 _minUSY, uint256 _liquidity, address _receiver)
        external
        whenNotPaused
        returns (uint256 usdcAmount, uint256 usyAmount, uint256 liquidity, address receiver)
    {
        // Validation
        require(_liquidity > 0, "Invalid liquidity amount");
        require(_receiver != address(0), "Invalid receiver");
        require(address(sUSY) != address(0), "sUSY not initialized");

        uint256 totalSupply = sUSY.totalSupply();
        require(totalSupply > 0, "No liquidity in pool");
        if (sUSY.balanceOf(msg.sender) < _liquidity) revert YoloHook__InsufficientLiquidityBalance();

        // Calculate proportional amounts (rounding down to benefit pool)
        usdcAmount = (_liquidity * totalAnchorReserveUSDC) / totalSupply;
        usyAmount = (_liquidity * totalAnchorReserveUSY) / totalSupply;

        if (usdcAmount < _minUSDC) revert YoloHook__InsufficientAmount();
        if (usyAmount < _minUSY) revert YoloHook__InsufficientAmount();

        // Handle rehypothecation if needed
        _handleDehypothecation(usdcAmount);

        // DO NOT update reserves here - let unlockCallback do it
        // totalAnchorReserveUSDC and totalAnchorReserveUSY will be updated in unlockCallback

        // Burn sUSY tokens from user
        sUSY.burn(msg.sender, _liquidity);

        // Settle transfers via PoolManager unlock callback (action 1)
        poolManager.unlock(
            abi.encode(
                CallbackData({
                    action: 1,
                    data: abi.encode(
                        RemoveLiquidityCallbackData({
                            initiator: msg.sender,
                            receiver: _receiver,
                            usdcAmount: usdcAmount,
                            usyAmount: usyAmount,
                            liquidity: _liquidity
                        })
                    )
                })
            )
        );

        // Emit liquidity event for compatibility
        if (anchorPoolToken0 == usdc) {
            emit HookModifyLiquidity(anchorPoolId, _receiver, -int128(int256(usdcAmount)), -int128(int256(usyAmount)));
        } else {
            emit HookModifyLiquidity(anchorPoolId, _receiver, -int128(int256(usyAmount)), -int128(int256(usdcAmount)));
        }

        return (usdcAmount, usyAmount, _liquidity, _receiver);
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
            // Use the pool's currencies from the PoolKey, not the raw token addresses
            Currency cIn = params.zeroForOne ? key.currency0 : key.currency1;
            Currency cOut = params.zeroForOne ? key.currency1 : key.currency0;

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

            // Update reserves: only the net input increases reserves; fee is forwarded to treasury
            if (usdcToUsy) {
                totalAnchorReserveUSDC = rIn + nIn;
                totalAnchorReserveUSY = rOut - out;
                _pendingRehypoUSDC = nIn; // only net input can be rehypothecated
            } else {
                totalAnchorReserveUSY = rIn + nIn;
                totalAnchorReserveUSDC = rOut - out;
                _pendingDehypoUSDC = out;
            }

            // Settlement - pull net input to hook, forward fee to treasury, and mint output to hook
            cIn.take(poolManager, address(this), nIn, true);
            if (f > 0) {
                // Send fee to treasury as real tokens
                cIn.take(poolManager, treasury, f, false);
            }
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

            int128 delta0 = exactIn ? int128(uint128(gIn)) : -int128(uint128(out));
            int128 delta1 = exactIn ? -int128(uint128(out)) : int128(uint128(gIn));
            
            return (
                this.beforeSwap.selector,
                toBeforeSwapDelta(delta0, delta1),
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

            int128 delta0 = exactIn ? int128(uint128(gIn)) : -int128(uint128(out));
            int128 delta1 = exactIn ? -int128(uint128(out)) : int128(uint128(gIn));
            
            return (
                this.beforeSwap.selector,
                toBeforeSwapDelta(delta0, delta1),
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
        // Handle pending rehypothecation
        if (_pendingRehypoUSDC > 0) {
            _handleRehypothecation(_pendingRehypoUSDC);
            _pendingRehypoUSDC = 0;
        }

        // Handle pending dehypothecation
        if (_pendingDehypoUSDC > 0) {
            _handleDehypothecation(_pendingDehypoUSDC);
            _pendingDehypoUSDC = 0;
        }

        return (this.afterSwap.selector, int128(0));
    }

    // ******************************//
    // *** CROSS CHAIN FUNCTIONS *** //
    // ***************************** //

    /**
     * @notice  Modifier to ensure only the registered bridge can call certain functions
     */
    modifier onlyBridge() {
        if (msg.sender != registeredBridge) revert YoloHook__NotBridge();
        _;
    }

    /**
     * @notice  Register a bridge contract that can mint/burn YoloAssets for cross-chain transfers
     * @param   _bridgeAddress  The address of the bridge contract to register
     */
    function registerBridge(address _bridgeAddress) external onlyOwner {
        if (_bridgeAddress == address(0)) revert YoloHook__ZeroAddress();

        registeredBridge = _bridgeAddress;

        emit BridgeRegistered(_bridgeAddress);
    }

    /**
     * @notice  Burn YoloAssets for cross-chain transfer (called by registered bridge)
     * @param   _yoloAsset  The YoloAsset to burn
     * @param   _amount     The amount to burn
     * @param   _sender     The original sender of the tokens
     */
    function crossChainBurn(address _yoloAsset, uint256 _amount, address _sender) external onlyBridge {
        if (!isYoloAsset[_yoloAsset]) revert YoloHook__NotYoloAsset();
        if (_amount == 0) revert YoloHook__InsufficientAmount();

        // Burn the tokens from the sender
        IYoloSyntheticAsset(_yoloAsset).burn(_sender, _amount);

        emit CrossChainBurn(msg.sender, _yoloAsset, _amount, _sender);
    }

    /**
     * @notice  Mint YoloAssets for cross-chain transfer (called by registered bridge)
     * @param   _yoloAsset  The YoloAsset to mint
     * @param   _amount     The amount to mint
     * @param   _receiver   The receiver of the minted tokens
     */
    function crossChainMint(address _yoloAsset, uint256 _amount, address _receiver) external onlyBridge {
        if (!isYoloAsset[_yoloAsset]) revert YoloHook__NotYoloAsset();
        if (_amount == 0) revert YoloHook__InsufficientAmount();
        if (_receiver == address(0)) revert YoloHook__ZeroAddress();

        // Check if minting would exceed the cap
        YoloAssetConfiguration storage config = yoloAssetConfigs[_yoloAsset];
        if (config.maxMintableCap > 0) {
            uint256 currentSupply = IERC20(_yoloAsset).totalSupply();
            if (currentSupply + _amount > config.maxMintableCap) {
                revert YoloHook__ExceedsYoloAssetMintCap();
            }
        }

        // Mint the tokens to the receiver
        IYoloSyntheticAsset(_yoloAsset).mint(_receiver, _amount);

        emit CrossChainMint(msg.sender, _yoloAsset, _amount, _receiver);
    }

    // ***********************//
    // *** VIEW FUNCTIONS *** //
    // ********************** //

    // **********************************//
    // *** REHYPOTHECATION FUNCTIONS *** //
    // ********************************* //

    /**
     * @notice  Enable or disable rehypothecation functionality
     * @param   _enabled  Whether to enable rehypothecation
     */
    function setRehypothecationEnabled(bool _enabled) external onlyOwner {
        // flip the switch & announce
        rehypothecationEnabled = _enabled;
        emit RehypothecationStatusUpdated(_enabled);

        // If disabling: unwind every­thing so the anchor-pool maths stay simple
        if (!_enabled && usycBalance > 0) {
            _sellUSYC(usycBalance); // this sells and *already* converts the USDC to claim-tokens
            // zero-out trackers
            usycBalance = 0;
            usycQuantity = 0;
            usycCostBasisUSDC = 0;
        }
    }

    // function setRehypothecationEnabled(bool _enabled) external onlyOwner {
    //     // // If disabling and we have USYC balance, convert it back to USDC
    //     // if (!_enabled && rehypothecationEnabled && usycBalance > 0) {
    //     //     // Sell all USYC back to USDC
    //     //     uint256 usdcReceived = _sellUSYC(usycBalance);
    //     //     uint256 withdrawnAmount = usycBalance;
    //     //     usycBalance = 0;

    //     //     emit EmergencyUSYCWithdrawal(withdrawnAmount, usdcReceived);
    //     // }

    //     // rehypothecationEnabled = _enabled;
    //     // emit RehypothecationStatusUpdated(_enabled);
    //     // flip the switch & announce first
    //     // rehypothecationEnabled = _enabled;
    //     // emit RehypothecationStatusUpdated(_enabled);

    //     // // if we are turning the feature *off*: unwind every-thing
    //     // if (!_enabled && usycBalance > 0) {
    //     //     uint256 withdrawn = usycBalance;
    //     //     uint256 received = _sellUSYC(withdrawn); // Sell USYC back to USDC
    //     //     usycBalance = 0;
    //     //     usycQuantity = 0;
    //     //     usycCostBasisUSDC = 0;
    //     //     emit EmergencyUSYCWithdrawal(withdrawn, received);
    //     // }
    //     // flip the switch & announce first
    //     rehypothecationEnabled = _enabled;
    //     emit RehypothecationStatusUpdated(_enabled);

    //     // turning OFF → unwind all USYC into USDC so pool maths stay sane
    //     if (!_enabled && usycBalance > 0) {
    //         _sellUSYC(usycBalance); // converts to real USDC
    //         // push the freshly-received USDC straight back as claim-tokens
    //         _pushRealUSDC(totalAnchorReserveUSDC); // action-4 handles PM unlock
    //         // clear trackers
    //         usycBalance = 0;
    //         usycQuantity = 0;
    //         usycCostBasisUSDC = 0;
    //     }
    // }

    /**
     * @notice  Configure rehypothecation parameters
     * @param   _usycTeller  Address of the USYC Teller contract
     * @param   _usyc        Address of the USYC token
     * @param   _ratio       Maximum percentage of USDC to rehypothecate (e.g., 7500 = 75%)
     */
    function configureRehypothecation(address _usycTeller, address _usyc, uint256 _ratio) external onlyOwner {
        if (_usycTeller == address(0) || _usyc == address(0)) revert YoloHook__ZeroAddress();
        if (_ratio > PRECISION_DIVISOR) revert YoloHook__InvalidRehypothecationRatio();

        usycTeller = ITeller(_usycTeller);
        usyc = IERC20(_usyc);
        rehypothecationRatio = _ratio;

        // Approve USYC Teller to spend USDC
        IERC20(usdc).approve(_usycTeller, type(uint256).max);

        emit RehypothecationConfigured(_usycTeller, _usyc, _ratio);
    }

    /**
     * @notice  Internal function to buy USYC and track cost basis
     * @param   _usdcAmount  Amount of USDC to spend
     * @return  usycOut      Amount of USYC received
     */
    function _buyUSYC(uint256 _usdcAmount) internal returns (uint256 usycOut) {
        (bool success, bytes memory ret) =
            rehypothecationLogic.delegatecall(abi.encodeWithSignature("buyUSYC(uint256)", _usdcAmount));
        if (!success) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return abi.decode(ret, (uint256));
    }

    /**
     * @notice  Internal function to sell USYC and realize P&L
     * @param   _usycAmount  Amount of USYC to sell
     * @return  usdcOut      Amount of USDC received
     */
    function _sellUSYC(uint256 _usycAmount) internal returns (uint256 usdcOut) {
        (bool success, bytes memory ret) =
            rehypothecationLogic.delegatecall(abi.encodeWithSignature("sellUSYC(uint256)", _usycAmount));
        if (!success) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return abi.decode(ret, (uint256));
    }

    /**
     * @notice  Internal function to handle rehypothecation during swaps
     * @dev     Called in _afterSwap for anchor pool when USDC is coming in
     * @param   _usdcAmount  Amount of USDC being added to reserves (not used due to double-counting fix)
     */
    function _handleRehypothecation(uint256 _usdcAmount) internal {
        (bool success, bytes memory ret) =
            rehypothecationLogic.delegatecall(abi.encodeWithSignature("handleRehypothecation(uint256)", _usdcAmount));
        if (!success) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /**
     * @notice  Internal function to handle de-hypothecation when USDC is needed
     * @dev     Called when removing liquidity or during swaps that reduce USDC reserves
     * @param   _usdcNeeded  Amount of USDC needed
     */
    function _handleDehypothecation(uint256 _usdcNeeded) internal {
        (bool success, bytes memory ret) =
            rehypothecationLogic.delegatecall(abi.encodeWithSignature("handleDehypothecation(uint256)", _usdcNeeded));
        if (!success) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /**
     * @notice  Manually rebalance rehypothecation to target ratio
     * @dev     Can be called by owner to rebalance outside of normal operations
     */
    function rebalanceRehypothecation() external onlyOwner {
        (bool success, bytes memory ret) =
            rehypothecationLogic.delegatecall(abi.encodeWithSignature("rebalanceRehypothecation()"));
        if (!success) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /**
     * @notice  Emergency function to withdraw all USYC and convert back to USDC
     * @dev     Only callable by owner in emergency situations
     */
    function emergencyWithdrawUSYC() external onlyOwner {
        (bool success, bytes memory ret) =
            rehypothecationLogic.delegatecall(abi.encodeWithSignature("emergencyWithdrawUSYC()"));
        if (!success) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

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
     * @notice Get current debt amount for a position with compound interest
     * @param _user User address
     * @param _collateral Collateral asset address
     * @param _yoloAsset Yolo asset address
     * @return actualDebt Current debt including compound interest
     */
    function getCurrentDebt(address _user, address _collateral, address _yoloAsset)
        public
        view
        returns (uint256 actualDebt)
    {
        UserPosition storage position = positions[_user][_collateral][_yoloAsset];
        CollateralToYoloAssetConfiguration storage config = pairConfigs[_collateral][_yoloAsset];

        if (position.normalizedDebtRay == 0) return 0;

        // Calculate effective global index with time since last config update
        uint256 timeDelta = block.timestamp - config.lastUpdateTimestamp;
        uint256 effectiveIndex =
            InterestMath.calculateEffectiveIndex(config.liquidityIndexRay, position.storedInterestRate, timeDelta);

        // Actual debt = normalizedDebtRay * effectiveIndex / RAY (round UP for user obligations)
        return divUp(position.normalizedDebtRay * effectiveIndex, RAY);
    }

    /**
     * @notice Check if a user position is solvent
     * @param _user User address
     * @param _collateral Collateral asset address
     * @param _yoloAsset Yolo asset address
     * @param _ltv LTV ratio to check against
     * @return solvent Whether position is solvent
     */
    function isPositionSolvent(address _user, address _collateral, address _yoloAsset, uint256 _ltv)
        public
        view
        returns (bool solvent)
    {
        UserPosition storage position = positions[_user][_collateral][_yoloAsset];

        if (position.borrower == address(0)) return true; // No position

        uint256 collateralDecimals = IERC20Metadata(_collateral).decimals();
        uint256 yoloAssetDecimals = IERC20Metadata(_yoloAsset).decimals();

        // Get current collateral value
        uint256 colVal =
            yoloOracle.getAssetPrice(_collateral) * position.collateralSuppliedAmount / (10 ** collateralDecimals);

        // Get current debt with compound interest
        uint256 currentDebt = getCurrentDebt(_user, _collateral, _yoloAsset);
        uint256 debtVal = yoloOracle.getAssetPrice(_yoloAsset) * currentDebt / (10 ** yoloAssetDecimals);

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

    // ========================
    // sUSY INTEGRATION FUNCTIONS
    // ========================

    /**
     * @notice Set the sUSY token contract address
     * @param _sUSYAddress Address of the deployed sUSY token
     */
    function setSUSYToken(address _sUSYAddress) external onlyOwner {
        if (_sUSYAddress == address(0)) revert YoloHook__ZeroAddress();
        sUSY = IStakedYoloUSD(_sUSYAddress);
        emit sUSYDeployed(_sUSYAddress);
    }

    /**
     * @notice Get total USD value of anchor pool reserves (for sUSY exchange rate)
     * @return totalValue Combined USD value of USDC + USY reserves (18 decimals)
     */
    function getTotalAnchorPoolValue() external view returns (uint256 totalValue) {
        // Convert USDC (6 decimals) to 18 decimals (treat as $1)
        uint256 usdcValue18 = _toWadUSDC(totalAnchorReserveUSDC);
        // USY is 18 decimals and treated as $1 in the stable anchor pool
        uint256 usyValue18 = totalAnchorReserveUSY;
        return usdcValue18 + usyValue18;
    }

    // ========================
    // EXPIRATION MANAGEMENT FUNCTIONS
    // ========================

    /**
     * @notice Configure expiration settings for a collateral-asset pair
     * @param _collateral Collateral asset address
     * @param _yoloAsset Yolo asset address
     * @param _isExpirable Whether positions in this pair expire
     * @param _expirePeriod Duration in seconds (e.g., 365 days)
     */
    function setExpirationConfig(address _collateral, address _yoloAsset, bool _isExpirable, uint256 _expirePeriod)
        external
        onlyOwner
    {
        if (!isWhiteListedCollateral[_collateral]) revert YoloHook__CollateralNotRecognized();
        if (!isYoloAsset[_yoloAsset]) revert YoloHook__NotYoloAsset();

        CollateralToYoloAssetConfiguration storage config = pairConfigs[_collateral][_yoloAsset];
        if (config.collateral == address(0)) revert YoloHook__InvalidPair();

        config.isExpirable = _isExpirable;
        config.expirePeriod = _expirePeriod;

        emit ExpirationConfigUpdated(_collateral, _yoloAsset, _isExpirable, _expirePeriod);
    }

    /**
     * @notice Renew an expired position (delegatecall to SyntheticAssetLogic)
     * @param _collateral Collateral asset address
     * @param _yoloAsset Yolo asset address
     */
    function renewPosition(address _collateral, address _yoloAsset) external nonReentrant whenNotPaused {
        (bool success, bytes memory result) = syntheticAssetLogic.delegatecall(
            abi.encodeWithSignature("renewPosition(address,address)", _collateral, _yoloAsset)
        );
        if (!success) {
            if (result.length > 0) {
                assembly {
                    revert(add(32, result), mload(result))
                }
            } else {
                revert("Renewal failed");
            }
        }
    }

    /**
     * @notice Check if a position is expired
     * @param _user User address
     * @param _collateral Collateral asset address
     * @param _yoloAsset Yolo asset address
     * @return expired Whether the position is expired
     * @return expiryTime The expiry timestamp (0 if non-expirable)
     */
    function getPositionExpiration(address _user, address _collateral, address _yoloAsset)
        external
        view
        returns (bool expired, uint256 expiryTime)
    {
        UserPosition storage position = positions[_user][_collateral][_yoloAsset];

        if (position.borrower == address(0)) {
            return (false, 0); // No position exists
        }

        expiryTime = position.expiryTimestamp;
        expired = (expiryTime > 0 && block.timestamp >= expiryTime);
    }

    // ========================
    // HELPER FUNCTIONS
    // ========================

    /**
     * @notice Helper function for ceiling division (rounds up)
     * @dev Used to ensure protocol always rounds in its favor for user obligations
     * @param a Numerator
     * @param b Denominator
     * @return Result rounded up
     */
    function divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

    /**
     * @notice Update global liquidity index with compound interest
     * @param config The pair configuration to update
     * @param rateBps Interest rate in basis points
     */
    function _updateGlobalLiquidityIndex(CollateralToYoloAssetConfiguration storage config, uint256 rateBps) internal {
        // Initialize check for safety
        if (config.liquidityIndexRay == 0) {
            config.liquidityIndexRay = RAY;
            config.lastUpdateTimestamp = block.timestamp;
            return;
        }

        uint256 timeDelta = block.timestamp - config.lastUpdateTimestamp;
        if (timeDelta == 0) return;

        uint256 oldIndex = config.liquidityIndexRay;
        config.liquidityIndexRay = InterestMath.calculateLinearInterest(config.liquidityIndexRay, rateBps, timeDelta);
        config.lastUpdateTimestamp = block.timestamp;

        // Emit event for transparency
        emit LiquidityIndexUpdated(config.collateral, config.yoloAsset, oldIndex, config.liquidityIndexRay);
    }

    // ========================
    // VIEW FUNCTIONS FOR POSITION HEALTH
    // ========================

    /**
     * @notice Get comprehensive position health information
     * @param _user User address
     * @param _collateral Collateral asset address
     * @param _yoloAsset Yolo asset address
     * @return currentDebt Current debt with accrued interest
     * @return currentPrincipal Current principal amount
     * @return accruedInterest Interest that has accrued
     * @return healthFactor Position health factor (1e18 = 100%)
     * @return isExpired Whether the position has expired
     */
    function getPositionHealth(address _user, address _collateral, address _yoloAsset)
        external
        view
        returns (
            uint256 currentDebt,
            uint256 currentPrincipal,
            uint256 accruedInterest,
            uint256 healthFactor,
            bool isExpired
        )
    {
        UserPosition storage pos = positions[_user][_collateral][_yoloAsset];
        CollateralToYoloAssetConfiguration storage cfg = pairConfigs[_collateral][_yoloAsset];

        if (pos.borrower == address(0)) {
            return (0, 0, 0, type(uint256).max, false); // No position
        }

        // Calculate effective global index without storage writes
        uint256 timeDelta = block.timestamp - cfg.lastUpdateTimestamp;
        uint256 effectiveIndex = InterestMath.calculateLinearInterest(
            cfg.liquidityIndexRay,
            pos.storedInterestRate, // User's locked rate
            timeDelta
        );

        // Debt accrues with index; principal remains constant
        currentDebt = (pos.normalizedDebtRay * effectiveIndex) / RAY;
        currentPrincipal = (pos.normalizedPrincipalRay * pos.userLiquidityIndexRay) / RAY;
        accruedInterest = currentDebt - currentPrincipal;

        // Calculate health factor
        uint256 collateralDecimals = IERC20Metadata(_collateral).decimals();
        uint256 yoloAssetDecimals = IERC20Metadata(_yoloAsset).decimals();

        uint256 collateralValue =
            yoloOracle.getAssetPrice(_collateral) * pos.collateralSuppliedAmount / (10 ** collateralDecimals);
        uint256 debtValue = yoloOracle.getAssetPrice(_yoloAsset) * currentDebt / (10 ** yoloAssetDecimals);

        healthFactor = debtValue > 0 ? (collateralValue * cfg.ltv) / (debtValue * PRECISION_DIVISOR) : type(uint256).max;

        // Check expiration
        isExpired = cfg.isExpirable && pos.expiryTimestamp > 0 && block.timestamp >= pos.expiryTimestamp;
    }
}
