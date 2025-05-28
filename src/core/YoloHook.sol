// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/*---------- IMPORT LIBRARIES & TYPES ----------*/
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol"; /*---------- IMPORT INTERFACES ----------*/
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
/*---------- IMPORT INTERFACES ----------*/
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "@yolo/contracts/interfaces/IWETH.sol";
import {IYoloOracle} from "@yolo/contracts/interfaces/IYoloOracle.sol";
import {IYoloSyntheticAsset} from "@yolo/contracts/interfaces/IYoloSyntheticAsset.sol";
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

    // ***************** //
    // *** DATATYPES *** //
    // ***************** //

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
    uint256 public hookSwapFee;
    uint256 public flashLoanFee;

    /*----- Anchor Pool -----*/
    IYoloSyntheticAsset public anchor;
    address public usdc; // USDC address, used in the anchor pool to pair with USY
    mapping(bytes32 => bool) public isAnchorPool;

    /*----- Aseet & Collateral Configurations -----*/
    mapping(address => bool) public isYoloAsset; // Mapping to check if an address is a Yolo asset
    mapping(address => bool) public isWhiteListedCollateral; // Mapping to check if an address is a whitelisted collateral asset

    mapping(address => YoloAssetConfiguration) public yoloAssetConfigs; // Maps Yolo assets to its configuration
    mapping(address => CollateralConfiguration) public collateralConfigs; // Maps collateral to its configuration

    // ***************//
    // *** EVENTS *** //
    // ************** //

    // ***************//
    // *** ERRORS *** //
    // ************** //
    error YoloHook_ZeroAddress();

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
     */
    function initialize(
        address _wethAddress,
        address _treasury,
        address _yoloOracle,
        uint256 _hookSwapFee,
        uint256 _flashLoanFee,
        address _usdc
    ) external onlyOwner {
        // Guard clause: ensure that the addresses are not zero
        if (_wethAddress == address(0) || _treasury == address(0) || _yoloOracle == address(0) || _usdc == address(0)) {
            revert YoloHook_ZeroAddress();
        }
        // Initialize the BaseHook with paramaters
        weth = IWETH(_wethAddress);
        treasury = _treasury;
        yoloOracle = IYoloOracle(_yoloOracle);
        hookSwapFee = _hookSwapFee;
        flashLoanFee = _flashLoanFee;
        usdc = _usdc;

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
        poolManager.initialize(pk, uint160(1) << 96);
        isAnchorPool[PoolId.unwrap(pk.toId())] = true;
    }

    // ***************************** //
    // *** USER FACING FUNCTIONS *** //
    // ***************************** //

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
}
