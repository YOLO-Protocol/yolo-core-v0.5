// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title   StableMathLib
 * @notice  Library containing stable swap math functions
 * @dev     Extracted from YoloHook to reduce contract size - deployed separately
 */
library StableMathLib {
    uint256 internal constant MATH_PRECISION = 1e18;
    uint256 internal constant STABLESWAP_ITERATIONS = 255;

    error StableMathLib__MathOverflow();
    error StableMathLib__StableswapConvergenceError();
    error StableMathLib__InsufficientReserves();
    error StableMathLib__InvalidSwapAmounts();

    function getK(uint256 x_18d, uint256 y_18d) public pure returns (uint256 k_18d) {
        if (x_18d == 0 || y_18d == 0) return 0;
        
        // Overflow protection: Check before multiplications
        if (x_18d > type(uint256).max / y_18d) revert StableMathLib__MathOverflow();
        if (x_18d > type(uint256).max / x_18d) revert StableMathLib__MathOverflow();
        if (y_18d > type(uint256).max / y_18d) revert StableMathLib__MathOverflow();
        
        uint256 xy_P = (x_18d * y_18d) / MATH_PRECISION;
        uint256 x_sq_P = (x_18d * x_18d) / MATH_PRECISION;
        uint256 y_sq_P = (y_18d * y_18d) / MATH_PRECISION;
        
        // Check for addition overflow and final multiplication
        if (x_sq_P > type(uint256).max - y_sq_P) revert StableMathLib__MathOverflow();
        uint256 sum = x_sq_P + y_sq_P;
        if (xy_P > type(uint256).max / sum) revert StableMathLib__MathOverflow();
        
        k_18d = (xy_P * sum) / MATH_PRECISION;
        return k_18d;
    }

    function f(uint256 x0_18d, uint256 y_18d) public pure returns (uint256) {
        uint256 y_sq_P = (y_18d * y_18d) / MATH_PRECISION;
        uint256 y_cubed_P2 = (y_sq_P * y_18d) / MATH_PRECISION;
        uint256 term1 = (x0_18d * y_cubed_P2) / MATH_PRECISION;

        uint256 x0_sq_P = (x0_18d * x0_18d) / MATH_PRECISION;
        uint256 x0_cubed_P2 = (x0_sq_P * x0_18d) / MATH_PRECISION;
        uint256 term2 = (y_18d * x0_cubed_P2) / MATH_PRECISION;
        return term1 + term2;
    }

    function d(uint256 x0_18d, uint256 y_18d) public pure returns (uint256) {
        // Overflow protection BEFORE operations
        if (x0_18d > type(uint256).max / x0_18d) revert StableMathLib__MathOverflow();
        if (y_18d > type(uint256).max / y_18d) revert StableMathLib__MathOverflow();
        
        uint256 x0_sq_P = (x0_18d * x0_18d) / MATH_PRECISION;
        if (x0_sq_P > type(uint256).max / x0_18d) revert StableMathLib__MathOverflow();
        uint256 x0_cubed_P2 = (x0_sq_P * x0_18d) / MATH_PRECISION;

        uint256 y_sq_P = (y_18d * y_18d) / MATH_PRECISION;
        
        // Check overflow BEFORE multiplication
        if (x0_18d > type(uint256).max / y_sq_P) revert StableMathLib__MathOverflow();
        uint256 x0_y_sq_P2 = (x0_18d * y_sq_P) / MATH_PRECISION;

        // Now check for the final multiplication by 3
        if (x0_y_sq_P2 > type(uint256).max / 3) {
            revert StableMathLib__MathOverflow();
        }
        uint256 term2_3x = 3 * x0_y_sq_P2;

        // Check addition overflow
        if (x0_cubed_P2 > type(uint256).max - term2_3x) revert StableMathLib__MathOverflow();
        uint256 derivative = x0_cubed_P2 + term2_3x;
        if (derivative == 0) revert StableMathLib__StableswapConvergenceError();
        return derivative;
    }

    function getY(uint256 x0_18d, uint256 k_18d, uint256 y_guess_18d) public pure returns (uint256 y_new_18d) {
        y_new_18d = y_guess_18d;
        if (x0_18d == 0) {
            if (k_18d > 0) revert StableMathLib__StableswapConvergenceError();
            return 0;
        }

        for (uint256 i = 0; i < STABLESWAP_ITERATIONS; i++) {
            uint256 y_prev = y_new_18d;
            uint256 f_val = f(x0_18d, y_new_18d);
            uint256 d_val = d(x0_18d, y_new_18d);

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

    function calculateStableSwapOutput(uint256 netAmountIn_18d, uint256 reserveIn_18d, uint256 reserveOut_18d)
        public
        pure
        returns (uint256 amountOut_18d)
    {
        if (netAmountIn_18d == 0) return 0;
        uint256 k_val = getK(reserveIn_18d, reserveOut_18d);

        if (k_val == 0) {
            revert StableMathLib__InsufficientReserves();
        }

        uint256 newReserveIn_18d = reserveIn_18d + netAmountIn_18d;
        uint256 newReserveOut_18d = getY(newReserveIn_18d, k_val, reserveOut_18d);

        if (newReserveOut_18d >= reserveOut_18d) return 0;
        amountOut_18d = reserveOut_18d - newReserveOut_18d;
    }

    function calculateStableSwapInput(uint256 amountOut_18d, uint256 reserveIn_18d, uint256 reserveOut_18d)
        public
        pure
        returns (uint256 netAmountIn_18d)
    {
        if (amountOut_18d == 0) return 0;
        if (amountOut_18d >= reserveOut_18d) {
            revert StableMathLib__InsufficientReserves();
        }

        uint256 k_val = getK(reserveIn_18d, reserveOut_18d);
        if (k_val == 0) {
            revert StableMathLib__InsufficientReserves();
        }

        uint256 newReserveOut_18d = reserveOut_18d - amountOut_18d;
        uint256 newReserveIn_18d = getY(newReserveOut_18d, k_val, reserveIn_18d);

        if (newReserveIn_18d <= reserveIn_18d) {
            revert StableMathLib__InvalidSwapAmounts();
        }
        netAmountIn_18d = newReserveIn_18d - reserveIn_18d;
    }
}
