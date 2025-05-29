// // SPDX-License-Identifier: BUSL-1.1
// pragma solidity ^0.8.26;

// // Add these to your YoloHook contract:

// // ***************************//
// // *** STABLESWAP VARIABLES ***//
// // ************************** //

// // Anchor pool liquidity tracking
// uint256 public anchorPoolLiquiditySupply; // Total LP tokens for anchor pool
// mapping(address => uint256) public anchorPoolLPBalance; // User LP balances
// mapping(address => uint256) public anchorPoolReserveUSDC; // USDC reserves
// mapping(address => uint256) public anchorPoolReserveUSY; // USY reserves

// // Anchor pool reserves
// uint256 public totalAnchorReserveUSDC;
// uint256 public totalAnchorReserveUSY;

// // Constants for stableswap math
// uint256 private constant MINIMUM_LIQUIDITY = 1000;
// uint256 private constant PRECISION = 1e18;

// // ***************//
// // *** EVENTS *** //
// // ************** //

// event AnchorLiquidityAdded(address indexed provider, uint256 usdcAmount, uint256 usyAmount, uint256 liquidity);

// event AnchorLiquidityRemoved(address indexed provider, uint256 usdcAmount, uint256 usyAmount, uint256 liquidity);

// event AnchorSwapExecuted(address indexed sender, bool usdcForUSY, uint256 amountIn, uint256 amountOut, uint256 fee);

// // ***************//
// // *** ERRORS *** //
// // ************** //

// error YoloHook__InsufficientLiquidity();
// error YoloHook__InsufficientAmount();
// error YoloHook__KInvariantViolation();

// // ********************************//
// // *** ANCHOR POOL FUNCTIONS *** //
// // ****************************** //

// /**
//  * @notice Add liquidity to the anchor pool (USDC/USY)
//  * @param usdcAmount Amount of USDC to add
//  * @param usyAmount Amount of USY to add
//  * @param minLiquidity Minimum LP tokens to receive
//  */
// function addAnchorLiquidity(uint256 usdcAmount, uint256 usyAmount, uint256 minLiquidity)
//     external
//     returns (uint256 liquidity)
// {
//     require(usdcAmount > 0 && usyAmount > 0, "YoloHook: amounts must be > 0");

//     // Transfer tokens to hook
//     IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcAmount);
//     anchor.burn(msg.sender, usyAmount); // Burn USY from user

//     uint256 _totalSupply = anchorPoolLiquiditySupply;

//     if (_totalSupply == 0) {
//         // First liquidity provision
//         liquidity = _sqrt(usdcAmount * usyAmount) - MINIMUM_LIQUIDITY;
//         anchorPoolLiquiditySupply = liquidity + MINIMUM_LIQUIDITY;
//         // Lock minimum liquidity forever
//     } else {
//         // Subsequent liquidity provision - maintain ratio
//         uint256 liquidityFromUSDC = (usdcAmount * _totalSupply) / totalAnchorReserveUSDC;
//         uint256 liquidityFromUSY = (usyAmount * _totalSupply) / totalAnchorReserveUSY;
//         liquidity = liquidityFromUSDC < liquidityFromUSY ? liquidityFromUSDC : liquidityFromUSY;
//         anchorPoolLiquiditySupply += liquidity;
//     }

//     require(liquidity >= minLiquidity, "YoloHook: insufficient liquidity minted");

//     // Update reserves
//     totalAnchorReserveUSDC += usdcAmount;
//     totalAnchorReserveUSY += usyAmount;

//     // Update user balance
//     anchorPoolLPBalance[msg.sender] += liquidity;

//     emit AnchorLiquidityAdded(msg.sender, usdcAmount, usyAmount, liquidity);
// }

// /**
//  * @notice Remove liquidity from the anchor pool
//  * @param liquidity Amount of LP tokens to burn
//  * @param minUSDC Minimum USDC to receive
//  * @param minUSY Minimum USY to receive
//  */
// function removeAnchorLiquidity(uint256 liquidity, uint256 minUSDC, uint256 minUSY)
//     external
//     returns (uint256 usdcAmount, uint256 usyAmount)
// {
//     require(liquidity > 0, "YoloHook: liquidity must be > 0");
//     require(anchorPoolLPBalance[msg.sender] >= liquidity, "YoloHook: insufficient LP balance");

//     uint256 _totalSupply = anchorPoolLiquiditySupply;

//     // Calculate proportional amounts
//     usdcAmount = (liquidity * totalAnchorReserveUSDC) / _totalSupply;
//     usyAmount = (liquidity * totalAnchorReserveUSY) / _totalSupply;

