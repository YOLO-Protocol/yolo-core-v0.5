// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "./base/Base01_DeployUniswapV4Pool.t.sol";
import "./base/Base02_DeployMockAssetsAndOracles.t.sol";
/*---------- IMPORT CONTRACTS ----------*/
import {PublicTransparentUpgradeableProxy} from "@yolo/contracts/proxy/PublicTransparentUpgradeableProxy.sol";
import {YoloHook} from "@yolo/contracts/core/YoloHook.sol";
import {YoloOracle} from "@yolo/contracts/core/YoloOracle.sol";
import {IPoolManager, ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
/*---------- IMPORT LIBRARIES & TYPES ----------*/
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
/*---------- IMPORT TEST SUITES ----------*/
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/**
 * @title   Test01_YoloHookFunctionality
 * @author  0xyolodev.eth
 * @dev     This contract is meant to test the core functionalities of the
 *          YoloHook contract, including the interaction with Uniswap V4 pools.
 *          (This is the most important test script)
 *
 *          1. Creation of the anchor pool
 *          2. Liquidity providing of the anchor pool -> must rever on PoolManager and can only be done on the Hook
 *          3. Swapping of the anchor pool
 *          4. Math of the anchor pool (CSMM -> StableSwap)
 *          5. Creation of the Yolo synthetic assets
 *          6. Minting, burning, flash loaning of Yolo synthetic assets
 *          7. Liquidation of Yolo synthetic assets
 */
contract Test01_YoloHookFunctionality is Test, Base01_DeployUniswapV4Pool, Base02_DeployMockAssetsAndOracles {
    YoloHook public yoloHookImplementation;
    YoloHook public yoloHookProxy;
    YoloOracle public yoloOracle;

    function setUp() public virtual override(Base01_DeployUniswapV4Pool, Base02_DeployMockAssetsAndOracles) {
        // Set up the base contracts
        Base01_DeployUniswapV4Pool.setUp();
        Base02_DeployMockAssetsAndOracles.setUp();

        // A. Deploy YoloHook Implementation and Proxy

        // Precompute the addresses for the YoloHook implementation and proxy in testing
        address hookImplementationAddress = address(uint160(Hooks.ALL_HOOK_MASK));
        address hookProxyAddress = address(uint160(Hooks.ALL_HOOK_MASK << 1) + 1);

        // Both address needs to be full flag enabled - last 14 bits should be 1
        console.log("Hook Implementation Binary Format:");
        _logAddressAsBinary(hookImplementationAddress);
        console.log("Hook Proxy Binary Format:");
        _logAddressAsBinary(hookProxyAddress);

        /// Deploy code to the hook implementation & proxy addresses
        deployCodeTo("YoloHook.sol", abi.encode(manager), hookImplementationAddress);
        yoloHookImplementation = YoloHook(hookImplementationAddress);
        deployCodeTo(
            "PublicTransparentUpgradeableProxy.sol",
            abi.encode(hookImplementationAddress, address(this), ""),
            hookProxyAddress
        );
        yoloHookProxy = YoloHook(hookProxyAddress);

        assertEq(
            PublicTransparentUpgradeableProxy(payable(address(yoloHookProxy))).implementation(),
            hookImplementationAddress,
            "Test01: YoloHook implementation address mismatch"
        );
        console.log("Hook Implementation: ", hookImplementationAddress);
        console.log("Hook Proxy: ", hookProxyAddress);

        console.log("Successfully deployed YoloHook implementation and proxy contracts.");

        // B. Deploy the YoloOracle contract

        // Extract the deployed assets and oracles from the base contract

        address[] memory assets = new address[](getMockAssetsLength());
        address[] memory oracles = new address[](getMockAssetsLength());

        for (uint256 i = 0; i < getMockAssetsLength(); i++) {
            string memory symbol = getMockAssetSymbol(i);
            assets[i] = symbolToDeployedAsset[symbol];

            string memory description = string(abi.encodePacked(symbol, " / USD"));
            // console.log("Description: ", description);
            address oracleAddress = symbolToDeployedOracle[description];
            // console.log("Oracle Address: ", oracleAddress);
            require(oracleAddress != address(0), string(abi.encodePacked("Oracle not found for ", symbol)));
            oracles[i] = oracleAddress;

            emit log_named_address(string(abi.encodePacked("Linked Oracle for Asset: ", symbol)), oracleAddress);
        }

        // Deploy the YoloOracle contract
        yoloOracle = new YoloOracle(assets, oracles);

        console.log("Successfully deployed YoloOracle contract at address:", address(yoloOracle));

        console.log("Tester Address Is: ", address(this));
        console.log(
            "YoloHook Proxy Admin Is: ", PublicTransparentUpgradeableProxy(payable(address(yoloHookProxy))).proxyAdmin()
        );
        console.log("YoloHook Implementation Owner Is: ", yoloHookImplementation.owner());
        console.log("YoloHook Proxy Owner Is: ", yoloHookProxy.owner());

        // C. Initialize the YoloHook proxy contract
        yoloHookProxy.initialize(
            address(weth),
            address(this),
            address(yoloOracle),
            5, // 0.05% stable swap fee
            20, // 0.2% synthetic swap fee
            10, // 0.1% flash loan fee
            symbolToDeployedAsset["USDC"] // USDC address
        );
        console.log();
        console.log("============================================================");
        console.log();
    }

    function test_Test01_Case01_cannotAddLiquidityOnPoolManager() external {
        console.log("==================== test_Test01_Case01_cannotAddLiquidityOnPoolManager ====================");

        // Initialize USDC Balance
        IERC20Metadata usdc = IERC20Metadata(symbolToDeployedAsset["USDC"]);
        deal(address(usdc), address(this), 100_000e6); // 100,000 USDC

        // Initialize USY Balance
        IERC20Metadata usy = IERC20Metadata(address(yoloHookProxy.anchor()));
        assertNotEq(address(usy), address(0), "Test01: USY anchor address is zero");
        deal(address(usy), address(this), 100_000e18); // 100,000 USY

        // Approve PoolManager to pull tokens
        usdc.approve(address(manager), type(uint256).max);
        usy.approve(address(manager), type(uint256).max);

        // Construct the PoolKey for the anchor pool
        address tokenA = address(usdc);
        address tokenB = address(usy);
        bool usdcIs0 = tokenA < tokenB;

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(usdcIs0 ? tokenA : tokenB),
            currency1: Currency.wrap(usdcIs0 ? tokenB : tokenA),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(yoloHookProxy))
        });

        // Try to add liquidity directly through PoolManager - should revert
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000e18, salt: bytes32(0)});

        // Test 1: revert with ManagerLocked error since wasnt unlocked through PositionsManager
        vm.expectRevert(IPoolManager.ManagerLocked.selector);
        manager.modifyLiquidity(key, params, "");

        // Test 2: Try with modifyLiquidityNoChecks - should also revert with hook error
        console.log("Testing with modifyLiquidityNoChecks...");
        vm.expectRevert();
        modifyLiquidityNoChecks.modifyLiquidity(key, params, "");

        console.log("Successfully prevented direct liquidity addition through PoolManager");
    }

    function test_Test01_Case02_addLiquidityOnHook() external {
        console.log("==================== test_Test01_Case02_addLiquidityOnHook ====================");

        // Initialize USDC Balance
        IERC20Metadata usdc = IERC20Metadata(symbolToDeployedAsset["USDC"]);

        // Check USDC decimals and adjust amounts accordingly
        uint8 usdcDecimals = usdc.decimals();
        console.log("USDC Decimals:", usdcDecimals);

        uint256 totalUsdcAmount = usdcDecimals == 18 ? 100_000e18 : 100_000e6;
        uint256 firstUsdcAmount = usdcDecimals == 18 ? 50_000e18 : 50_000e6;
        uint256 secondUsdcAmount = usdcDecimals == 18 ? 10_000e18 : 10_000e6;

        deal(address(usdc), address(this), totalUsdcAmount);

        // Initialize USY Balance
        IERC20Metadata usy = IERC20Metadata(address(yoloHookProxy.anchor()));
        assertNotEq(address(usy), address(0), "Test01: USY anchor address is zero");
        deal(address(usy), address(this), 100_000e18); // 100,000 USY

        // // Approve Hook to pull tokens
        usdc.approve(address(yoloHookProxy), type(uint256).max);
        usy.approve(address(yoloHookProxy), type(uint256).max);

        // Approve PoolManager as well (needed for settle operations)
        // usdc.approve(address(manager), type(uint256).max);
        // usy.approve(address(manager), type(uint256).max);

        // Initial balances
        uint256 balUsdcBefore = usdc.balanceOf(address(this));
        uint256 balUsyBefore = usy.balanceOf(address(this));
        console.log("User USDC Before:", balUsdcBefore);
        console.log("User USY Before:", balUsyBefore);

        // Get initial pool state
        (uint256 usdcReserveBefore, uint256 usyReserveBefore) = yoloHookProxy.getAnchorReserves();
        uint256 lpBalanceBefore = yoloHookProxy.anchorPoolLPBalance(address(this));
        uint256 totalSupplyBefore = yoloHookProxy.anchorPoolLiquiditySupply();

        console.log("Pool USDC Reserve Before:", usdcReserveBefore);
        console.log("Pool USY Reserve Before:", usyReserveBefore);
        console.log("User LP Balance Before:", lpBalanceBefore);
        console.log("Total LP Supply Before:", totalSupplyBefore);

        // Add liquidity through the hook
        uint256 maxUsdcAmount = firstUsdcAmount;
        uint256 maxUsyAmount = 60_000e18; // 60,000 USY (more than USDC to test ratio enforcement)
        uint256 minLiquidity = 0; // Accept any amount for testing

        // Calculate expected amounts
        // For first liquidity with 1:1 ratio enforcement, it uses the smaller amount in WAD
        uint256 expectedUsdcUsed = firstUsdcAmount;
        uint256 expectedUsyUsed = 50_000e18; // Always 50,000e18 regardless of USDC decimals
        uint256 expectedLiquidity = 50_000e18 - 1000; // Since both are equal in WAD

        // Call addLiquidity
        (uint256 usdcUsed, uint256 usyUsed, uint256 liquidityMinted, address receiver) =
            yoloHookProxy.addLiquidity(maxUsdcAmount, maxUsyAmount, minLiquidity, address(this));

        console.log("USDC Used:", usdcUsed);
        console.log("USY Used:", usyUsed);
        console.log("Liquidity Minted:", liquidityMinted);

        // Verify amounts
        assertEq(usdcUsed, expectedUsdcUsed, "USDC used should match expected");
        assertEq(usyUsed, expectedUsyUsed, "USY used should match expected");
        assertEq(liquidityMinted, expectedLiquidity, "Liquidity minted should match expected");

        // Check balances after
        uint256 balUsdcAfter = usdc.balanceOf(address(this));
        uint256 balUsyAfter = usy.balanceOf(address(this));
        console.log("User USDC After:", balUsdcAfter);
        console.log("User USY After:", balUsyAfter);

        assertEq(balUsdcBefore - balUsdcAfter, usdcUsed, "USDC balance change should match used amount");
        assertEq(balUsyBefore - balUsyAfter, usyUsed, "USY balance change should match used amount");

        // Check pool state after
        (uint256 usdcReserveAfter, uint256 usyReserveAfter) = yoloHookProxy.getAnchorReserves();
        uint256 lpBalanceAfter = yoloHookProxy.anchorPoolLPBalance(address(this));
        uint256 totalSupplyAfter = yoloHookProxy.anchorPoolLiquiditySupply();

        console.log("Pool USDC Reserve After:", usdcReserveAfter);
        console.log("Pool USY Reserve After:", usyReserveAfter);
        console.log("User LP Balance After:", lpBalanceAfter);
        console.log("Total LP Supply After:", totalSupplyAfter);

        assertEq(usdcReserveAfter, usdcUsed, "USDC reserve should equal used amount");
        assertEq(usyReserveAfter, usyUsed, "USY reserve should equal used amount");
        assertEq(lpBalanceAfter, liquidityMinted, "User LP balance should equal minted amount");
        assertEq(totalSupplyAfter, liquidityMinted + 1000, "Total supply should equal minted + minimum liquidity");

        // Test adding more liquidity (non-first liquidity)
        console.log("\n--- Adding more liquidity (testing ratio maintenance) ---");

        // Try to add liquidity with imbalanced amounts
        uint256 secondUsyAmount = 5_000e18; // 5,000 USY (less than proportional)

        (usdcUsed, usyUsed, liquidityMinted,) =
            yoloHookProxy.addLiquidity(secondUsdcAmount, secondUsyAmount, 0, address(this));

        console.log("Second Add - USDC Used:", usdcUsed);
        console.log("Second Add - USY Used:", usyUsed);
        console.log("Second Add - Liquidity Minted:", liquidityMinted);

        // Since USY is limiting, it should use all USY and proportional USDC
        assertEq(usyUsed, secondUsyAmount, "Should use all USY when it's limiting");
        assertTrue(usdcUsed <= secondUsdcAmount, "Should not use more USDC than provided");

        console.log("Successfully added liquidity through YoloHook");
    }

    function test_Test01_Case03_removeLiquidityOnHook() external {
        console.log("==================== test_Test01_Case03_removeLiquidityOnHook ====================");

        // ---- 0. Set-up: fund tester and add initial liquidity -------------------------
        IERC20Metadata usdc = IERC20Metadata(symbolToDeployedAsset["USDC"]);
        IERC20Metadata usy = IERC20Metadata(address(yoloHookProxy.anchor()));

        uint256 usdcRaw = usdc.decimals() == 18 ? 50_000e18 : 50_000e6; // 50k
        uint256 usyRaw = 50_000e18;

        deal(address(usdc), address(this), usdcRaw);
        deal(address(usy), address(this), usyRaw);

        usdc.approve(address(yoloHookProxy), type(uint256).max);
        usy.approve(address(yoloHookProxy), type(uint256).max);

        // add liquidity and grab minted LP tokens
        (,, uint256 lpMinted,) = yoloHookProxy.addLiquidity(usdcRaw, usyRaw, 0, address(this));
        assertGt(lpMinted, 0, "LP minted");

        // ---- 1. Snapshot before we remove --------------------------------------------
        uint256 lpUserBefore = yoloHookProxy.anchorPoolLPBalance(address(this));
        uint256 lpTotalBefore = yoloHookProxy.anchorPoolLiquiditySupply();
        (uint256 resUsdcBefore, uint256 resUsyBefore) = yoloHookProxy.getAnchorReserves();

        uint256 balUsdcBefore = usdc.balanceOf(address(this));
        uint256 balUsyBefore = usy.balanceOf(address(this));

        // we’ll remove half
        uint256 lpToBurn = lpMinted / 2;
        assertEq(lpToBurn * 2, lpMinted, "use even lp for easy math");

        // expected amounts (floor-division to match contract’s round-down)
        uint256 expectUsdc = lpToBurn * resUsdcBefore / lpTotalBefore;
        uint256 expectUsy = lpToBurn * resUsyBefore / lpTotalBefore;

        // ---- 2. Happy-path withdraw ---------------------------------------------------
        (uint256 usdcOut, uint256 usyOut,,) = yoloHookProxy.removeLiquidity(0, 0, lpToBurn, address(this));

        // core invariants
        assertEq(usdcOut, expectUsdc, "pro-rata USDC");
        assertEq(usyOut, expectUsy, "pro-rata USY");

        assertEq(usdc.balanceOf(address(this)), balUsdcBefore + usdcOut, "USDC credited");
        assertEq(usy.balanceOf(address(this)), balUsyBefore + usyOut, "USY credited");

        assertEq(yoloHookProxy.anchorPoolLPBalance(address(this)), lpUserBefore - lpToBurn, "LP burned from user");
        assertEq(yoloHookProxy.anchorPoolLiquiditySupply(), lpTotalBefore - lpToBurn, "total LP supply shrank");

        (uint256 resUsdcAfter, uint256 resUsyAfter) = yoloHookProxy.getAnchorReserves();
        assertEq(resUsdcAfter, resUsdcBefore - usdcOut, "reserve USDC down");
        assertEq(resUsyAfter, resUsyBefore - usyOut, "reserve USY down");

        // ---- 3. Revert paths ----------------------------------------------------------
        // a) too-strict minimums
        vm.expectRevert(YoloHook.YoloHook__InsufficientAmount.selector);
        yoloHookProxy.removeLiquidity(usdcOut + 1, usyOut + 1, lpToBurn, address(this));

        // b) trying to burn more than you have
        vm.expectRevert(YoloHook.YoloHook__InsufficientLiquidityBalance.selector);
        yoloHookProxy.removeLiquidity(0, 0, lpMinted, address(this)); // user now has < lpMinted
    }

    function test_Test01_Case04_swapExactInputUsdcToUsy() external {
        console.log("==================== test_Test01_Case04_swapExactInputUsdcToUsy ====================");
        // 1. seed pool with balanced liquidity (20 k / 20 k)
        IERC20Metadata usdc = IERC20Metadata(symbolToDeployedAsset["USDC"]);
        IERC20Metadata usy = IERC20Metadata(address(yoloHookProxy.anchor()));
        uint256 initUsdc = usdc.decimals() == 18 ? 20_000e18 : 20_000e6;
        uint256 initUsy = 20_000e18;
        deal(address(usdc), address(this), initUsdc);
        deal(address(usy), address(this), initUsy);
        usdc.approve(address(yoloHookProxy), type(uint256).max);
        usy.approve(address(yoloHookProxy), type(uint256).max);
        yoloHookProxy.addLiquidity(initUsdc, initUsy, 0, address(this));

        // 2. do a 1 000 USDC exact-input swap
        uint256 sellRaw = usdc.decimals() == 18 ? 15_000e18 : 15_000e6;
        deal(address(usdc), address(this), sellRaw); // fund
        usdc.approve(address(swapRouter), sellRaw);

        (PoolKey memory key_, bool usdcIs0) = _anchorKey();
        SwapParams memory sp = SwapParams({
            zeroForOne: usdcIs0, // sell currency0 if USDC is 0
            amountSpecified: -int256(sellRaw), // negative => exact-in
            sqrtPriceLimitX96: 0
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // 3. snapshot balances
        uint256 balUsyBefore = usy.balanceOf(address(this));
        uint256 feeBps = yoloHookProxy.stableSwapFee();

        usdc.approve(address(swapRouter), type(uint256).max);
        usy.approve(address(swapRouter), type(uint256).max);

        swapRouter.swap(key_, sp, settings, "");

        // 4. verify: user received ≥ netOut predicted by hook math
        uint256 balUsyAfter = usy.balanceOf(address(this));
        uint256 gotOut = balUsyAfter - balUsyBefore;
        console.log("USY Before: ", balUsyBefore);
        console.log("USY After: ", balUsyAfter);
        assertGt(gotOut, 0, "out > 0");

        // fee should equal sellRaw * feeBps / 10_000
        uint256 expectFee = (sellRaw * feeBps) / 10_000;
        assertEq(usdc.balanceOf(address(yoloHookProxy.treasury())), expectFee, "fee forwarded");
    }

    function test_Test01_Case05_swapExactInputUsyToUsdc() external {
        console.log("==================== test_Test01_Case05_swapExactInputUsyToUsdc ====================");
        // seed with 20k/20k from liquidityProvider
        IERC20Metadata usdc = IERC20Metadata(symbolToDeployedAsset["USDC"]);
        IERC20Metadata usy = IERC20Metadata(address(yoloHookProxy.anchor()));
        uint256 initUsdc = usdc.decimals() == 18 ? 20_000e18 : 20_000e6;
        uint256 initUsy = 20_000e18;
        address liquidityProvider = makeAddr("moneyGuy");
        address swapper = makeAddr("swapGuy");
        deal(address(usdc), liquidityProvider, initUsdc);
        deal(address(usy), liquidityProvider, initUsy);
        vm.startPrank(liquidityProvider);
        usdc.approve(address(yoloHookProxy), type(uint256).max);
        usy.approve(address(yoloHookProxy), type(uint256).max);
        yoloHookProxy.addLiquidity(initUsdc, initUsy, 0, address(this));

        // sell 5 000 USY
        uint256 sellUsy = 5_000e18;
        deal(address(usy), swapper, sellUsy);
        vm.startPrank(swapper);
        usy.approve(address(swapRouter), sellUsy);

        (PoolKey memory key_, bool usdcIs0) = _anchorKey();
        SwapParams memory sp = SwapParams({
            zeroForOne: !usdcIs0, // opposite direction
            amountSpecified: -int256(sellUsy),
            sqrtPriceLimitX96: 0
        });

        uint256 balUSDCBefore = usdc.balanceOf(swapper);

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(key_, sp, settings, "");

        uint256 balUSDCAfter = usdc.balanceOf(swapper);
        console.log("USDC Before: ", balUSDCBefore);
        console.log("USDC After: ", balUSDCAfter);
        assertGt(balUSDCAfter, balUSDCBefore, "received USDC");
    }

    function test_Test01_Case06_swapExactOutputUsdcToUsy() external {
        console.log("==================== test_Test01_Case06_swapExactOutputUsdcToUsy ====================");

        // seed with 20k/20k from liquidityProvider
        IERC20Metadata usdc = IERC20Metadata(symbolToDeployedAsset["USDC"]);
        IERC20Metadata usy = IERC20Metadata(address(yoloHookProxy.anchor()));
        uint256 initUsdc = usdc.decimals() == 18 ? 10_000e18 : 10_000e6;
        uint256 initUsy = 10_000e18;

        address liquidityProvider = makeAddr("moneyGuy");
        address swapper = makeAddr("swapGuy");

        vm.startPrank(liquidityProvider);

        deal(address(usdc), liquidityProvider, initUsdc);
        deal(address(usy), liquidityProvider, initUsy);
        usdc.approve(address(yoloHookProxy), type(uint256).max);
        usy.approve(address(yoloHookProxy), type(uint256).max);
        yoloHookProxy.addLiquidity(initUsdc, initUsy, 0, address(this));

        // pull 1 000 USY (exact-output)
        uint256 wantOut = 1_000e18;
        (PoolKey memory key_, bool usdcIs0) = _anchorKey();
        SwapParams memory sp = SwapParams({
            zeroForOne: usdcIs0,
            amountSpecified: int256(wantOut), // positive => exact-out
            sqrtPriceLimitX96: 0
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // we don't know in-advance gross USDC-in, so just fund plenty
        deal(address(usdc), swapper, usdc.decimals() == 18 ? 5_000e18 : 5_000e6);
        vm.startPrank(swapper);
        usdc.approve(address(swapRouter), type(uint256).max);

        uint256 balUsyBefore = usy.balanceOf(swapper);
        swapRouter.swap(key_, sp, settings, "");
        uint256 balUsyafter = usy.balanceOf(swapper);
        console.log("USY Before: ", balUsyBefore);
        console.log("USY After: ", balUsyafter);
        assertEq(balUsyafter, wantOut, "got exact out");
    }



    // ************************ //
    // *** HELPER FUNCTIONS *** //
    // ************************ //

    /**
     * @notice  Takes in an address and logs its binary representation.
     * @dev     Used to check an address format for Uniswap V4 hooks.
     * @param   _addr   Address to be logged in binary format.
     */
    function _logAddressAsBinary(address _addr) public {
        bytes20 b = bytes20(_addr);
        bytes memory out = new bytes(160); // 20 bytes * 8 bits

        for (uint256 i = 0; i < 20; i++) {
            uint8 byteVal = uint8(b[i]);
            for (uint256 j = 0; j < 8; j++) {
                out[i * 8 + (7 - j)] = (byteVal & (1 << j)) != 0 ? bytes1("1") : bytes1("0");
            }
        }

        console.log(string(out));
    }

    // Helper function for square root calculation
    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x >> 1) + 1;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) >> 1;
        }
        return y;
    }

    function _anchorKey() internal view returns (PoolKey memory key, bool usdcIs0) {
        IERC20Metadata usdc = IERC20Metadata(symbolToDeployedAsset["USDC"]);
        IERC20Metadata usy = IERC20Metadata(address(yoloHookProxy.anchor()));
        usdcIs0 = address(usdc) < address(usy);
        key = PoolKey({
            currency0: Currency.wrap(usdcIs0 ? address(usdc) : address(usy)),
            currency1: Currency.wrap(usdcIs0 ? address(usy) : address(usdc)),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(yoloHookProxy))
        });
    }
}
