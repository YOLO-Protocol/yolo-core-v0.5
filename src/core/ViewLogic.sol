// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {YoloStorage} from "./YoloStorage.sol";
import {InterestMath} from "../libraries/InterestMath.sol";

/**
 * @title   ViewLogic
 * @author  0xyolodev.eth
 * @notice  Delegated logic contract for view functions (debt calculations, position health, etc.)
 * @dev     IMPORTANT: This contract MUST NOT have constructor or additional storage
 *          It inherits storage layout from YoloStorage and is called via delegatecall
 */
contract ViewLogic is YoloStorage {
    // ========================
    // EXTERNAL VIEW FUNCTIONS (called via delegatecall)
    // ========================

    /**
     * @notice Get current debt amount for a position with compound interest
     * @param _user User address
     * @param _collateral Collateral asset address
     * @param _yoloAsset Yolo asset address
     * @return actualDebt Current debt including compound interest
     */
    function getCurrentDebt(address _user, address _collateral, address _yoloAsset)
        external
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
        return _divUp(position.normalizedDebtRay * effectiveIndex, RAY);
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
        external
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
        uint256 currentDebt = this.getCurrentDebt(_user, _collateral, _yoloAsset);
        uint256 debtVal = yoloOracle.getAssetPrice(_yoloAsset) * currentDebt / (10 ** yoloAssetDecimals);

        return debtVal * PRECISION_DIVISOR <= colVal * _ltv;
    }

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

    /**
     * @notice Get user's position keys (all collateral-yoloAsset pairs for a user)
     * @param _user User address
     * @return keys Array of position keys for the user
     */
    function getUserPositionKeys(address _user) external view returns (UserPositionKey[] memory keys) {
        return userPositionKeys[_user];
    }

    /**
     * @notice Get detailed position information
     * @param _user User address
     * @param _collateral Collateral asset address
     * @param _yoloAsset Yolo asset address
     * @return position Full position struct
     */
    function getUserPosition(address _user, address _collateral, address _yoloAsset)
        external
        view
        returns (UserPosition memory position)
    {
        return positions[_user][_collateral][_yoloAsset];
    }

    /**
     * @notice Get pair configuration details
     * @param _collateral Collateral asset address
     * @param _yoloAsset Yolo asset address
     * @return config Full pair configuration
     */
    function getPairConfig(address _collateral, address _yoloAsset)
        external
        view
        returns (CollateralToYoloAssetConfiguration memory config)
    {
        return pairConfigs[_collateral][_yoloAsset];
    }

    /**
     * @notice Get all yolo assets supported by a collateral
     * @param _collateral Collateral asset address
     * @return supportedAssets Array of supported yolo asset addresses
     */
    function getSupportedYoloAssets(address _collateral) external view returns (address[] memory supportedAssets) {
        return collateralToSupportedYoloAssets[_collateral];
    }

    /**
     * @notice Get all collaterals that support a yolo asset
     * @param _yoloAsset Yolo asset address
     * @return supportedCollaterals Array of supported collateral addresses
     */
    function getSupportedCollaterals(address _yoloAsset)
        external
        view
        returns (address[] memory supportedCollaterals)
    {
        return yoloAssetsToSupportedCollateral[_yoloAsset];
    }

    /**
     * @notice Check if an asset is a recognized YoloAsset
     * @param _asset Asset address to check
     * @return isYolo Whether the asset is a YoloAsset
     */
    function checkIsYoloAsset(address _asset) external view returns (bool isYolo) {
        return isYoloAsset[_asset];
    }

    /**
     * @notice Check if an asset is whitelisted as collateral
     * @param _asset Asset address to check
     * @return isCollateral Whether the asset is whitelisted collateral
     */
    function checkIsWhitelistedCollateral(address _asset) external view returns (bool isCollateral) {
        return isWhiteListedCollateral[_asset];
    }

    /**
     * @notice Get yolo asset configuration
     * @param _yoloAsset Yolo asset address
     * @return config Asset configuration
     */
    function getYoloAssetConfig(address _yoloAsset) external view returns (YoloAssetConfiguration memory config) {
        return yoloAssetConfigs[_yoloAsset];
    }

    /**
     * @notice Get collateral configuration
     * @param _collateral Collateral asset address
     * @return config Collateral configuration
     */
    function getCollateralConfig(address _collateral) external view returns (CollateralConfiguration memory config) {
        return collateralConfigs[_collateral];
    }

    /**
     * @notice Get current liquidity index for a pair (projected, not stored)
     * @param _collateral Collateral asset address
     * @param _yoloAsset Yolo asset address
     * @return currentIndex Current projected liquidity index
     */
    function getCurrentLiquidityIndex(address _collateral, address _yoloAsset)
        external
        view
        returns (uint256 currentIndex)
    {
        CollateralToYoloAssetConfiguration storage config = pairConfigs[_collateral][_yoloAsset];

        if (config.liquidityIndexRay == 0) return RAY; // Default to 1.0

        uint256 timeDelta = block.timestamp - config.lastUpdateTimestamp;
        return InterestMath.calculateEffectiveIndex(config.liquidityIndexRay, config.interestRate, timeDelta);
    }

    // ========================
    // INTERNAL HELPER FUNCTIONS
    // ========================

    /**
     * @notice Helper function for ceiling division (rounds up)
     * @dev Used to ensure protocol always rounds in its favor for user obligations
     * @param a Numerator
     * @param b Denominator
     * @return Result rounded up
     */
    function _divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }
}