//     require(usdcAmount >= minUSDC && usyAmount >= minUSY, "YoloHook: insufficient amounts");

//     // Update state
//     anchorPoolLPBalance[msg.sender] -= liquidity;
//     anchorPoolLiquiditySupply -= liquidity;
//     totalAnchorReserveUSDC -= usdcAmount;
//     totalAnchorReserveUSY -= usyAmount;

//     // Transfer tokens back to user
//     IERC20(usdc).safeTransfer(msg.sender, usdcAmount);
//     anchor.mint(msg.sender, usyAmount); // Mint USY to user

//     emit AnchorLiquidityRemoved(msg.sender, usdcAmount, usyAmount, liquidity);
// }

// // ********************************//
// // *** STABLESWAP MATH FUNCTIONS ***//
// // ******************************* //

// /**
//  * @notice Calculate stableswap invariant: x³y + y³x = k
//  */
// function _k(uint256 x, uint256 y) internal pure returns (uint256) {
//     uint256 _x = x * PRECISION / PRECISION; // Already normalized to 18 decimals
//     uint256 _y = y * PRECISION / PRECISION;
//     uint256 _a = (_x * _y) / PRECISION;
//     uint256 _b = ((_x * _x) / PRECISION + (_y * _y) / PRECISION);
//     return (_a * _b) / PRECISION; // x³y + y³x
// }

// /**
//  * @notice Helper function for Newton-Raphson method: f(x0, y) = x0(y²/1e18*y/1e18)/1e18 + (x0²/1e18*x0/1e18)*y/1e18
//  */
// function _f(uint256 x0, uint256 y) internal pure returns (uint256) {
//     return x0 * (y * y / PRECISION * y / PRECISION) / PRECISION + (x0 * x0 / PRECISION * x0 / PRECISION) * y / PRECISION;
// }

// /**
//  * @notice Derivative for Newton-Raphson: f'(x0, y) = 3*x0*(y²/1e18)/1e18 + (x0²/1e18*x0/1e18)
//  */
// function _d(uint256 x0, uint256 y) internal pure returns (uint256) {
//     return 3 * x0 * (y * y / PRECISION) / PRECISION + (x0 * x0 / PRECISION * x0 / PRECISION);
// }

// /**
//  * @notice Newton-Raphson method to find y given x and k
//  */
// function _get_y(uint256 x0, uint256 xy, uint256 y) internal pure returns (uint256) {
//     for (uint256 i = 0; i < 255; i++) {
//         uint256 y_prev = y;
//         uint256 k = _f(x0, y);

//         if (k < xy) {
//             uint256 dy = (xy - k) * PRECISION / _d(x0, y);
//             y = y + dy;
//         } else {
//             uint256 dy = (k - xy) * PRECISION / _d(x0, y);
//             y = y - dy;
//         }

//         if (y > y_prev) {
//             if (y - y_prev <= 1) {
//                 return y;
//             }
//         } else {
//             if (y_prev - y <= 1) {
//                 return y;
//             }
//         }
//     }
//     return y;
// }

// /**
//  * @notice Calculate output amount for stableswap
//  * @param amountIn Input amount (after fees)
//  * @param reserveIn Input token reserve
//  * @param reserveOut Output token reserve
//  */
// function _getStableAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
//     if (amountIn == 0) return 0;

//     uint256 xy = _k(reserveIn, reserveOut);
//     uint256 y = reserveOut - _get_y(amountIn + reserveIn, xy, reserveOut);

//     return y;
// }

// /**
//  * @notice Updated _beforeSwap function with stableswap logic
//  */
// function _beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
//     internal
//     override
//     returns (bytes4, BeforeSwapDelta, uint24)
// {
//     bytes32 id = PoolId.unwrap(key.toId());
//     require(isAnchorPool[id] || isSyntheticPool[id], "YoloHook: unrecognized pool");

//     uint256 amountInOutPositive =
//         params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);

//     // Cancel out amount to bypass PoolManager's default swap logic
//     BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(int128(-params.amountSpecified), int128(params.amountSpecified));

//     if (isAnchorPool[id]) {
//         // *** STABLESWAP LOGIC FOR ANCHOR POOL ***

//         (Currency curIn, Currency curOut) =
//             params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

//         uint256 inFee = (amountInOutPositive * stableSwapFee) / PRECISION_DIVISOR;
//         uint256 netIn = amountInOutPositive - inFee;

//         bool usdcForUSY = Currency.unwrap(curIn) == usdc;

//         uint256 amountOut;
//         if (usdcForUSY) {
//             // USDC → USY: Use stableswap math
//             amountOut = _getStableAmountOut(netIn, totalAnchorReserveUSDC, totalAnchorReserveUSY);

