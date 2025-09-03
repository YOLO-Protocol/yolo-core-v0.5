// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.26;

// import "forge-std/Test.sol";
// import {Test01_YoloHookFunctionality} from "./Test01_YoloHookFunctionality.t.sol";
// import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// import {StakedYoloUSD} from "../src/tokenization/StakedYoloUSD.sol";
// import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
// import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
// import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
// import {PoolSwapTest as YoloHookTestHelper} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

// /**
//  * @title Test02_sUSYTransferAndLP
//  * @notice Comprehensive tests for sUSY LP token transfers and position management
//  * @dev Tests that LP positions are correctly transferred with sUSY tokens
//  */
// contract Test02_sUSYTransferAndLP is Test01_YoloHookFunctionality {
    
//     address alice;
//     address bob;
//     address charlie;
    
//     // Convenience variables
//     IERC20 usdc;
//     IERC20 usy;
//     IERC20 sUSY;  // Use IERC20 interface for transfer operations
//     StakedYoloUSD sUSYToken;  // Use this for sUSY-specific functions
    
//     function setUp() public override {
//         super.setUp();
        
//         // Create test users
//         alice = makeAddr("alice");
//         bob = makeAddr("bob");
//         charlie = makeAddr("charlie");
        
//         // Set up convenience variables
//         usdc = IERC20(symbolToDeployedAsset["USDC"]);
//         usy = IERC20(address(yoloHookProxy.anchor()));
//         sUSY = IERC20(address(yoloHookProxy.sUSY()));
//         sUSYToken = StakedYoloUSD(address(yoloHookProxy.sUSY()));
        
//         // Fund test users with USDC and USY
//         deal(address(usdc), alice, 1_000_000e6); // 1M USDC
//         deal(address(usy), alice, 1_000_000e18); // 1M USY
//         deal(address(usdc), bob, 1_000_000e6);
//         deal(address(usy), bob, 1_000_000e18);
//         deal(address(usdc), charlie, 1_000_000e6);
//         deal(address(usy), charlie, 1_000_000e18);
        
//         // Approve hook to spend tokens
//         vm.startPrank(alice);
//         usdc.approve(address(yoloHookProxy), type(uint256).max);
//         usy.approve(address(yoloHookProxy), type(uint256).max);
//         vm.stopPrank();
        
//         vm.startPrank(bob);
//         usdc.approve(address(yoloHookProxy), type(uint256).max);
//         usy.approve(address(yoloHookProxy), type(uint256).max);
//         vm.stopPrank();
        
//         vm.startPrank(charlie);
//         usdc.approve(address(yoloHookProxy), type(uint256).max);
//         usy.approve(address(yoloHookProxy), type(uint256).max);
//         vm.stopPrank();
//     }
    
//     /**
//      * @notice Test that sUSY tokens are correctly minted on liquidity addition
//      */
//     function test_sUSY_MintOnAddLiquidity() external {
//         console.log("\n==================== test_sUSY_MintOnAddLiquidity ====================");
        
//         uint256 usdcAmount = 10_000e6; // 10k USDC
//         uint256 usyAmount = 10_000e18; // 10k USY
        
//         // Record initial balances
//         uint256 aliceInitialSUSY = sUSY.balanceOf(alice);
//         uint256 totalSupplyBefore = sUSY.totalSupply();
        
//         // Alice adds liquidity
//         vm.startPrank(alice);
//         (uint256 usdcUsed, uint256 usyUsed, uint256 liquidityMinted,) = 
//             yoloHookProxy.addLiquidity(usdcAmount, usyAmount, 0, alice);
//         vm.stopPrank();
        
//         // Verify sUSY was minted to Alice
//         uint256 aliceFinalSUSY = sUSY.balanceOf(alice);
//         uint256 totalSupplyAfter = sUSY.totalSupply();
        
//         assertEq(aliceFinalSUSY - aliceInitialSUSY, liquidityMinted, "Alice should receive sUSY equal to liquidity");
//         // Note: Total supply includes 1000 minimum liquidity locked on first mint
//         assertTrue(totalSupplyAfter - totalSupplyBefore >= liquidityMinted, "Total supply should increase by at least liquidity amount");
        
//         console.log("Alice received sUSY:", liquidityMinted);
//         console.log("Total sUSY supply:", totalSupplyAfter);
//     }
    
