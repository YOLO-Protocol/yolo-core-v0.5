// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {YoloSyntheticAsset} from "@yolo/contracts/tokenization/YoloSyntheticAsset.sol";
import {YoloStorage} from "./YoloStorage.sol";
import {InterestMath} from "../libraries/InterestMath.sol";
import {IStakedYoloUSD} from "../interfaces/IStakedYoloUSD.sol";

/**
 * @title   AdminLogic
 * @author  0xyolodev.eth
 * @notice  Delegated logic contract for admin functions (asset/collateral/pair configuration)
 * @dev     IMPORTANT: This contract MUST NOT have constructor or additional storage
 *          It inherits storage layout from YoloStorage and is called via delegatecall
 */
contract AdminLogic is YoloStorage {
    // ========================
    // EXTERNAL ADMIN FUNCTIONS (called via delegatecall)
    // ========================

    /**
     * @notice Create a new synthetic YoloAsset
     * @param _name Token name
     * @param _symbol Token symbol
     * @param _decimals Token decimals
     * @param _priceSource Oracle price source address
     * @return assetAddress Address of created YoloAsset
     */
    function createNewYoloAsset(string calldata _name, string calldata _symbol, uint8 _decimals, address _priceSource)
        external
        returns (address assetAddress)
    {
        // 1. Deploy the token
        YoloSyntheticAsset asset = new YoloSyntheticAsset(_name, _symbol, _decimals);
        assetAddress = address(asset);

        // 2. Register it
        isYoloAsset[assetAddress] = true;
        yoloAssetConfigs[assetAddress] =
            YoloAssetConfiguration({yoloAssetAddress: assetAddress, maxMintableCap: 0, maxFlashLoanableAmount: 0});

        // 3. Wire its price feed in the Oracle
        address[] memory assets = new address[](1);
        address[] memory priceSources = new address[](1);
        assets[0] = assetAddress;
        priceSources[0] = _priceSource;
        yoloOracle.setAssetSources(assets, priceSources);

        emit YoloAssetCreated(assetAddress, _name, _symbol, _decimals, _priceSource);

        // 4. Automatically create a synthetic pool vs. the anchor (USY)
        bool anchorIs0 = address(anchor) < assetAddress;
        Currency c0 = Currency.wrap(anchorIs0 ? address(anchor) : assetAddress);
        Currency c1 = Currency.wrap(anchorIs0 ? assetAddress : address(anchor));

        PoolKey memory pk =
            PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 1, hooks: IHooks(address(this))});

        // Get poolManager instance and initialize price at 1:1 (sqrtPriceX96 = 2^96)
        IPoolManager poolManager = _getPoolManager();
        poolManager.initialize(pk, uint160(1) << 96);

        // Mark it synthetic
        isSyntheticPool[PoolId.unwrap(pk.toId())] = true;
    }

    /**
     * @notice Set YoloAsset configuration (caps and limits)
     * @param _asset YoloAsset address
     * @param _newMintCap New maximum mintable cap
     * @param _newFlashLoanCap New flash loan cap
     */
    function setYoloAssetConfig(address _asset, uint256 _newMintCap, uint256 _newFlashLoanCap) external {
        if (!isYoloAsset[_asset]) revert YoloHook__NotYoloAsset();
        YoloAssetConfiguration storage cfg = yoloAssetConfigs[_asset];
        cfg.maxMintableCap = _newMintCap;
        cfg.maxFlashLoanableAmount = _newFlashLoanCap;
        emit YoloAssetConfigurationUpdated(_asset, _newMintCap, _newFlashLoanCap);
    }

    /**
     * @notice Set collateral configuration
     * @param _collateral Collateral asset address
     * @param _newSupplyCap New supply cap
     * @param _priceSource Oracle price source (0 address to skip)
     */
    function setCollateralConfig(address _collateral, uint256 _newSupplyCap, address _priceSource) external {
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

    /**
     * @notice Set pair configuration (collateral-yoloAsset pair parameters)
     * @param _collateral Collateral asset address
     * @param _yoloAsset YoloAsset address
     * @param _interestRate Interest rate in basis points
     * @param _ltv Loan-to-value ratio in basis points
     * @param _liquidationPenalty Liquidation penalty in basis points
     */
    function setPairConfig(
        address _collateral,
        address _yoloAsset,
        uint256 _interestRate,
        uint256 _ltv,
        uint256 _liquidationPenalty
    ) external {
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

    /**
     * @notice Remove pair configuration
     * @param _collateral Collateral asset address
     * @param _yoloAsset YoloAsset address
     */
    function removePairConfig(address _collateral, address _yoloAsset) external {
        // 1) Remove the config mapping
        delete pairConfigs[_collateral][_yoloAsset];

        // 2) Remove from collateral→assets list
        _removeFromArray(collateralToSupportedYoloAssets[_collateral], _yoloAsset);

        // 3) Remove from asset→collaterals list
        _removeFromArray(yoloAssetsToSupportedCollateral[_yoloAsset], _collateral);

        emit PairDropped(_collateral, _yoloAsset);
    }

    /**
     * @notice Configure expiration settings for a collateral-asset pair
     * @param _collateral Collateral asset address
     * @param _yoloAsset Yolo asset address
     * @param _isExpirable Whether positions in this pair expire
     * @param _expirePeriod Duration in seconds (e.g., 365 days)
     */
    function setExpirationConfig(address _collateral, address _yoloAsset, bool _isExpirable, uint256 _expirePeriod)
        external
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
     * @notice Set new price source for an asset
     * @param _asset Asset address
     * @param _priceSource New price source address
     */
    function setNewPriceSource(address _asset, address _priceSource) external {
        if (_priceSource == address(0)) revert YoloHook__InvalidPriceSource();

        address[] memory assets = new address[](1);
        address[] memory priceSources = new address[](1);
        assets[0] = _asset;
        priceSources[0] = _priceSource;

        yoloOracle.setAssetSources(assets, priceSources);
    }

    /**
     * @notice Set fee configuration
     * @param _newFee New fee amount
     * @param _feeType Fee type (0=stable swap, 1=synthetic swap, 2=flash loan)
     */
    function setFee(uint256 _newFee, uint8 _feeType) external {
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
     * @notice Set synthetic asset logic contract address
     * @param _syntheticAssetLogic New synthetic asset logic address
     */
    function setSyntheticAssetLogic(address _syntheticAssetLogic) external {
        if (_syntheticAssetLogic == address(0)) revert YoloHook__ZeroAddress();
        syntheticAssetLogic = _syntheticAssetLogic;
    }

    /**
     * @notice Set rehypothecation logic contract address
     * @param _rehypothecationLogic New rehypothecation logic address
     */
    function setRehypothecationLogic(address _rehypothecationLogic) external {
        if (_rehypothecationLogic == address(0)) revert YoloHook__ZeroAddress();
        rehypothecationLogic = _rehypothecationLogic;
    }

    /**
     * @notice Set anchor pool logic contract address
     * @param _anchorPoolLogic New anchor pool logic address
     */
    function setAnchorPoolLogic(address _anchorPoolLogic) external {
        if (_anchorPoolLogic == address(0)) revert YoloHook__ZeroAddress();
        anchorPoolLogic = _anchorPoolLogic;
    }

    /**
     * @notice Set view logic contract address
     * @param _viewLogic New view logic address
     */
    function setViewLogic(address _viewLogic) external {
        if (_viewLogic == address(0)) revert YoloHook__ZeroAddress();
        viewLogic = _viewLogic;
    }

    /**
     * @notice Set admin logic contract address
     * @param _adminLogic New admin logic address
     */
    function setAdminLogic(address _adminLogic) external {
        if (_adminLogic == address(0)) revert YoloHook__ZeroAddress();
        adminLogic = _adminLogic;
    }

    /**
     * @notice Set utility logic contract address
     * @param _utilityLogic New utility logic address
     */
    function setUtilityLogic(address _utilityLogic) external {
        if (_utilityLogic == address(0)) revert YoloHook__ZeroAddress();
        utilityLogic = _utilityLogic;
    }

    /**
     * @notice Set the sUSY token contract address
     * @param _sUSYAddress Address of the deployed sUSY token
     */
    function setSUSYToken(address _sUSYAddress) external {
        if (_sUSYAddress == address(0)) revert YoloHook__ZeroAddress();
        sUSY = IStakedYoloUSD(_sUSYAddress);
        emit sUSYDeployed(_sUSYAddress);
    }

    /**
     * @notice Register a bridge contract for cross-chain operations
     * @param _bridgeAddress Bridge contract address
     */
    function registerBridge(address _bridgeAddress) external {
        if (_bridgeAddress == address(0)) revert YoloHook__ZeroAddress();
        registeredBridge = _bridgeAddress;
        emit BridgeRegistered(_bridgeAddress);
    }

    // ========================
    // INTERNAL HELPER FUNCTIONS
    // ========================

    /**
     * @notice Remove element from array by swapping with last and popping
     * @param arr Array to modify
     * @param elem Element to remove
     */
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

    /**
     * @notice Get the PoolManager instance
     * @dev Calls back to YoloHook to get the immutable poolManager
     */
    function _getPoolManager() internal view returns (IPoolManager) {
        // poolManager is immutable in BaseHook, so we need to call YoloHook to get it
        // Use low-level call to avoid interface dependency
        (bool success, bytes memory data) = address(this).staticcall(abi.encodeWithSignature("getPoolManager()"));
        require(success, "Failed to get poolManager");
        return abi.decode(data, (IPoolManager));
    }
}
