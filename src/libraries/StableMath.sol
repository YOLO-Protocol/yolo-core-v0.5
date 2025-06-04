// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library StableMath {
    // Constants
    uint256 private constant MATH_PRECISION = 1e18;
    uint8 private constant STABLESWAP_ITERATIONS = 255; // Maximum iterations for stable swap Newton-Raphson method

    // Errors
    error StableMath__ConvergenceError();
    error StableMath__MathOverflow();

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
            revert StableMath__MathOverflow();
        }
        uint256 term2_3x = 3 * x0_y_sq_P2;

        uint256 derivative = x0_cubed_P2 + term2_3x;
        if (derivative == 0) revert StableMath__ConvergenceError();
        return derivative;
    }

    function _getY_stable(uint256 x0_18d, uint256 k_18d, uint256 y_guess_18d)
        internal
        pure
        returns (uint256 y_new_18d)
    {
        y_new_18d = y_guess_18d;
        if (x0_18d == 0) {
            if (k_18d > 0) revert StableMath__ConvergenceError();
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
}