//     /**
//      * @notice Test that sUSY tokens can be transferred between users
//      */
//     function test_sUSY_TransferBetweenUsers() external {
//         console.log("\n==================== test_sUSY_TransferBetweenUsers ====================");
        
//         // Alice adds liquidity first
//         vm.startPrank(alice);
//         (,,uint256 liquidityMinted,) = yoloHookProxy.addLiquidity(10_000e6, 10_000e18, 0, alice);
        
//         uint256 aliceBalanceBefore = sUSY.balanceOf(alice);
//         uint256 bobBalanceBefore = sUSY.balanceOf(bob);
        
//         // Alice transfers half of her sUSY to Bob
//         uint256 transferAmount = liquidityMinted / 2;
//         sUSY.transfer(bob, transferAmount);
//         vm.stopPrank();
        
//         // Verify balances after transfer
//         uint256 aliceBalanceAfter = sUSY.balanceOf(alice);
//         uint256 bobBalanceAfter = sUSY.balanceOf(bob);
        
//         assertEq(aliceBalanceAfter, aliceBalanceBefore - transferAmount, "Alice balance should decrease");
//         assertEq(bobBalanceAfter, bobBalanceBefore + transferAmount, "Bob balance should increase");
        
//         console.log("Alice transferred:", transferAmount);
//         console.log("Alice balance after:", aliceBalanceAfter);
//         console.log("Bob balance after:", bobBalanceAfter);
//     }
    
//     /**
//      * @notice Test that transferred sUSY allows the recipient to remove liquidity
//      */
//     function test_sUSY_TransferredTokensCanRemoveLiquidity() external {
//         console.log("\n==================== test_sUSY_TransferredTokensCanRemoveLiquidity ====================");
        
//         // Alice adds liquidity
//         vm.startPrank(alice);
//         (,,uint256 liquidityMinted,) = yoloHookProxy.addLiquidity(10_000e6, 10_000e18, 0, alice);
        
//         // Alice transfers all sUSY to Bob
//         sUSY.transfer(bob, liquidityMinted);
//         vm.stopPrank();
        
//         // Record Bob's initial balances
//         uint256 bobUsdcBefore = usdc.balanceOf(bob);
//         uint256 bobUsyBefore = usy.balanceOf(bob);
        
//         // Bob removes liquidity using the transferred sUSY
//         vm.startPrank(bob);
//         (uint256 usdcReceived, uint256 usyReceived,,) = 
//             yoloHookProxy.removeLiquidity(0, 0, liquidityMinted, bob);
//         vm.stopPrank();
        
//         // Verify Bob received the underlying assets
//         uint256 bobUsdcAfter = usdc.balanceOf(bob);
//         uint256 bobUsyAfter = usy.balanceOf(bob);
        
//         assertEq(bobUsdcAfter - bobUsdcBefore, usdcReceived, "Bob should receive USDC");
//         assertEq(bobUsyAfter - bobUsyBefore, usyReceived, "Bob should receive USY");
//         assertEq(sUSY.balanceOf(bob), 0, "Bob's sUSY should be burned");
        
//         console.log("Bob removed liquidity using transferred sUSY");
//         console.log("USDC received:", usdcReceived);
//         console.log("USY received:", usyReceived);
//     }
    
//     /**
//      * @notice Test partial transfer of sUSY and proportional liquidity removal
//      */
//     function test_sUSY_PartialTransferAndProportionalRemoval() external {
//         console.log("\n==================== test_sUSY_PartialTransferAndProportionalRemoval ====================");
        
//         // Alice adds liquidity
//         vm.startPrank(alice);
//         (,,uint256 liquidityMinted,) = yoloHookProxy.addLiquidity(20_000e6, 20_000e18, 0, alice);
        
//         // Alice transfers 25% to Bob and 25% to Charlie
//         uint256 transferToBob = liquidityMinted / 4;
//         uint256 transferToCharlie = liquidityMinted / 4;
        
//         sUSY.transfer(bob, transferToBob);
//         sUSY.transfer(charlie, transferToCharlie);
//         vm.stopPrank();
        
//         // Each user removes their portion of liquidity
//         vm.startPrank(bob);
//         (uint256 bobUsdcReceived, uint256 bobUsyReceived,,) = 
//             yoloHookProxy.removeLiquidity(0, 0, transferToBob, bob);
//         vm.stopPrank();
        
