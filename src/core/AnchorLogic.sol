// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IYoloSyntheticAsset} from "@yolo/contracts/interfaces/IYoloSyntheticAsset.sol";

contract AnchorLogic {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    // Constants for stable math (matching YoloHook)
    uint256 private constant MINIMUM_LIQUIDITY = 1000;
    uint256 private constant MATH_PRECISION = 1e18;
    uint8 private constant STABLESWAP_ITERATIONS = 255;
    uint256 private constant PRECISION_DIVISOR = 10000;

    // Storage variables are accessed via delegatecall context from YoloHook
    // These declarations allow compilation but actual storage is in YoloHook

    IPoolManager public poolManager;
    address public treasury;
    IYoloSyntheticAsset public anchor;
    address public usdc;
    address public anchorPoolToken0;
    address public anchorPoolToken1;
    uint256 public stableSwapFee;
    uint256 public totalAnchorReserveUSDC;
    uint256 public totalAnchorReserveUSY;
    uint256 public anchorPoolLiquiditySupply;
    mapping(address => uint256) public anchorPoolLPBalance;
    uint256 private USDC_SCALE_UP;

    // Error declarations (matching YoloHook)
    error YoloHook__InsufficientLiquidityMinted();
    error YoloHook__InsufficientLiquidityBalance();
    error YoloHook__InsufficientAmount();
    error YoloHook__InsufficientReserves();
    error YoloHook__InvalidOutput();
    error YoloHook__InvalidSwapAmounts();
    error YoloHook__StableswapConvergenceError();
    error YoloHook__MathOverflow();
    error YoloHook__KInvariantViolation();

    // Events (matching YoloHook)
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

    event AnchorSwapExecuted(
        bytes32 indexed poolId,
        address indexed sender,
        address indexed receiver,
        bool zeroForOne,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut,
        uint256 feeAmount
    );

    event HookSwap(
        bytes32 indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint128 hookLPfeeAmount0,
        uint128 hookLPfeeAmount1
    );

    // Liquidity management functions
    function addLiquidity(
        address sender,
        address receiver,
        uint256 maxUsdcAmount,
        uint256 maxUsyAmount,
        uint256 minLiquidityReceive
    ) external returns (uint256 usdcUsed, uint256 usyUsed, uint256 liquidity) {
        if (maxUsdcAmount == 0 || maxUsyAmount == 0) revert YoloHook__InsufficientAmount();

        // Calculate optimal amounts
        (usdcUsed, usyUsed, liquidity) = _quoteAdd(maxUsdcAmount, maxUsyAmount);

        if (liquidity < minLiquidityReceive) revert YoloHook__InsufficientLiquidityMinted();

        // Transfer tokens from user
        IERC20(usdc).safeTransferFrom(sender, address(this), usdcUsed);
        IERC20(address(anchor)).safeTransferFrom(sender, address(this), usyUsed);

        // Update reserves
        totalAnchorReserveUSDC += usdcUsed;
        totalAnchorReserveUSY += usyUsed;

        // Mint LP tokens
        if (anchorPoolLiquiditySupply == 0) {
            anchorPoolLPBalance[address(0)] += MINIMUM_LIQUIDITY;
            anchorPoolLPBalance[receiver] += liquidity;
            anchorPoolLiquiditySupply = liquidity + MINIMUM_LIQUIDITY;
        } else {
            anchorPoolLPBalance[receiver] += liquidity;
            anchorPoolLiquiditySupply += liquidity;
        }

        emit AnchorLiquidityAdded(sender, receiver, usdcUsed, usyUsed, liquidity);
    }

    function removeLiquidity(
        address sender,
        address receiver,
        uint256 liquidityToRemove,
        uint256 minUSDC,
        uint256 minUSY
    ) external returns (uint256 usdcAmount, uint256 usyAmount) {
        if (anchorPoolLPBalance[sender] < liquidityToRemove) revert YoloHook__InsufficientLiquidityBalance();

        // Calculate proportional amounts
        usdcAmount = (liquidityToRemove * totalAnchorReserveUSDC) / anchorPoolLiquiditySupply;
        usyAmount = (liquidityToRemove * totalAnchorReserveUSY) / anchorPoolLiquiditySupply;

        if (usdcAmount < minUSDC || usyAmount < minUSY) revert YoloHook__InsufficientAmount();

        // Update state
        anchorPoolLPBalance[sender] -= liquidityToRemove;
        anchorPoolLiquiditySupply -= liquidityToRemove;
        totalAnchorReserveUSDC -= usdcAmount;
        totalAnchorReserveUSY -= usyAmount;

        // Transfer tokens to receiver
        IERC20(usdc).safeTransfer(receiver, usdcAmount);
        IERC20(address(anchor)).safeTransfer(receiver, usyAmount);

        emit AnchorLiquidityRemoved(sender, receiver, usdcAmount, usyAmount, liquidityToRemove);
    }

    function executeAnchorSwap(bytes32 poolId, address sender, SwapParams calldata params, PoolKey calldata key)
        external
        returns (BeforeSwapDelta beforeSwapDelta)
    {
        // Validate reserves
        if (totalAnchorReserveUSDC == 0 || totalAnchorReserveUSY == 0) {
            revert YoloHook__InsufficientReserves();
        }

        bool usdcToUsy = (params.zeroForOne == (anchorPoolToken0 == usdc));
        uint256 reserveInRaw = usdcToUsy ? totalAnchorReserveUSDC : totalAnchorReserveUSY;
        uint256 reserveOutRaw = usdcToUsy ? totalAnchorReserveUSY : totalAnchorReserveUSDC;

        uint256 scaleUpIn = usdcToUsy ? USDC_SCALE_UP : 1;
        uint256 scaleUpOut = usdcToUsy ? 1 : USDC_SCALE_UP;

        uint256 reserveInWad = reserveInRaw * scaleUpIn;
        uint256 reserveOutWad = reserveOutRaw * scaleUpOut;

        // Calculate swap amounts
        uint256 grossInRaw;
        uint256 netInRaw;
        uint256 feeRaw;
        uint256 amountOutRaw;

        if (params.amountSpecified < 0) {
            // Exact Input
            grossInRaw = uint256(-params.amountSpecified);
            uint256 grossInWad = grossInRaw * scaleUpIn;

            uint256 feeWad = (grossInWad * stableSwapFee) / PRECISION_DIVISOR;
            uint256 netInWad = grossInWad - feeWad;

            uint256 outWad = _calculateStableSwapOutputInternal(netInWad, reserveInWad, reserveOutWad);
            if (outWad == 0) revert YoloHook__InvalidOutput();

            amountOutRaw = outWad / scaleUpOut;
            feeRaw = feeWad / scaleUpIn;
            netInRaw = grossInRaw - feeRaw;
        } else {
            // Exact Output
            amountOutRaw = uint256(params.amountSpecified);
            uint256 desiredOutWad = amountOutRaw * scaleUpOut;

            uint256 netInWad = _calculateStableSwapInputInternal(desiredOutWad, reserveInWad, reserveOutWad);

            uint256 grossInWad =
                (netInWad * PRECISION_DIVISOR + (PRECISION_DIVISOR - 1)) / (PRECISION_DIVISOR - stableSwapFee);
            uint256 feeWad = grossInWad - netInWad;

            grossInRaw = grossInWad / scaleUpIn;
            feeRaw = feeWad / scaleUpIn;
            netInRaw = grossInRaw - feeRaw;
        }

        // Update reserves
        if (usdcToUsy) {
            totalAnchorReserveUSDC = reserveInRaw + netInRaw;
            totalAnchorReserveUSY = reserveOutRaw - amountOutRaw;
        } else {
            totalAnchorReserveUSY = reserveInRaw + netInRaw;
            totalAnchorReserveUSDC = reserveOutRaw - amountOutRaw;
        }

        // Construct BeforeSwapDelta
        int128 dSpecified;
        int128 dUnspecified;

        if (params.amountSpecified < 0) {
            dSpecified = int128(uint128(grossInRaw));
            dUnspecified = -int128(uint128(amountOutRaw));
        } else {
            dSpecified = -int128(uint128(amountOutRaw));
            dUnspecified = int128(uint128(grossInRaw));
        }
        beforeSwapDelta = toBeforeSwapDelta(dSpecified, dUnspecified);

        // Currency settlement
        Currency cIn = params.zeroForOne ? key.currency0 : key.currency1;
        Currency cOut = params.zeroForOne ? key.currency1 : key.currency0;

        cIn.take(poolManager, address(this), netInRaw, true);
        if (feeRaw != 0) {
            cIn.take(poolManager, treasury, feeRaw, false);
        }
        cOut.settle(poolManager, address(this), amountOutRaw, true);

        emit AnchorSwapExecuted(
            poolId,
            sender,
            sender,
            params.zeroForOne,
            Currency.unwrap(cIn),
            grossInRaw,
            Currency.unwrap(cOut),
            amountOutRaw,
            feeRaw
        );

        // Emit HookSwap event
        uint128 in128 = uint128(grossInRaw);
        uint128 out128 = uint128(amountOutRaw);
        uint128 fee128 = uint128(feeRaw);

        int128 amount0;
        int128 amount1;
        uint128 fee0;
        uint128 fee1;

        if (params.zeroForOne) {
            amount0 = int128(in128);
            amount1 = -int128(out128);
            fee0 = fee128;
            fee1 = 0;
        } else {
            amount0 = -int128(out128);
            amount1 = int128(in128);
            fee0 = 0;
            fee1 = fee128;
        }

        emit HookSwap(poolId, sender, amount0, amount1, fee0, fee1);
    }

    // View function for calculating optimal liquidity amounts
    function calculateOptimalLiquidity(uint256 _usdcAmount, uint256 _usyAmount)
        external
        view
        returns (uint256 usdcUsed, uint256 usyUsed, uint256 liquidity)
    {
        return _quoteAdd(_usdcAmount, _usyAmount);
    }

    // Internal functions for stable math
    function _quoteAdd(uint256 rawUsdc, uint256 usy)
        internal
        view
        returns (uint256 usdcOut, uint256 usyOut, uint256 lpOut)
    {
        if (anchorPoolLiquiditySupply == 0) {
            usdcOut = rawUsdc;
            usyOut = usy;
            lpOut = _sqrt(_toWadUSDC(usdcOut) * usyOut) - MINIMUM_LIQUIDITY;
        } else {
            uint256 wadResUsdc = _toWadUSDC(totalAnchorReserveUSDC);
            uint256 wadResUsy = totalAnchorReserveUSY;

            uint256 usdcReq = (usy * wadResUsdc + wadResUsy - 1) / wadResUsy;
            uint256 usyReq = (rawUsdc * wadResUsy + wadResUsdc - 1) / wadResUsdc;

            if (usdcReq <= rawUsdc) {
                usdcOut = usdcReq;
                usyOut = usy;
            } else {
                usdcOut = rawUsdc;
                usyOut = usyReq;
            }

            uint256 lp0 = _toWadUSDC(usdcOut) * anchorPoolLiquiditySupply / wadResUsdc;
            uint256 lp1 = usyOut * anchorPoolLiquiditySupply / wadResUsy;
            lpOut = lp0 < lp1 ? lp0 : lp1;
        }
    }

    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x >> 1) + 1;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) >> 1;
        }
        return y;
    }

    function _toWadUSDC(uint256 _raw) internal view returns (uint256) {
        return _raw * USDC_SCALE_UP;
    }

    function _fromWadUSDC(uint256 _wad) internal view returns (uint256) {
        return _wad / USDC_SCALE_UP;
    }

    // Stable math functions
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
            revert YoloHook__MathOverflow();
        }
        uint256 term2_3x = 3 * x0_y_sq_P2;

        uint256 derivative = x0_cubed_P2 + term2_3x;
        if (derivative == 0) revert YoloHook__StableswapConvergenceError();
        return derivative;
    }

    function _getY_stable(uint256 x0_18d, uint256 k_18d, uint256 y_guess_18d)
        internal
        pure
        returns (uint256 y_new_18d)
    {
        y_new_18d = y_guess_18d;
        if (x0_18d == 0) {
            if (k_18d > 0) revert YoloHook__StableswapConvergenceError();
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

    function _calculateStableSwapOutputInternal(uint256 netAmountIn_18d, uint256 reserveIn_18d, uint256 reserveOut_18d)
        internal
        pure
        returns (uint256 amountOut_18d)
    {
        if (netAmountIn_18d == 0) return 0;
        uint256 k_val = _getK_stable(reserveIn_18d, reserveOut_18d);

        if (k_val == 0) {
            revert YoloHook__InsufficientReserves();
        }

        uint256 newReserveIn_18d = reserveIn_18d + netAmountIn_18d;
        uint256 newReserveOut_18d = _getY_stable(newReserveIn_18d, k_val, reserveOut_18d);

        if (newReserveOut_18d >= reserveOut_18d) return 0;
        amountOut_18d = reserveOut_18d - newReserveOut_18d;
    }

    function _calculateStableSwapInputInternal(uint256 amountOut_18d, uint256 reserveIn_18d, uint256 reserveOut_18d)
        internal
        pure
        returns (uint256 netAmountIn_18d)
    {
        if (amountOut_18d == 0) return 0;
        if (amountOut_18d >= reserveOut_18d) {
            revert YoloHook__InsufficientReserves();
        }

        uint256 k_val = _getK_stable(reserveIn_18d, reserveOut_18d);
        if (k_val == 0) {
            revert YoloHook__InsufficientReserves();
        }

        uint256 newReserveOut_18d = reserveOut_18d - amountOut_18d;
        uint256 newReserveIn_18d = _getY_stable(newReserveOut_18d, k_val, reserveIn_18d);

        if (newReserveIn_18d <= reserveIn_18d) {
            revert YoloHook__InvalidSwapAmounts();
        }
        netAmountIn_18d = newReserveIn_18d - reserveIn_18d;
    }
}
