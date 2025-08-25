// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title InterestMath
 * @notice Mathematical functions for compound interest calculations using Aave-style liquidity index
 * @dev Uses 27 decimal precision (RAY) for maximum accuracy
 */
library InterestMath {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /**
     * @dev Calculate new liquidity index with compound interest
     * @param currentLiquidityIndexRay Current index value (27 decimals)
     * @param rateBps Interest rate in basis points (e.g., 500 = 5%)
     * @param timeDelta Time elapsed in seconds
     * @return newLiquidityIndexRay Updated index value
     */
    function calculateLinearInterest(uint256 currentLiquidityIndexRay, uint256 rateBps, uint256 timeDelta)
        internal
        pure
        returns (uint256 newLiquidityIndexRay)
    {
        if (timeDelta == 0) return currentLiquidityIndexRay;

        // Convert rate to per-second RAY precision
        // rateBps = 500 (5%) -> ratePerSecondRay = (500 * RAY) / (10000 * SECONDS_PER_YEAR)
        uint256 ratePerSecondRay = (rateBps * RAY) / (10000 * SECONDS_PER_YEAR);

        // Calculate linear factor keeping RAY precision
        uint256 linearFactorRay = ratePerSecondRay * timeDelta;

        // Apply compound growth: newIndex = currentIndex * (1 + rate * time)
        // newIndex = currentIndex + (currentIndex * linearFactorRay) / RAY
        return currentLiquidityIndexRay + (currentLiquidityIndexRay * linearFactorRay) / RAY;
    }

    /**
     * @dev Calculate actual debt from normalized (scaled) debt
     * @param scaledDebtRay User's stored debt amount (27 decimals)
     * @param currentLiquidityIndexRay Current global index (27 decimals)
     * @return actualDebt Real debt amount with compound interest (18 decimals)
     */
    function calculateActualDebt(uint256 scaledDebtRay, uint256 currentLiquidityIndexRay)
        internal
        pure
        returns (uint256 actualDebt)
    {
        if (scaledDebtRay == 0 || currentLiquidityIndexRay == 0) return 0;
        return (scaledDebtRay * currentLiquidityIndexRay) / RAY;
    }

    /**
     * @dev Calculate normalized (scaled) debt from actual debt
     * @param actualDebt Real debt amount (18 decimals)
     * @param liquidityIndexRay Current index (27 decimals)
     * @return scaledDebtRay Normalized debt amount (27 decimals)
     */
    function calculateScaledDebt(uint256 actualDebt, uint256 liquidityIndexRay)
        internal
        pure
        returns (uint256 scaledDebtRay)
    {
        if (actualDebt == 0 || liquidityIndexRay == 0) return 0;
        return (actualDebt * RAY) / liquidityIndexRay;
    }

    /**
     * @dev Calculate effective index for view functions (no storage writes)
     * @param currentLiquidityIndexRay Current stored index
     * @param rateBps Interest rate in basis points
     * @param timeDelta Time since last update
     * @return effectiveIndexRay Projected index value
     */
    function calculateEffectiveIndex(uint256 currentLiquidityIndexRay, uint256 rateBps, uint256 timeDelta)
        internal
        pure
        returns (uint256 effectiveIndexRay)
    {
        return calculateLinearInterest(currentLiquidityIndexRay, rateBps, timeDelta);
    }
}