//         vm.startPrank(charlie);
//         (uint256 charlieUsdcReceived, uint256 charlieUsyReceived,,) = 
//             yoloHookProxy.removeLiquidity(0, 0, transferToCharlie, charlie);
//         vm.stopPrank();
        
//         // Alice removes her remaining 50%
//         vm.startPrank(alice);
//         uint256 aliceRemaining = sUSY.balanceOf(alice);
//         (uint256 aliceUsdcReceived, uint256 aliceUsyReceived,,) = 
//             yoloHookProxy.removeLiquidity(0, 0, aliceRemaining, alice);
//         vm.stopPrank();
        
//         // Verify proportional distributions
//         assertApproxEqRel(bobUsdcReceived, charlieUsdcReceived, 0.01e18, "Bob and Charlie should receive similar amounts");
//         assertApproxEqRel(aliceUsdcReceived, bobUsdcReceived * 2, 0.01e18, "Alice should receive ~2x Bob's amount");
        
//         console.log("Bob received USDC:", bobUsdcReceived);
//         console.log("Bob received USY:", bobUsyReceived);
//         console.log("Charlie received USDC:", charlieUsdcReceived);
//         console.log("Charlie received USY:", charlieUsyReceived);
//         console.log("Alice received USDC:", aliceUsdcReceived);
//         console.log("Alice received USY:", aliceUsyReceived);
//     }
    
//     /**
//      * @notice Test that sUSY value appreciation benefits all holders proportionally
//      */
//     function test_sUSY_ValueAppreciationSharedByTransferredTokens() external {
//         console.log("\n==================== test_sUSY_ValueAppreciationSharedByTransferredTokens ====================");
        
//         // Alice adds initial liquidity
//         vm.startPrank(alice);
//         (,,uint256 aliceLiquidity,) = yoloHookProxy.addLiquidity(50_000e6, 50_000e18, 0, alice);
        
//         // Alice transfers half to Bob before any swaps
//         uint256 transferAmount = aliceLiquidity / 2;
//         sUSY.transfer(bob, transferAmount);
//         vm.stopPrank();
        
//         // Record exchange rate before swaps
//         uint256 rateBefore = sUSYToken.getExchangeRate();
//         console.log("Exchange rate before swaps:", rateBefore);
        
//         // Generate fees through swaps (Charlie does swaps)
//         // First, get the anchor pool key
//         bool anchorPoolToken0IsUSDC = address(usdc) < address(usy);
//         PoolKey memory anchorKey = PoolKey({
//             currency0: Currency.wrap(anchorPoolToken0IsUSDC ? address(usdc) : address(usy)),
//             currency1: Currency.wrap(anchorPoolToken0IsUSDC ? address(usy) : address(usdc)),
//             fee: 0,
//             tickSpacing: 1,
//             hooks: IHooks(address(yoloHookProxy))
//         });
        
//         // Charlie approves and swaps to generate fees
//         vm.startPrank(charlie);
//         usdc.approve(address(swapRouter), type(uint256).max);
//         // Do 10 swaps of 100 USDC each to generate fees
//         for (uint i = 0; i < 10; i++) {
//             // Swap USDC for USY
//             swapRouter.swap(
//                 anchorKey,
//                 SwapParams({
//                     zeroForOne: anchorPoolToken0IsUSDC,
//                     amountSpecified: -100e6, // 100 USDC
//                     sqrtPriceLimitX96: 0
//                 }),
//                 YoloHookTestHelper.TestSettings({takeClaims: false, settleUsingBurn: false}),
//                 ZERO_BYTES
//             );
//         }
//         vm.stopPrank();
        
//         // Check exchange rate after swaps
//         uint256 rateAfter = sUSYToken.getExchangeRate();
//         console.log("Exchange rate after swaps:", rateAfter);
//         assertTrue(rateAfter > rateBefore, "Exchange rate should increase from fees");
        
//         // Both Alice and Bob remove liquidity
//         vm.startPrank(alice);
//         uint256 aliceBalance = sUSY.balanceOf(alice);
//         (uint256 aliceUsdcReceived, uint256 aliceUsyReceived,,) = 
//             yoloHookProxy.removeLiquidity(0, 0, aliceBalance, alice);
//         vm.stopPrank();
        
//         vm.startPrank(bob);
//         uint256 bobBalance = sUSY.balanceOf(bob);
//         (uint256 bobUsdcReceived, uint256 bobUsyReceived,,) = 
//             yoloHookProxy.removeLiquidity(0, 0, bobBalance, bob);
//         vm.stopPrank();
        
