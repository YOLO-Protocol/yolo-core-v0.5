// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IYoloOracle} from "@yolo/contracts/interfaces/IYoloOracle.sol";
import {IYoloSyntheticAsset} from "@yolo/contracts/interfaces/IYoloSyntheticAsset.sol";
import {ITeller} from "@yolo/contracts/interfaces/ITeller.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IStakedYoloUSD} from "../interfaces/IStakedYoloUSD.sol";

/**
 * @title   YoloStorage
 * @notice  Abstract contract defining the storage layout for YoloHook and delegated logic contracts
 * @dev     DO NOT DEPLOY - This contract only defines storage layout to ensure consistency across delegatecalls
 *          IMPORTANT: This must match YoloHook's storage layout exactly, excluding inherited storage
 */
abstract contract YoloStorage {
    // ========================
    // STORAGE LAYOUT - DO NOT REORDER
    // ========================

    // --- ReentrancyGuard Storage ---
    uint256 private _status;

    // --- Ownable Storage ---
    address private _owner;

    // --- Pausable Storage ---
    bool private _paused;

    // --- NOTE: poolManager from BaseHook is NOT included here ---
    // --- It exists in YoloHook at slot 2 through inheritance ---

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

    // NEW: Add missing logic contract addresses
    address public anchorPoolLogic;
    address public viewLogic;
    address public adminLogic;
    address public utilityLogic;

    // ========================
    // DATA STRUCTURES
    // ========================

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

    // ========================
    // CONSTANTS
    // ========================

    uint256 public constant PRECISION_DIVISOR = 10000;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant MINIMUM_LIQUIDITY = 1000;

    // NEW: Constants for compound interest calculations
    uint256 public constant RAY = 1e27; // Aave's 27 decimal precision
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    // Security constants
    uint256 internal constant DUST_THRESHOLD = 1e15; // 0.001 units (more meaningful than 1 wei)
    uint256 internal constant MINIMUM_BORROW_AMOUNT = 1e16; // 0.01 units minimum borrow

    // ========================
    // ERRORS
    // ========================

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

    // Hook-specific errors
    error YoloHook__ParamsLengthMismatched();
    error YoloHook__MustAddLiquidityThroughHook();
    error YoloHook__InvalidAddLiquidityParams();
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

    // ========================
    // EVENTS
    // ========================

    // Synthetic Asset Events
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

    // Hook-specific events
    event HookModifyLiquidity(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1);
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
    event FlashLoanExecuted(address indexed flashBorrower, address[] yoloAssets, uint256[] amounts, uint256[] fees);
    event BridgeRegistered(address indexed bridge);
    event CrossChainBurn(address indexed bridge, address indexed yoloAsset, uint256 amount, address indexed sender);
    event CrossChainMint(address indexed bridge, address indexed yoloAsset, uint256 amount, address indexed receiver);
    event LiquidityIndexUpdated(
        address indexed collateral, address indexed yoloAsset, uint256 oldIndex, uint256 newIndex
    );
}
