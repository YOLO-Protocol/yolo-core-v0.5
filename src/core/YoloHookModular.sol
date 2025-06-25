// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IWETH} from "@yolo/contracts/interfaces/IWETH.sol";
import {IYoloOracle} from "@yolo/contracts/interfaces/IYoloOracle.sol";
import {IYoloSyntheticAsset} from "@yolo/contracts/interfaces/IYoloSyntheticAsset.sol";
import {YoloSyntheticAsset} from "@yolo/contracts/tokenization/YoloSyntheticAsset.sol";
import {IPoolManager, ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract YoloHookModular is BaseHook, ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    // Logic contract addresses
    address public anchorLogic;
    address public syntheticLogic;
    address public borrowLogic;

    // All original storage variables remain here
    struct AddLiquidityCallbackData {
        address sender;
        address receiver;
        uint256 maxUsdcAmount;
        uint256 maxUsyAmount;
        uint256 minLiquidityReceive;
    }

    struct RemoveLiquidityCallbackData {
        address initiator;
        address receiver;
        uint256 usdcAmount;
        uint256 usyAmount;
        uint256 liquidity;
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

    struct CallbackData {
        uint256 action;
        bytes data;
    }

    // Contract variables
    address public treasury;
    IWETH public weth;
    IYoloOracle public yoloOracle;
    address public swapRouter;

    uint256 public stableSwapFee;
    uint256 public syntheticSwapFee;
    uint256 public flashLoanFee;

    IYoloSyntheticAsset public anchor;
    address public usdc;
    bytes32 public anchorPoolId;
    address public anchorPoolToken0;
    address public anchorPoolToken1;

    mapping(bytes32 => bool) public isAnchorPool;
    uint256 public anchorPoolLiquiditySupply;
    mapping(address => uint256) public anchorPoolLPBalance;

    mapping(bytes32 => bool) public isSyntheticPool;

    address private assetToBurn;
    uint256 private amountToBurn;
    uint256 private USDC_SCALE_UP;

    uint256 public totalAnchorReserveUSDC;
    uint256 public totalAnchorReserveUSY;

    uint256 private constant MINIMUM_LIQUIDITY = 1000;
    uint256 private constant MATH_PRECISION = 1e18;
    uint8 private constant STABLESWAP_ITERATIONS = 255;
    uint256 private constant PRECISION_DIVISOR = 10000;

    mapping(address => bool) public isYoloAsset;
    mapping(address => bool) public isWhiteListedCollateral;
    mapping(address => YoloAssetConfiguration) public yoloAssetConfigs;
    mapping(address => CollateralConfiguration) public collateralConfigs;
    mapping(address => address[]) yoloAssetsToSupportedCollateral;
    mapping(address => address[]) collateralToSupportedYoloAssets;
    mapping(address => mapping(address => CollateralToYoloAssetConfiguration)) public pairConfigs;

    mapping(address => UserPosition[]) userAllPositions;
    mapping(address => mapping(address => mapping(address => UserPosition))) public positions;
    mapping(address => UserPositionKey[]) public userPositionKeys;

    // Events (keeping all original events)
    event HookSwap(
        bytes32 indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint128 hookLPfeeAmount0,
        uint128 hookLPfeeAmount1
    );

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

    // All other events...
    event UpdateFlashLoanFee(uint256 newFlashLoanFee, uint256 oldFlashLoanFee);
    event UpdateSyntheticSwapFee(uint256 newSyntheticSwapFee, uint256 oldSynthethicSwapFee);
    event UpdateStableSwapFee(uint256 newStableSwapFee, uint256 oldStableSwapFee);
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
    event PairConfigRemoved(address collateral, address yoloAsset);

    // All errors
    error Ownable__AlreadyInitialized();
    error YoloHook__ParamsLengthMismatched();
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
    error CustomRevert__uint256(uint256 num);
    error CustomRevert__int256(int256 num);

    constructor(address _v4PoolManager) Ownable(msg.sender) BaseHook(IPoolManager(_v4PoolManager)) {}

    // Initialize function with logic contract setup
    function initialize(
        address _wethAddress,
        address _treasury,
        address _yoloOracle,
        uint256 _stableSwapFee,
        uint256 _syntheticSwapFee,
        uint256 _flashLoanFee,
        address _usdcAddress,
        address _anchorLogic,
        address _syntheticLogic,
        address _borrowLogic
    ) external {
        if (
            _wethAddress == address(0) || _treasury == address(0) || _yoloOracle == address(0)
                || _usdcAddress == address(0)
        ) {
            revert YoloHook__ZeroAddress();
        }

        if (owner() != address(0)) revert Ownable__AlreadyInitialized();
        _transferOwnership(msg.sender);

        // Set logic contracts
        anchorLogic = _anchorLogic;
        syntheticLogic = _syntheticLogic;
        borrowLogic = _borrowLogic;

        // Initialize BaseHook with parameters
        weth = IWETH(_wethAddress);
        treasury = _treasury;
        yoloOracle = IYoloOracle(_yoloOracle);
        stableSwapFee = _stableSwapFee;
        syntheticSwapFee = _syntheticSwapFee;
        flashLoanFee = _flashLoanFee;
        usdc = _usdcAddress;

        USDC_SCALE_UP = 10 ** (18 - IERC20Metadata(usdc).decimals());

        string memory anchorName = "YOLO USD";
        string memory anchorSymbol = "USY";
        anchor = IYoloSyntheticAsset(createNewYoloAsset(anchorName, anchorSymbol, 18, address(0)));

        isYoloAsset[address(anchor)] = true;
        yoloAssetConfigs[address(anchor)] = YoloAssetConfiguration(address(anchor), 0, 0);

        isWhiteListedCollateral[_wethAddress] = true;
        collateralConfigs[_wethAddress] = CollateralConfiguration(_wethAddress, 0);

        // Initialize anchor pool
        address tokenA = usdc;
        address tokenB = address(anchor);

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

        PoolKey memory pk =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(this))});
        poolManager.initialize(pk, uint160(1) << 96);
        anchorPoolId = PoolId.unwrap(pk.toId());
        isAnchorPool[PoolId.unwrap(pk.toId())] = true;
    }

    // Logic contract management
    function setLogicContracts(address _anchorLogic, address _syntheticLogic, address _borrowLogic)
        external
        onlyOwner
    {
        anchorLogic = _anchorLogic;
        syntheticLogic = _syntheticLogic;
        borrowLogic = _borrowLogic;
    }

    // Admin functions (keep in main contract)
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setFlashLoanFee(uint256 _newFlashLoanFee) external onlyOwner {
        uint256 oldFlashLoanFee = flashLoanFee;
        flashLoanFee = _newFlashLoanFee;
        emit UpdateFlashLoanFee(_newFlashLoanFee, oldFlashLoanFee);
    }

    function setSyntheticSwapFee(uint256 _newSyntheticSwapFee) external onlyOwner {
        uint256 oldSyntheticSwapFee = syntheticSwapFee;
        syntheticSwapFee = _newSyntheticSwapFee;
        emit UpdateSyntheticSwapFee(_newSyntheticSwapFee, oldSyntheticSwapFee);
    }

    function setStableSwapFee(uint256 _newStableSwapFee) external onlyOwner {
        uint256 oldStableSwapfee = stableSwapFee;
        stableSwapFee = _newStableSwapFee;
        emit UpdateStableSwapFee(_newStableSwapFee, oldStableSwapfee);
    }

    function createNewYoloAsset(string memory _name, string memory _symbol, uint8 _decimals, address _priceSource)
        public
        onlyOwner
        returns (address)
    {
        // 1. Deploy the token
        YoloSyntheticAsset asset = new YoloSyntheticAsset(_name, _symbol, _decimals);
        address newAsset = address(asset);

        // 2. Register it
        isYoloAsset[newAsset] = true;
        yoloAssetConfigs[newAsset] = YoloAssetConfiguration(newAsset, 0, 0);

        // 3. Wire its price feed in the Oracle
        address[] memory assets = new address[](1);
        address[] memory priceSources = new address[](1);
        assets[0] = newAsset;
        priceSources[0] = _priceSource;
        yoloOracle.setAssetSources(assets, priceSources);

        emit YoloAssetCreated(newAsset, _name, _symbol, _decimals, _priceSource);

        // 4. Automatically create a synthetic pool vs. the anchor (USY)
        //    and mark it in our mapping so _beforeSwap kicks in correctly.
        bool anchorIs0 = address(anchor) < newAsset;
        Currency c0 = Currency.wrap(anchorIs0 ? address(anchor) : newAsset);
        Currency c1 = Currency.wrap(anchorIs0 ? newAsset : address(anchor));

        PoolKey memory pk =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(this))});

        // initialize price at 1:1 (sqrtPriceX96 = 2^96)
        poolManager.initialize(pk, uint160(1) << 96);

        // mark it synthetic
        isSyntheticPool[PoolId.unwrap(pk.toId())] = true;

        return newAsset;
    }

    // Admin functions for asset and collateral configuration
    function setYoloAssetConfig(address _asset, uint256 _maxMintableCap, uint256 _maxFlashLoanableAmount)
        external
        onlyOwner
    {
        if (!isYoloAsset[_asset]) revert YoloHook__NotYoloAsset();
        yoloAssetConfigs[_asset].maxMintableCap = _maxMintableCap;
        yoloAssetConfigs[_asset].maxFlashLoanableAmount = _maxFlashLoanableAmount;
        emit YoloAssetConfigurationUpdated(_asset, _maxMintableCap, _maxFlashLoanableAmount);
    }

    function setCollateralConfig(address _asset, uint256 _maxSupplyCap, address _priceSource) external onlyOwner {
        isWhiteListedCollateral[_asset] = true;
        collateralConfigs[_asset] = CollateralConfiguration(_asset, _maxSupplyCap);
        emit CollateralConfigurationUpdated(_asset, _maxSupplyCap, _priceSource);
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
        if (pairConfigs[_collateral][_yoloAsset].collateral == address(0)) revert YoloHook__InvalidPair();

        delete pairConfigs[_collateral][_yoloAsset];
        _removeFromArray(collateralToSupportedYoloAssets[_collateral], _yoloAsset);
        _removeFromArray(yoloAssetsToSupportedCollateral[_yoloAsset], _collateral);

        emit PairConfigRemoved(_collateral, _yoloAsset);
    }

    function setNewPriceSource(address _asset, address _priceSource) external onlyOwner {
        if (_priceSource == address(0)) revert YoloHook__InvalidPriceSource();

        address[] memory assets = new address[](1);
        address[] memory priceSources = new address[](1);
        assets[0] = _asset;
        priceSources[0] = _priceSource;
        yoloOracle.setAssetSources(assets, priceSources);
    }

    // User-facing functions that delegate to logic contracts
    function addLiquidity(
        uint256 _maxUsdcAmount,
        uint256 _maxUsyAmount,
        uint256 _minLiquidityReceive,
        address _receiver
    ) external nonReentrant whenNotPaused returns (uint256 usdcUsed, uint256 usyUsed, uint256 liquidity) {
        bytes memory data = abi.encodeWithSignature(
            "addLiquidity(address,address,uint256,uint256,uint256)",
            msg.sender,
            _receiver,
            _maxUsdcAmount,
            _maxUsyAmount,
            _minLiquidityReceive
        );

        (bool success, bytes memory result) = anchorLogic.delegatecall(data);
        require(success, "AnchorLogic call failed");

        return abi.decode(result, (uint256, uint256, uint256));
    }

    function removeLiquidity(uint256 _liquidityToRemove, uint256 _minUSDC, uint256 _minUSY, address _receiver)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 usdcAmount, uint256 usyAmount)
    {
        bytes memory data = abi.encodeWithSignature(
            "removeLiquidity(address,address,uint256,uint256,uint256)",
            msg.sender,
            _receiver,
            _liquidityToRemove,
            _minUSDC,
            _minUSY
        );

        (bool success, bytes memory result) = anchorLogic.delegatecall(data);
        require(success, "AnchorLogic call failed");

        return abi.decode(result, (uint256, uint256));
    }

    function borrow(address _collateral, uint256 _collateralAmount, address _yoloAsset, uint256 _borrowAmount)
        external
        nonReentrant
        whenNotPaused
    {
        bytes memory data = abi.encodeWithSignature(
            "borrow(address,uint256,address,uint256)", _collateral, _collateralAmount, _yoloAsset, _borrowAmount
        );

        (bool success,) = borrowLogic.delegatecall(data);
        require(success, "BorrowLogic call failed");
    }

    function repay(address _collateral, address _yoloAsset, uint256 _repayAmount, bool _returnCollateral)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 collateralToReturn)
    {
        bytes memory data = abi.encodeWithSignature(
            "repay(address,address,uint256,bool)", _collateral, _yoloAsset, _repayAmount, _returnCollateral
        );

        (bool success, bytes memory result) = borrowLogic.delegatecall(data);
        require(success, "BorrowLogic call failed");

        return abi.decode(result, (uint256));
    }

    function simpleFlashLoan(address _yoloAsset, uint256 _amount, bytes calldata _data)
        external
        nonReentrant
        whenNotPaused
    {
        bytes memory callData =
            abi.encodeWithSignature("simpleFlashLoan(address,uint256,bytes)", _yoloAsset, _amount, _data);

        (bool success,) = syntheticLogic.delegatecall(callData);
        require(success, "SyntheticLogic call failed");
    }

    function flashLoan(address[] calldata _yoloAssets, uint256[] calldata _amounts, bytes calldata _data)
        external
        nonReentrant
        whenNotPaused
    {
        bytes memory callData =
            abi.encodeWithSignature("flashLoan(address[],uint256[],bytes)", _yoloAssets, _amounts, _data);

        (bool success,) = syntheticLogic.delegatecall(callData);
        require(success, "SyntheticLogic call failed");
    }

    // Hook interface functions (stay in main contract)
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: true,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    function beforeModifyLiquidity(PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert YoloHook__MustAddLiquidityThroughHook();
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert YoloHook__MustAddLiquidityThroughHook();
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Burn previous pending tokens if any
        if (assetToBurn != address(0)) {
            bytes memory burnData = abi.encodeWithSignature("burnPendings()");
            (bool success,) = syntheticLogic.delegatecall(burnData);
            require(success, "Burn pendings failed");
        }

        bytes32 poolId = PoolId.unwrap(key.toId());
        BeforeSwapDelta beforeSwapDelta;

        if (isAnchorPool[poolId]) {
            // Delegate to AnchorLogic
            bytes memory data = abi.encodeWithSignature(
                "executeAnchorSwap(bytes32,address,(int256,bool,uint160,bytes32),((address,address,uint24,int24,address)))",
                poolId,
                sender,
                params,
                key
            );

            (bool success, bytes memory result) = anchorLogic.delegatecall(data);
            require(success, "AnchorLogic swap failed");

            beforeSwapDelta = abi.decode(result, (BeforeSwapDelta));
        } else if (isSyntheticPool[poolId]) {
            // Delegate to SyntheticLogic
            bytes memory data = abi.encodeWithSignature(
                "executeSyntheticSwap(bytes32,address,(int256,bool,uint160,bytes32),((address,address,uint24,int24,address)))",
                poolId,
                sender,
                params,
                key
            );

            (bool success, bytes memory result) = syntheticLogic.delegatecall(data);
            require(success, "SyntheticLogic swap failed");

            beforeSwapDelta = abi.decode(result, (BeforeSwapDelta));
        } else {
            revert YoloHook__InvalidPoolId();
        }

        return (this.beforeSwap.selector, beforeSwapDelta, 0);
    }

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        return (this.afterSwap.selector, int128(0));
    }

    function unlockCallback(bytes calldata _callbackData) external onlyPoolManager returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(_callbackData, (CallbackData));
        uint256 action = callbackData.action;

        if (action == 0 || action == 1) {
            // Liquidity operations - delegate to AnchorLogic
            (bool success, bytes memory result) =
                anchorLogic.delegatecall(abi.encodeWithSignature("unlockCallback(bytes)", _callbackData));
            require(success, "AnchorLogic unlock failed");
            return result;
        } else if (action == 2) {
            // Burn pendings - delegate to SyntheticLogic
            (bool success, bytes memory result) = syntheticLogic.delegatecall(abi.encodeWithSignature("burnPendings()"));
            require(success, "Burn pendings failed");
            return result;
        } else {
            revert YoloHook__UnknownUnlockActionError();
        }
    }

    // View functions
    function getAnchorReserves() external view returns (uint256 usdcReserve, uint256 usyReserve) {
        return (totalAnchorReserveUSDC, totalAnchorReserveUSY);
    }

    function calculateOptimalLiquidity(uint256 _usdcAmount, uint256 _usyAmount)
        external
        view
        returns (uint256 usdcUsed, uint256 usyUsed, uint256 liquidity)
    {
        bytes memory data =
            abi.encodeWithSignature("calculateOptimalLiquidity(uint256,uint256)", _usdcAmount, _usyAmount);

        (bool success, bytes memory result) = anchorLogic.staticcall(data);
        require(success, "AnchorLogic view call failed");

        return abi.decode(result, (uint256, uint256, uint256));
    }

    // Internal helper function for array manipulation
    function _removeFromArray(address[] storage arr, address elem) internal {
        uint256 len = arr.length;
        for (uint256 i = 0; i < len; i++) {
            if (arr[i] == elem) {
                arr[i] = arr[len - 1];
                arr.pop();
                break;
            }
        }
    }
}