//         // Calculate total value received (in USDC terms for simplicity)
//         uint256 aliceTotalValue = aliceUsdcReceived + (aliceUsyReceived / 1e12); // Convert USY to USDC decimals
//         uint256 bobTotalValue = bobUsdcReceived + (bobUsyReceived / 1e12);
        
//         // Both should have received more than their initial deposit
//         assertTrue(aliceTotalValue > 5_000e6, "Alice should profit from fees");
//         assertTrue(bobTotalValue > 5_000e6, "Bob should profit from fees");
        
//         console.log("Alice total value received:", aliceTotalValue);
//         console.log("Bob total value received:", bobTotalValue);
//     }
    
//     /**
//      * @notice Test that user cannot remove more liquidity than their sUSY balance
//      */
//     function test_sUSY_CannotRemoveMoreThanBalance() external {
//         console.log("\n==================== test_sUSY_CannotRemoveMoreThanBalance ====================");
        
//         // Alice adds liquidity
//         vm.startPrank(alice);
//         (,,uint256 liquidityMinted,) = yoloHookProxy.addLiquidity(10_000e6, 10_000e18, 0, alice);
        
//         // Alice transfers most sUSY to Bob
//         uint256 transferAmount = (liquidityMinted * 90) / 100; // 90%
//         sUSY.transfer(bob, transferAmount);
        
//         uint256 aliceRemaining = sUSY.balanceOf(alice);
//         console.log("Alice remaining sUSY:", aliceRemaining);
        
//         // Alice tries to remove more than her balance
//         vm.expectRevert(); // Should revert with insufficient balance
//         yoloHookProxy.removeLiquidity(0, 0, aliceRemaining + 1, alice);
//         vm.stopPrank();
        
//         console.log("Correctly prevented removal beyond balance");
//     }
    
//     /**
//      * @notice Test multiple sequential transfers maintain correct LP ownership
//      */
//     function test_sUSY_MultipleTransfersChain() external {
//         console.log("\n==================== test_sUSY_MultipleTransfersChain ====================");
        
//         // Alice adds liquidity
//         vm.startPrank(alice);
//         (,,uint256 liquidityMinted,) = yoloHookProxy.addLiquidity(10_000e6, 10_000e18, 0, alice);
        
//         // Alice -> Bob
//         sUSY.transfer(bob, liquidityMinted);
//         vm.stopPrank();
        
//         assertEq(sUSY.balanceOf(alice), 0, "Alice should have 0");
//         assertEq(sUSY.balanceOf(bob), liquidityMinted, "Bob should have all");
        
//         // Bob -> Charlie
//         vm.startPrank(bob);
//         sUSY.transfer(charlie, liquidityMinted);
//         vm.stopPrank();
        
//         assertEq(sUSY.balanceOf(bob), 0, "Bob should have 0");
//         assertEq(sUSY.balanceOf(charlie), liquidityMinted, "Charlie should have all");
        
//         // Charlie can remove all liquidity
//         vm.startPrank(charlie);
//         (uint256 usdcReceived, uint256 usyReceived,,) = 
//             yoloHookProxy.removeLiquidity(0, 0, liquidityMinted, charlie);
//         vm.stopPrank();
        
//         assertTrue(usdcReceived > 0 && usyReceived > 0, "Charlie should receive assets");
//         assertEq(sUSY.balanceOf(charlie), 0, "Charlie's sUSY should be burned");
        
//         console.log("Transfer chain: Alice -> Bob -> Charlie");
//         console.log("Charlie successfully removed liquidity");
//     }
    
//     /**
//      * @notice Test that sUSY follows ERC20 approval/transferFrom pattern
//      */
//     function test_sUSY_ApprovalAndTransferFrom() external {
//         console.log("\n==================== test_sUSY_ApprovalAndTransferFrom ====================");
        
//         // Alice adds liquidity
//         vm.startPrank(alice);
//         (,,uint256 liquidityMinted,) = yoloHookProxy.addLiquidity(10_000e6, 10_000e18, 0, alice);
        
//         // Alice approves Bob to spend her sUSY
//         sUSY.approve(bob, liquidityMinted / 2);
//         vm.stopPrank();
        