//             // Pull USDC from user
//             curIn.settle(poolManager, sender, amountInOutPositive, false);

//             // Update reserves
//             totalAnchorReserveUSDC += netIn;
//             totalAnchorReserveUSY -= amountOut;

//             // Mint USY to user, fee to treasury
//             anchor.mint(sender, amountOut);
//             anchor.mint(treasury, inFee);
//         } else {
//             // USY → USDC: Use stableswap math
//             amountOut = _getStableAmountOut(netIn, totalAnchorReserveUSY, totalAnchorReserveUSDC);

//             // Burn USY from user
//             anchor.burn(sender, amountInOutPositive);

//             // Update reserves
//             totalAnchorReserveUSY += netIn;
//             totalAnchorReserveUSDC -= amountOut;

//             // Pay out USDC to user, fee to treasury
//             curOut.settle(poolManager, sender, amountOut, false);
//             curOut.settle(poolManager, treasury, inFee, false);
//         }

//         // Verify K invariant hasn't decreased
//         require(
//             _k(totalAnchorReserveUSDC, totalAnchorReserveUSY)
//                 >= _k(
//                     totalAnchorReserveUSDC - (usdcForUSY ? netIn : -int256(amountOut)),
//                     totalAnchorReserveUSY - (usdcForUSY ? -int256(amountOut) : netIn)
//                 ),
//             "YoloHook: K invariant violation"
//         );

//         emit AnchorSwapExecuted(sender, usdcForUSY, netIn, amountOut, inFee);
//     } else {
//         // *** SYNTHETIC SWAP LOGIC (UNCHANGED) ***

//         (Currency curIn, Currency curOut) =
//             params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

//         uint256 inFee = (amountInOutPositive * syntheticSwapFee) / PRECISION_DIVISOR;
//         uint256 netIn = amountInOutPositive - inFee;

//         // Pull the full amount from user
//         curIn.settle(poolManager, sender, amountInOutPositive, false);

//         // Take fee to treasury and net amount to hook
//         curIn.take(poolManager, treasury, inFee, true);
//         curIn.take(poolManager, address(this), netIn, true);

//         // Burn the input synthetic asset
//         IYoloSyntheticAsset(address(Currency.unwrap(curIn))).burn(address(this), netIn);

//         // Oracle-based conversion and mint output
//         uint256 priceIn = yoloOracle.getAssetPrice(address(Currency.unwrap(curIn)));
//         uint256 priceOut = yoloOracle.getAssetPrice(address(Currency.unwrap(curOut)));
//         uint256 usdValue = netIn * priceIn;
//         uint256 outAmt = usdValue / priceOut;

//         IYoloSyntheticAsset(address(Currency.unwrap(curOut))).mint(sender, outAmt);

//         emit HookSwapExecuted(
//             id,
//             sender,
//             params.zeroForOne,
//             address(Currency.unwrap(curIn)),
//             netIn,
//             address(Currency.unwrap(curOut)),
//             outAmt,
//             inFee
//         );
//     }

//     return (this.beforeSwap.selector, beforeSwapDelta, 0);
// }

// // **********************//
// // *** HELPER FUNCTIONS ***//
// // ********************* //

// /**
//  * @notice Square root function for liquidity calculation
//  */
// function _sqrt(uint256 x) internal pure returns (uint256) {
//     if (x == 0) return 0;
//     uint256 z = (x + 1) / 2;
//     uint256 y = x;
//     while (z < y) {
//         y = z;
//         z = (x / z + z) / 2;
//     }
//     return y;
// }

// /**
//  * @notice Get anchor pool reserves
//  */
// function getAnchorReserves() external view returns (uint256 usdcReserve, uint256 usyReserve) {
//     return (totalAnchorReserveUSDC, totalAnchorReserveUSY);
// }

// /**
//  * @notice Calculate swap output amount (view function)
//  */
// function getStableSwapAmountOut(address tokenIn, uint256 amountIn) external view returns (uint256 amountOut) {
//     require(tokenIn == usdc || tokenIn == address(anchor), "YoloHook: invalid token");

//     // Remove fee from input
//     uint256 netAmountIn = amountIn - (amountIn * stableSwapFee) / PRECISION_DIVISOR;

//     if (tokenIn == usdc) {
//         amountOut = _getStableAmountOut(netAmountIn, totalAnchorReserveUSDC, totalAnchorReserveUSY);
//     } else {
//         amountOut = _getStableAmountOut(netAmountIn, totalAnchorReserveUSY, totalAnchorReserveUSDC);
//     }
// }