//         // Bob transfers Alice's sUSY to Charlie using transferFrom
//         vm.startPrank(bob);
//         sUSY.transferFrom(alice, charlie, liquidityMinted / 2);
//         vm.stopPrank();
        
//         assertEq(sUSY.balanceOf(alice), liquidityMinted / 2, "Alice should have half");
//         assertEq(sUSY.balanceOf(charlie), liquidityMinted / 2, "Charlie should have half");
        
//         // Charlie can remove liquidity with transferred tokens
//         vm.startPrank(charlie);
//         (uint256 usdcReceived, uint256 usyReceived,,) = 
//             yoloHookProxy.removeLiquidity(0, 0, sUSY.balanceOf(charlie), charlie);
//         vm.stopPrank();
        
//         assertTrue(usdcReceived > 0 && usyReceived > 0, "Charlie should receive assets");
        
//         console.log("Approval and transferFrom worked correctly");
//         console.log("Charlie received USDC:", usdcReceived);
//         console.log("Charlie received USY:", usyReceived);
//     }
    
//     /**
//      * @notice Test edge case: transfer to address that already has sUSY
//      */
//     function test_sUSY_TransferToExistingHolder() external {
//         console.log("\n==================== test_sUSY_TransferToExistingHolder ====================");
        
//         // Both Alice and Bob add liquidity
//         vm.startPrank(alice);
//         (,,uint256 aliceLiquidity,) = yoloHookProxy.addLiquidity(10_000e6, 10_000e18, 0, alice);
//         vm.stopPrank();
        
//         vm.startPrank(bob);
//         (,,uint256 bobLiquidity,) = yoloHookProxy.addLiquidity(5_000e6, 5_000e18, 0, bob);
//         vm.stopPrank();
        
//         uint256 bobBalanceBefore = sUSY.balanceOf(bob);
        
//         // Alice transfers to Bob (who already has sUSY)
//         vm.startPrank(alice);
//         uint256 transferAmount = aliceLiquidity / 2;
//         sUSY.transfer(bob, transferAmount);
//         vm.stopPrank();
        
//         uint256 bobBalanceAfter = sUSY.balanceOf(bob);
//         assertEq(bobBalanceAfter, bobBalanceBefore + transferAmount, "Bob's balance should increase correctly");
        
//         // Bob can remove all his liquidity
//         vm.startPrank(bob);
//         (uint256 usdcReceived, uint256 usyReceived,,) = 
//             yoloHookProxy.removeLiquidity(0, 0, bobBalanceAfter, bob);
//         vm.stopPrank();
        
//         assertEq(sUSY.balanceOf(bob), 0, "Bob's sUSY should be fully burned");
        
//         console.log("Bob's combined position removed successfully");
//         console.log("Total USDC received:", usdcReceived);
//         console.log("Total USY received:", usyReceived);
//     }
    
//     /**
//      * @notice Test that sUSY total supply remains consistent through transfers
//      */
//     function test_sUSY_TotalSupplyConsistency() external {
//         console.log("\n==================== test_sUSY_TotalSupplyConsistency ====================");
        
//         // Alice adds liquidity
//         vm.startPrank(alice);
//         (,,uint256 liquidityMinted,) = yoloHookProxy.addLiquidity(10_000e6, 10_000e18, 0, alice);
//         vm.stopPrank();
        
//         uint256 totalSupplyBefore = sUSY.totalSupply();
        
//         // Multiple transfers
//         vm.startPrank(alice);
//         sUSY.transfer(bob, liquidityMinted / 3);
//         sUSY.transfer(charlie, liquidityMinted / 3);
//         vm.stopPrank();
        
//         uint256 totalSupplyAfterTransfers = sUSY.totalSupply();
//         assertEq(totalSupplyBefore, totalSupplyAfterTransfers, "Total supply should not change on transfers");
        
//         // Verify sum of balances equals total supply
//         uint256 sumOfBalances = sUSY.balanceOf(alice) + sUSY.balanceOf(bob) + sUSY.balanceOf(charlie);
//         // MINIMUM_LIQUIDITY (1000) is locked at address(1) during first liquidity addition
//         assertEq(sumOfBalances, totalSupplyAfterTransfers - 1000, "Sum of balances should equal supply minus locked liquidity");
        
//         console.log("Total supply remained consistent:", totalSupplyAfterTransfers);
//         console.log("Sum of user balances:", sumOfBalances);
//     }
// }