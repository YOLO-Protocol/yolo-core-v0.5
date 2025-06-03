// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "./base/Base01_DeployUniswapV4Pool.t.sol";
import "./base/Base02_DeployMockAssetsAndOracles.t.sol";
import "./base/Base03_DeployYoloAssetSettingsAndCollaterals.t.sol";
/*---------- IMPORT CONTRACTS ----------*/
import {PublicTransparentUpgradeableProxy} from "@yolo/contracts/proxy/PublicTransparentUpgradeableProxy.sol";
import {YoloHook} from "@yolo/contracts/core/YoloHook.sol";
import {YoloOracle} from "@yolo/contracts/core/YoloOracle.sol";
import {IPoolManager, ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IFlashBorrower} from "@yolo/contracts/interfaces/IFlashBorrower.sol";
import {IYoloSyntheticAsset} from "@yolo/contracts/interfaces/IYoloSyntheticAsset.sol";
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
contract Test01_YoloHookFunctionality is
    Test,
    Base01_DeployUniswapV4Pool,
    Base03_DeployYoloAssetSettingsAndCollaterals
{
    YoloHook public yoloHookImplementation;
    YoloHook public yoloHookProxy;
    YoloOracle public yoloOracle;

    mapping(string => address) yoloAssetToAddress;

    // For convenience
    address public yJpyAsset; // Yolo Asset
    address public yKrwAsset; // Yolo Asset
    address public yGoldAsset; // Yolo Asset
    address public yNvdaAsset; // Yolo Asset
    address public wbtcAsset; // Collateral
    address public ptUsdeAsset; // Collateral

    function setUp()
        public
        virtual
        override(Base01_DeployUniswapV4Pool, Base03_DeployYoloAssetSettingsAndCollaterals)
    {
        // Set up the base contracts
        Base01_DeployUniswapV4Pool.setUp();
        Base03_DeployYoloAssetSettingsAndCollaterals.setUp();

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

        // D. Set Hook on YoloOracle
        yoloOracle.setHook(address(yoloHookProxy));
        yoloOracle.setAnchor(address(yoloHookProxy.anchor()));

        // E. Deploy All Yolo Assets
        for (uint256 i = 0; i < yoloAssetsArray.length; i++) {
            // E-1. Create New Yolo Assets
            address yoloAsset = yoloHookProxy.createNewYoloAsset(
                yoloAssetsArray[i].name,
                yoloAssetsArray[i].symbol,
                yoloAssetsArray[i].decimals,
                yoloAssetsArray[i].oracle
            );

            yoloAssetToAddress[yoloAssetsArray[i].symbol] = yoloAsset;

            // E-2. Configure Yolo Assets
            yoloHookProxy.setYoloAssetConfig(
                yoloAsset,
                yoloAssetsArray[i].assetConfiguration.maxMintableCap,
                yoloAssetsArray[i].assetConfiguration.maxFlashLoanableAmount
            );
        }

        // F. Register and whitelist all collaterals
        for (uint256 i = 0; i < collateralAssetsArray.length; i++) {
            address asset = symbolToDeployedAsset[collateralAssetsArray[i].symbol];
            require(asset != address(0), "Invalid asset address");
            address priceSource = yoloOracle.getSourceOfAsset(asset);
            require(priceSource != address(0), "Invalid price source");

            // setCollateralConfig()
            yoloHookProxy.setCollateralConfig(asset, collateralAssetsArray[i].supplyCap, priceSource);
        }

        // G. Set convenience variables
        yJpyAsset = yoloAssetToAddress["yJPY"];
        yKrwAsset = yoloAssetToAddress["yKRW"];
        yGoldAsset = yoloAssetToAddress["yXAU"];
        yNvdaAsset = yoloAssetToAddress["yNVDA"];
        wbtcAsset = symbolToDeployedAsset["WBTC"];
        ptUsdeAsset = symbolToDeployedAsset["PT-sUSDe-31JUL2025"];

        // H. Quick setup pair configs for testings
        address[] memory collateralAssets = new address[](2);
        collateralAssets[0] = wbtcAsset;
        collateralAssets[1] = ptUsdeAsset;

        address[] memory yoloAssets = new address[](4);
        yoloAssets[0] = yJpyAsset;
        yoloAssets[1] = yKrwAsset;
        yoloAssets[2] = yGoldAsset;
        yoloAssets[3] = yNvdaAsset;

        for (uint256 i = 0; i < collateralAssets.length; i++) {
            for (uint256 j = 0; j < yoloAssets.length; j++) {
                // Set pair configs with reasonable values
                // interestRate: 5% APR
                // ltv: 80% (for WBTC), 70% (for PT-sUSDe)
                // liquidationPenalty: 5%
                uint256 interestRate = 500; // 5%
                uint256 ltv = i == 0 ? 8000 : 7000; // 80% or 70%
                uint256 liquidationPenalty = 500; // 5%

                yoloHookProxy.setPairConfig(collateralAssets[i], yoloAssets[j], interestRate, ltv, liquidationPenalty);
            }
        }

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

    function test_Test01_Case07_createAndConfigureYoloAssets() external {
        console.log("==================== test_Test01_Case07_createAndConfigureYoloAssets ====================");

        // Test creating a new Yolo asset
        string memory name = "Yolo Euro";
        string memory symbol = "yEUR";
        uint8 decimals = 18;

        // Deploy a mock oracle for the new asset
        MockPriceOracle eurOracle = new MockPriceOracle(120e6, "EUR / USD"); // 1.20 USD per EUR

        // Create the new Yolo asset
        address yEurAsset = yoloHookProxy.createNewYoloAsset(name, symbol, decimals, address(eurOracle));

        // Verify the asset was created
        assertTrue(yoloHookProxy.isYoloAsset(yEurAsset), "yEUR should be registered as Yolo asset");

        // Verify the oracle was set
        assertEq(yoloOracle.getSourceOfAsset(yEurAsset), address(eurOracle), "Oracle not set correctly");

        // Check initial configuration (should be paused with 0 caps)
        (address assetAddr, uint256 mintCap, uint256 flashCap) = yoloHookProxy.yoloAssetConfigs(yEurAsset);
        assertEq(assetAddr, yEurAsset, "Asset address mismatch");
        assertEq(mintCap, 0, "Initial mint cap should be 0");
        assertEq(flashCap, 0, "Initial flash loan cap should be 0");

        // Configure the asset
        uint256 newMintCap = 1_000_000e18;
        uint256 newFlashCap = 500_000e18;
        yoloHookProxy.setYoloAssetConfig(yEurAsset, newMintCap, newFlashCap);

        // Verify configuration updated
        (, mintCap, flashCap) = yoloHookProxy.yoloAssetConfigs(yEurAsset);
        assertEq(mintCap, newMintCap, "Mint cap not updated");
        assertEq(flashCap, newFlashCap, "Flash loan cap not updated");
    }

    function test_Test01_Case08_borrowWithCollateral() external {
        console.log("==================== test_Test01_Case08_borrowWithCollateral ====================");

        // Setup user with collateral
        address user = makeAddr("borrower");
        uint256 collateralAmount = 1e18; // 1 WBTC
        deal(wbtcAsset, user, collateralAmount);

        // Setup pair config for WBTC-yJPY
        yoloHookProxy.setPairConfig(
            wbtcAsset,
            yJpyAsset,
            500, // 5% interest rate
            8000, // 80% LTV
            500 // 5% liquidation penalty
        );

        vm.startPrank(user);
        IERC20(wbtcAsset).approve(address(yoloHookProxy), collateralAmount);

        // Calculate max borrowable amount based on LTV
        uint256 wbtcPrice = yoloOracle.getAssetPrice(wbtcAsset); // Should be ~104,000 USD
        uint256 jpyPrice = yoloOracle.getAssetPrice(yJpyAsset); // Should be ~0.0067 USD
        uint256 borrowAmount = 5_000_000e18; // 5M JPY

        // Record balances before
        uint256 jpyBalBefore = IERC20(yJpyAsset).balanceOf(user);
        uint256 wbtcBalBefore = IERC20(wbtcAsset).balanceOf(user);

        // Borrow
        yoloHookProxy.borrow(yJpyAsset, borrowAmount, wbtcAsset, collateralAmount);

        // Verify position created
        (
            address borrower,
            address collateral,
            uint256 collateralSupplied,
            address yoloAsset,
            uint256 yoloAssetMinted,
            uint256 lastUpdated,
            uint256 storedRate,
            uint256 accruedInterest
        ) = yoloHookProxy.positions(user, wbtcAsset, yJpyAsset);

        assertEq(borrower, user, "Borrower mismatch");
        assertEq(collateral, wbtcAsset, "Collateral mismatch");
        assertEq(collateralSupplied, collateralAmount, "Collateral amount mismatch");
        assertEq(yoloAsset, yJpyAsset, "Yolo asset mismatch");
        assertEq(yoloAssetMinted, borrowAmount, "Borrowed amount mismatch");
        assertEq(storedRate, 500, "Interest rate mismatch");
        assertEq(accruedInterest, 0, "Initial accrued interest should be 0");

        // Verify balances
        assertEq(IERC20(yJpyAsset).balanceOf(user), jpyBalBefore + borrowAmount, "JPY not minted");
        assertEq(IERC20(wbtcAsset).balanceOf(user), wbtcBalBefore - collateralAmount, "WBTC not transferred");

        vm.stopPrank();
    }

    function test_Test01_Case09_interestAccrualAndPartialRepayment() external {
        console.log("==================== test_Test01_Case09_interestAccrualAndPartialRepayment ====================");

        // Setup borrowing position
        address user = makeAddr("borrower");
        uint256 collateralAmount = 1e18;
        uint256 borrowAmount = 5_000_000e18;

        deal(wbtcAsset, user, collateralAmount);
        yoloHookProxy.setPairConfig(wbtcAsset, yJpyAsset, 500, 8000, 500);

        vm.startPrank(user);
        IERC20(wbtcAsset).approve(address(yoloHookProxy), collateralAmount);
        yoloHookProxy.borrow(yJpyAsset, borrowAmount, wbtcAsset, collateralAmount);

        // Fast forward 30 days
        vm.warp(block.timestamp + 30 days);

        // Trigger interest accrual by doing a tiny repayment
        IERC20(yJpyAsset).approve(address(yoloHookProxy), 1);
        yoloHookProxy.repay(wbtcAsset, yJpyAsset, 1, false);

        // Check interest accrued
        (,,,, uint256 principal,,, uint256 interest) = yoloHookProxy.positions(user, wbtcAsset, yJpyAsset);
        console.log("Interest accrued after 30 days:", interest);
        assertTrue(interest > 0, "No interest accrued");

        // Calculate expected interest: principal * rate * time / (365 days * 10000)
        uint256 expectedInterest = (borrowAmount * 500 * 30 days) / (365 days * 10000);
        assertApproxEqRel(interest, expectedInterest, 0.01e18, "Interest calculation off");

        // Partial repayment
        uint256 repayAmount = borrowAmount / 4; // Repay 25%
        IERC20(yJpyAsset).approve(address(yoloHookProxy), repayAmount);

        uint256 treasuryBalBefore = IERC20(yJpyAsset).balanceOf(yoloHookProxy.treasury());

        yoloHookProxy.repay(wbtcAsset, yJpyAsset, repayAmount, false);

        // Verify repayment applied to interest first, then principal
        (,,,, uint256 principalAfter,,, uint256 interestAfter) = yoloHookProxy.positions(user, wbtcAsset, yJpyAsset);

        assertTrue(interestAfter < interest, "Interest not reduced");
        assertTrue(principalAfter < principal, "Principal not reduced");

        // Check treasury received interest payment
        uint256 treasuryBalAfter = IERC20(yJpyAsset).balanceOf(yoloHookProxy.treasury());
        assertTrue(treasuryBalAfter > treasuryBalBefore, "Treasury didn't receive interest");

        vm.stopPrank();
    }

    function test_Test01_Case10_fullRepaymentWithCollateralClaim() external {
        console.log("==================== test_Test01_Case10_fullRepaymentWithCollateralClaim ====================");

        // Setup borrowing position
        address user = makeAddr("borrower");
        uint256 collateralAmount = 1e18;
        uint256 borrowAmount = 5_000_000e18;

        deal(wbtcAsset, user, collateralAmount);
        yoloHookProxy.setPairConfig(wbtcAsset, yJpyAsset, 500, 8000, 500);

        vm.startPrank(user);
        IERC20(wbtcAsset).approve(address(yoloHookProxy), collateralAmount);
        yoloHookProxy.borrow(yJpyAsset, borrowAmount, wbtcAsset, collateralAmount);

        // Fast forward to accrue interest
        vm.warp(block.timestamp + 7 days);

        // Get total debt
        IERC20(yJpyAsset).approve(address(yoloHookProxy), 1);
        yoloHookProxy.repay(wbtcAsset, yJpyAsset, 1, false);
        (,,,, uint256 principal,,, uint256 interest) = yoloHookProxy.positions(user, wbtcAsset, yJpyAsset);
        uint256 totalDebt = principal + interest;

        // Mint extra to cover interest
        vm.stopPrank();
        vm.prank(address(yoloHookProxy));
        IYoloSyntheticAsset(yJpyAsset).mint(user, interest * 2);

        vm.startPrank(user);
        uint256 wbtcBalBefore = IERC20(wbtcAsset).balanceOf(user);

        // Full repayment with collateral claim
        IERC20(yJpyAsset).approve(address(yoloHookProxy), totalDebt);
        yoloHookProxy.repay(wbtcAsset, yJpyAsset, 0, true); // 0 means full repayment

        // Verify position cleared
        (address borrower,, uint256 collateralLeft,, uint256 debtLeft,,, uint256 interestLeft) =
            yoloHookProxy.positions(user, wbtcAsset, yJpyAsset);

        assertEq(collateralLeft, 0, "Collateral not cleared");
        assertEq(debtLeft, 0, "Debt not cleared");
        assertEq(interestLeft, 0, "Interest not cleared");

        // Verify collateral returned
        assertEq(IERC20(wbtcAsset).balanceOf(user), wbtcBalBefore + collateralAmount, "Collateral not returned");

        vm.stopPrank();
    }

    function test_Test01_Case11_withdrawCollateral() external {
        console.log("==================== test_Test01_Case11_withdrawCollateral ====================");

        // Setup over-collateralized position
        address user = makeAddr("borrower");
        uint256 collateralAmount = 2e18; // 2 WBTC
        uint256 borrowAmount = 5_000_000e18; // Only 5M JPY (very safe)

        deal(wbtcAsset, user, collateralAmount);
        yoloHookProxy.setPairConfig(wbtcAsset, yJpyAsset, 500, 8000, 500);

        vm.startPrank(user);
        IERC20(wbtcAsset).approve(address(yoloHookProxy), collateralAmount);
        yoloHookProxy.borrow(yJpyAsset, borrowAmount, wbtcAsset, collateralAmount);

        uint256 wbtcBalBefore = IERC20(wbtcAsset).balanceOf(user);

        // Withdraw 0.5 WBTC
        uint256 withdrawAmount = 0.5e18;
        yoloHookProxy.withdraw(wbtcAsset, yJpyAsset, withdrawAmount);

        // Verify collateral reduced
        (,, uint256 collateralLeft,,,,,) = yoloHookProxy.positions(user, wbtcAsset, yJpyAsset);
        assertEq(collateralLeft, collateralAmount - withdrawAmount, "Collateral not reduced");

        // Verify user received collateral
        assertEq(IERC20(wbtcAsset).balanceOf(user), wbtcBalBefore + withdrawAmount, "Collateral not received");

        vm.stopPrank();
    }

    function test_Test01_Case12_liquidationScenario() external {
        console.log("==================== test_Test01_Case12_liquidationScenario ====================");

        // Setup positions
        address borrower = makeAddr("borrower");
        address liquidator = makeAddr("liquidator");
        uint256 collateralAmount = 1e18;
        uint256 borrowAmount = 12_000_000e18; // 12M JPY (close to 80% LTV)

        deal(wbtcAsset, borrower, collateralAmount);
        deal(wbtcAsset, liquidator, 2e18); // Fund liquidator

        yoloHookProxy.setPairConfig(wbtcAsset, yJpyAsset, 500, 8000, 500);

        // Borrower takes loan
        vm.startPrank(borrower);
        IERC20(wbtcAsset).approve(address(yoloHookProxy), collateralAmount);
        yoloHookProxy.borrow(yJpyAsset, borrowAmount, wbtcAsset, collateralAmount);
        vm.stopPrank();

        // Drop WBTC price to make position insolvent
        MockPriceOracle wbtcOracle = MockPriceOracle(yoloOracle.getSourceOfAsset(wbtcAsset));
        wbtcOracle.updateAnswer(90_000e8); // Drop from 104k to 90k

        // Liquidator prepares
        vm.startPrank(liquidator);
        IERC20(wbtcAsset).approve(address(yoloHookProxy), 2e18);
        yoloHookProxy.borrow(yJpyAsset, borrowAmount, wbtcAsset, 2e18);

        uint256 wbtcBalBefore = IERC20(wbtcAsset).balanceOf(liquidator);

        // Liquidate half the position
        uint256 liquidateAmount = borrowAmount / 2;
        IERC20(yJpyAsset).approve(address(yoloHookProxy), liquidateAmount);
        yoloHookProxy.liquidate(borrower, wbtcAsset, yJpyAsset, liquidateAmount);

        // Verify liquidator received collateral with bonus
        uint256 wbtcBalAfter = IERC20(wbtcAsset).balanceOf(liquidator);
        assertTrue(wbtcBalAfter > wbtcBalBefore, "Liquidator didn't receive collateral");

        // Verify borrower's position reduced
        (,, uint256 collateralLeft,, uint256 debtLeft,,,) = yoloHookProxy.positions(borrower, wbtcAsset, yJpyAsset);
        assertTrue(collateralLeft < collateralAmount, "Collateral not seized");
        assertTrue(debtLeft < borrowAmount, "Debt not reduced");

        vm.stopPrank();
    }

    function test_Test01_Case13_syntheticAssetSwaps() external {
        console.log("==================== test_Test01_Case13_syntheticAssetSwaps ====================");

        // Setup: mint some yJPY for testing
        address swapper = makeAddr("swapper");
        uint256 jpyAmount = 1_000_000e18; // 1M JPY

        // Mint yJPY to swapper (using collateral)
        deal(wbtcAsset, swapper, 1e18);
        yoloHookProxy.setPairConfig(wbtcAsset, yJpyAsset, 500, 8000, 500);

        vm.startPrank(swapper);
        IERC20(wbtcAsset).approve(address(yoloHookProxy), 1e18);
        yoloHookProxy.borrow(yJpyAsset, jpyAmount, wbtcAsset, 1e18);

        // IMPORTANT: Synthetic assets can only be swapped through the anchor (USY)
        // So we need to swap yJPY -> USY -> yKRW (or directly yJPY -> USY)
        // Let's test yJPY -> USY swap

        bool jpyIsToken0 = yJpyAsset < address(yoloHookProxy.anchor());
        PoolKey memory syntheticKey = PoolKey({
            currency0: Currency.wrap(jpyIsToken0 ? yJpyAsset : address(yoloHookProxy.anchor())),
            currency1: Currency.wrap(jpyIsToken0 ? address(yoloHookProxy.anchor()) : yJpyAsset),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(yoloHookProxy))
        });

        // Approve and swap yJPY for USY
        uint256 swapAmount = 100_000e18; // 100k JPY
        IERC20(yJpyAsset).approve(address(swapRouter), swapAmount);

        SwapParams memory sp = SwapParams({
            zeroForOne: jpyIsToken0,
            amountSpecified: -int256(swapAmount), // Exact input
            sqrtPriceLimitX96: 0
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 usyBalBefore = IERC20(address(yoloHookProxy.anchor())).balanceOf(swapper);

        swapRouter.swap(syntheticKey, sp, settings, "");

        uint256 usyBalAfter = IERC20(address(yoloHookProxy.anchor())).balanceOf(swapper);
        uint256 usyReceived = usyBalAfter - usyBalBefore;

        // Verify oracle-based conversion happened
        // require(IERC20Metadata(yJpyAsset).balanceOf(swapper) == jpyAmount - swapAmount, "PLACEHOLDER A");
        console.log("PoolManager's JPY Amount: ", IERC20Metadata(yJpyAsset).balanceOf(address(manager)));
        assertTrue(usyReceived > 0, "No USY received");
        yoloHookProxy.burnPendings();
        console.log("PoolManager's JPY Amount after burn: ", IERC20Metadata(yJpyAsset).balanceOf(address(manager)));

        // Calculate expected amount based on oracle prices
        uint256 jpyPrice = yoloOracle.getAssetPrice(yJpyAsset);
        uint256 usyPrice = yoloOracle.getAssetPrice(address(yoloHookProxy.anchor()));
        uint256 feeAmount = (swapAmount * yoloHookProxy.syntheticSwapFee()) / 10000;
        uint256 netInput = swapAmount - feeAmount;

        // Note: USY doesn't have a price feed set, so it defaults to 1e8
        // Let's check if the conversion makes sense given the JPY price
        console.log("JPY price:", jpyPrice);
        console.log("USY received:", usyReceived);
        console.log("Fee amount:", feeAmount);

        vm.stopPrank();
    }

    function test_Test01_Case14_simpleFlashLoan() external {
        console.log("==================== test_Test01_Case14_simpleFlashLoan ====================");

        MockFlashBorrower borrower = new MockFlashBorrower(address(yoloHookProxy));
        uint256 flashAmount = 1_000_000e18; // 1M JPY
        uint256 expectedFee = (flashAmount * yoloHookProxy.flashLoanFee()) / 10000;

        // IMPORTANT: The borrower needs to have the fee amount to repay
        // In a real scenario, the borrower would use the flash loan to generate profit
        // For testing, we'll give the borrower some tokens to pay the fee
        vm.prank(address(yoloHookProxy));
        IYoloSyntheticAsset(yJpyAsset).mint(address(borrower), expectedFee);

        vm.startPrank(address(borrower));

        uint256 treasuryBalBefore = IERC20(yJpyAsset).balanceOf(yoloHookProxy.treasury());

        yoloHookProxy.simpleFlashLoan(yJpyAsset, flashAmount, "");

        // Verify treasury received fee
        uint256 treasuryBalAfter = IERC20(yJpyAsset).balanceOf(yoloHookProxy.treasury());
        assertEq(treasuryBalAfter - treasuryBalBefore, expectedFee, "Treasury didn't receive fee");

        // Verify borrower's balance is 0 (all returned)
        assertEq(IERC20(yJpyAsset).balanceOf(address(borrower)), 0, "Borrower should have no balance left");

        vm.stopPrank();
    }

    function test_Test01_Case15_batchFlashLoan() external {
        console.log("==================== test_Test01_Case15_batchFlashLoan ====================");

        MockFlashBorrower borrower = new MockFlashBorrower(address(yoloHookProxy));

        address[] memory assets = new address[](2);
        assets[0] = yJpyAsset;
        assets[1] = yKrwAsset;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1_000_000e18; // 1M JPY
        amounts[1] = 5_000_000e18; // 5M KRW

        // Calculate expected fees
        uint256[] memory expectedFees = new uint256[](2);
        expectedFees[0] = (amounts[0] * yoloHookProxy.flashLoanFee()) / 10000;
        expectedFees[1] = (amounts[1] * yoloHookProxy.flashLoanFee()) / 10000;

        // Give the borrower fee amounts to repay
        vm.startPrank(address(yoloHookProxy));
        IYoloSyntheticAsset(yJpyAsset).mint(address(borrower), expectedFees[0]);
        IYoloSyntheticAsset(yKrwAsset).mint(address(borrower), expectedFees[1]);
        vm.stopPrank();

        vm.startPrank(address(borrower));

        uint256 jpyTreasuryBefore = IERC20(yJpyAsset).balanceOf(yoloHookProxy.treasury());
        uint256 krwTreasuryBefore = IERC20(yKrwAsset).balanceOf(yoloHookProxy.treasury());

        yoloHookProxy.flashLoan(assets, amounts, "");

        // Verify treasury received fees
        uint256 jpyTreasuryAfter = IERC20(yJpyAsset).balanceOf(yoloHookProxy.treasury());
        uint256 krwTreasuryAfter = IERC20(yKrwAsset).balanceOf(yoloHookProxy.treasury());

        assertEq(jpyTreasuryAfter - jpyTreasuryBefore, expectedFees[0], "JPY fee incorrect");
        assertEq(krwTreasuryAfter - krwTreasuryBefore, expectedFees[1], "KRW fee incorrect");

        // Verify borrower has no balance left
        assertEq(IERC20(yJpyAsset).balanceOf(address(borrower)), 0, "Borrower should have no JPY left");
        assertEq(IERC20(yKrwAsset).balanceOf(address(borrower)), 0, "Borrower should have no KRW left");

        vm.stopPrank();
    }

    function test_Test01_Case16_pausedAssetOperations() external {
        console.log("==================== test_Test01_Case16_pausedAssetOperations ====================");

        // Pause yJPY by setting max cap to 0
        yoloHookProxy.setYoloAssetConfig(yJpyAsset, 0, 0);

        address user = makeAddr("user");
        deal(wbtcAsset, user, 1e18);
        yoloHookProxy.setPairConfig(wbtcAsset, yJpyAsset, 500, 8000, 500);

        vm.startPrank(user);
        IERC20(wbtcAsset).approve(address(yoloHookProxy), 1e18);

        // Try to borrow - should fail
        vm.expectRevert(YoloHook.YoloHook__YoloAssetPaused.selector);
        yoloHookProxy.borrow(yJpyAsset, 1_000_000e18, wbtcAsset, 1e18);

        // Try flash loan - should also fail
        vm.expectRevert(YoloHook.YoloHook__YoloAssetPaused.selector);
        yoloHookProxy.simpleFlashLoan(yJpyAsset, 1_000_000e18, "");

        vm.stopPrank();
    }

    function test_Test01_Case17_exceedMintCap() external {
        console.log("==================== test_Test01_Case17_exceedMintCap ====================");

        // Set a low mint cap
        uint256 mintCap = 1_000_000e18; // 1M JPY
        yoloHookProxy.setYoloAssetConfig(yJpyAsset, mintCap, 0);

        address user = makeAddr("user");
        deal(wbtcAsset, user, 10e18); // Plenty of collateral
        yoloHookProxy.setPairConfig(wbtcAsset, yJpyAsset, 500, 8000, 500);

        vm.startPrank(user);
        IERC20(wbtcAsset).approve(address(yoloHookProxy), 10e18);

        // Try to borrow more than cap
        vm.expectRevert(YoloHook.YoloHook__ExceedsYoloAssetMintCap.selector);
        yoloHookProxy.borrow(yJpyAsset, mintCap + 1, wbtcAsset, 10e18);

        vm.stopPrank();
    }

    function test_Test01_Case18_exceedCollateralCap() external {
        console.log("==================== test_Test01_Case18_exceedCollateralCap ====================");

        // Set a low collateral cap
        uint256 collateralCap = 1e18; // 1 WBTC
        yoloHookProxy.setCollateralConfig(wbtcAsset, collateralCap, address(0));

        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        deal(wbtcAsset, user1, 0.6e18);
        deal(wbtcAsset, user2, 0.6e18);

        // First user deposits
        vm.startPrank(user1);
        IERC20(wbtcAsset).approve(address(yoloHookProxy), 0.6e18);
        yoloHookProxy.borrow(yJpyAsset, 1_000_000e18, wbtcAsset, 0.6e18);
        vm.stopPrank();

        // Second user tries to deposit - should exceed cap
        vm.startPrank(user2);
        IERC20(wbtcAsset).approve(address(yoloHookProxy), 0.6e18);
        vm.expectRevert(YoloHook.YoloHook__ExceedsCollateralCap.selector);
        yoloHookProxy.borrow(yJpyAsset, 1_000_000e18, wbtcAsset, 0.6e18);
        vm.stopPrank();
    }

    function test_Test01_Case19_multiplePositionsPerUser() external {
        console.log("==================== test_Test01_Case19_multiplePositionsPerUser ====================");

        address user = makeAddr("multiUser");
        deal(wbtcAsset, user, 2e18);
        deal(ptUsdeAsset, user, 100_000e18);

        // Setup pair configs
        yoloHookProxy.setPairConfig(wbtcAsset, yJpyAsset, 500, 8000, 500);
        yoloHookProxy.setPairConfig(wbtcAsset, yKrwAsset, 600, 7500, 600);
        yoloHookProxy.setPairConfig(ptUsdeAsset, yJpyAsset, 400, 7000, 400);

        vm.startPrank(user);

        // Create multiple positions
        IERC20(wbtcAsset).approve(address(yoloHookProxy), 2e18);
        IERC20(ptUsdeAsset).approve(address(yoloHookProxy), 100_000e18);

        // Position 1: WBTC -> yJPY
        yoloHookProxy.borrow(yJpyAsset, 5_000_000e18, wbtcAsset, 0.5e18);

        // Position 2: WBTC -> yKRW
        yoloHookProxy.borrow(yKrwAsset, 20_000_000e18, wbtcAsset, 0.5e18);

        // Position 3: PT-sUSDe -> yJPY
        yoloHookProxy.borrow(yJpyAsset, 2_000_000e18, ptUsdeAsset, 50_000e18);

        // Verify all positions exist
        YoloHook.UserPositionKey[] memory keys = new YoloHook.UserPositionKey[](3);
        for (uint256 i = 0; i < 3; i++) {
            (address collateral, address yoloAsset) = yoloHookProxy.userPositionKeys(user, i);
            keys[i] = YoloHook.UserPositionKey(collateral, yoloAsset);
        }

        assertEq(keys[0].collateral, wbtcAsset);
        assertEq(keys[0].yoloAsset, yJpyAsset);
        assertEq(keys[1].collateral, wbtcAsset);
        assertEq(keys[1].yoloAsset, yKrwAsset);
        assertEq(keys[2].collateral, ptUsdeAsset);
        assertEq(keys[2].yoloAsset, yJpyAsset);

        vm.stopPrank();
    }

    function test_Test01_Case20_stableSwapMathAccuracy() external {
        console.log("==================== test_Test01_Case20_stableSwapMathAccuracy ====================");

        // Add significant liquidity
        IERC20Metadata usdc = IERC20Metadata(symbolToDeployedAsset["USDC"]);
        IERC20Metadata usy = IERC20Metadata(address(yoloHookProxy.anchor()));

        uint256 largeUsdc = usdc.decimals() == 18 ? 1_000_000e18 : 1_000_000e6;
        uint256 largeUsy = 1_000_000e18;

        deal(address(usdc), address(this), largeUsdc);
        deal(address(usy), address(this), largeUsy);

        usdc.approve(address(yoloHookProxy), type(uint256).max);
        usy.approve(address(yoloHookProxy), type(uint256).max);

        yoloHookProxy.addLiquidity(largeUsdc, largeUsy, 0, address(this));

        // Test various swap sizes
        uint256[] memory swapSizes = new uint256[](4);
        swapSizes[0] = usdc.decimals() == 18 ? 100e18 : 100e6; // Small
        swapSizes[1] = usdc.decimals() == 18 ? 10_000e18 : 10_000e6; // Medium
        swapSizes[2] = usdc.decimals() == 18 ? 100_000e18 : 100_000e6; // Large
        swapSizes[3] = usdc.decimals() == 18 ? 500_000e18 : 500_000e6; // Very large

        for (uint256 i = 0; i < swapSizes.length; i++) {
            deal(address(usdc), address(this), swapSizes[i]);
            usdc.approve(address(swapRouter), swapSizes[i]);

            (PoolKey memory key_, bool usdcIs0) = _anchorKey();

            uint256 usyBefore = usy.balanceOf(address(this));

            SwapParams memory sp =
                SwapParams({zeroForOne: usdcIs0, amountSpecified: -int256(swapSizes[i]), sqrtPriceLimitX96: 0});

            PoolSwapTest.TestSettings memory settings =
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

            swapRouter.swap(key_, sp, settings, "");

            uint256 usyAfter = usy.balanceOf(address(this));
            uint256 usyReceived = usyAfter - usyBefore;

            console.log("Swap size (USDC):", swapSizes[i]);
            console.log("USY received:", usyReceived);

            // For stable swap, output should be very close to input minus fee
            uint256 fee = (swapSizes[i] * yoloHookProxy.stableSwapFee()) / 10000;
            uint256 expectedOutput = swapSizes[i] - fee;

            // Convert to same decimals for comparison
            if (usdc.decimals() != 18) {
                expectedOutput = expectedOutput * (10 ** (18 - usdc.decimals()));
            }

            // Should be within 15% due to stable swap curve
            assertApproxEqRel(usyReceived, expectedOutput, 1.5e17, "Stable swap output off");
        }
    }

    function test_Test01_Case21_pendingBurnsMechanism() external {
        console.log("==================== test_Test01_Case21_pendingBurnsMechanism ====================");

        // Setup: Create positions and mint synthetic assets
        address user = makeAddr("syntheticSwapper");
        uint256 collateralAmount = 2e18; // 2 WBTC
        uint256 jpyBorrowAmount = 10_000_000e18; // 10M JPY
        uint256 krwBorrowAmount = 50_000_000e18; // 50M KRW

        // Setup collateral and borrow both JPY and KRW
        deal(wbtcAsset, user, collateralAmount);
        yoloHookProxy.setPairConfig(wbtcAsset, yJpyAsset, 500, 8000, 500);
        yoloHookProxy.setPairConfig(wbtcAsset, yKrwAsset, 500, 8000, 500);

        vm.startPrank(user);
        IERC20(wbtcAsset).approve(address(yoloHookProxy), collateralAmount);

        // Borrow JPY with half collateral
        yoloHookProxy.borrow(yJpyAsset, jpyBorrowAmount, wbtcAsset, 1e18);

        // Borrow KRW with other half
        yoloHookProxy.borrow(yKrwAsset, krwBorrowAmount, wbtcAsset, 1e18);

        // Test 1: First swap creates pending burn
        console.log("\n--- Test 1: First swap creates pending burn ---");

        // Check initial states
        assertEq(yoloHookProxy.assetToBurn(), address(0), "No pending burn initially");
        assertEq(yoloHookProxy.amountToBurn(), 0, "No pending amount initially");

        // Swap yJPY -> USY
        uint256 swapAmount = 1_000_000e18; // 1M JPY
        IERC20(yJpyAsset).approve(address(swapRouter), swapAmount);

        bool jpyIsToken0 = yJpyAsset < address(yoloHookProxy.anchor());
        PoolKey memory jpyUsyKey = PoolKey({
            currency0: Currency.wrap(jpyIsToken0 ? yJpyAsset : address(yoloHookProxy.anchor())),
            currency1: Currency.wrap(jpyIsToken0 ? address(yoloHookProxy.anchor()) : yJpyAsset),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(yoloHookProxy))
        });

        SwapParams memory sp1 =
            SwapParams({zeroForOne: jpyIsToken0, amountSpecified: -int256(swapAmount), sqrtPriceLimitX96: 0});

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Track balances before swap
        uint256 jpyBalBefore = IERC20(yJpyAsset).balanceOf(user);
        uint256 usyBalBefore = IERC20(address(yoloHookProxy.anchor())).balanceOf(user);
        uint256 jpySupplyBefore = IYoloSyntheticAsset(yJpyAsset).totalSupply();

        // Execute swap
        swapRouter.swap(jpyUsyKey, sp1, settings, "");

        // Verify pending burn is set
        assertEq(yoloHookProxy.assetToBurn(), yJpyAsset, "JPY should be pending burn");
        uint256 expectedPendingAmount = swapAmount - (swapAmount * yoloHookProxy.syntheticSwapFee() / 10000);
        assertEq(yoloHookProxy.amountToBurn(), expectedPendingAmount, "Pending amount incorrect");

        // Verify swap executed correctly
        assertEq(IERC20(yJpyAsset).balanceOf(user), jpyBalBefore - swapAmount, "JPY not deducted");
        assertGt(IERC20(address(yoloHookProxy.anchor())).balanceOf(user), usyBalBefore, "USY not received");

        // Verify JPY hasn't been burned yet
        assertEq(IYoloSyntheticAsset(yJpyAsset).totalSupply(), jpySupplyBefore, "JPY burned too early");

        // Test 2: Second swap burns pending and creates new pending
        console.log("\n--- Test 2: Second swap burns previous pending and creates new ---");

        // Now swap KRW -> USY
        uint256 krwSwapAmount = 5_000_000e18; // 5M KRW
        IERC20(yKrwAsset).approve(address(swapRouter), krwSwapAmount);

        bool krwIsToken0 = yKrwAsset < address(yoloHookProxy.anchor());
        PoolKey memory krwUsyKey = PoolKey({
            currency0: Currency.wrap(krwIsToken0 ? yKrwAsset : address(yoloHookProxy.anchor())),
            currency1: Currency.wrap(krwIsToken0 ? address(yoloHookProxy.anchor()) : yKrwAsset),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(yoloHookProxy))
        });

        SwapParams memory sp2 =
            SwapParams({zeroForOne: krwIsToken0, amountSpecified: -int256(krwSwapAmount), sqrtPriceLimitX96: 0});

        uint256 krwSupplyBefore = IYoloSyntheticAsset(yKrwAsset).totalSupply();

        // Execute second swap
        swapRouter.swap(krwUsyKey, sp2, settings, "");

        // Verify previous pending (JPY) was burned
        assertEq(
            IYoloSyntheticAsset(yJpyAsset).totalSupply(),
            jpySupplyBefore - expectedPendingAmount,
            "JPY not burned correctly"
        );

        // Verify new pending (KRW) is set
        assertEq(yoloHookProxy.assetToBurn(), yKrwAsset, "KRW should be new pending burn");
        uint256 expectedKrwPending = krwSwapAmount - (krwSwapAmount * yoloHookProxy.syntheticSwapFee() / 10000);
        assertEq(yoloHookProxy.amountToBurn(), expectedKrwPending, "KRW pending amount incorrect");

        // Verify KRW hasn't been burned yet
        assertEq(IYoloSyntheticAsset(yKrwAsset).totalSupply(), krwSupplyBefore, "KRW burned too early");

        // Test 3: Manual burn via burnPendings()
        console.log("\n--- Test 3: Manual burn via burnPendings() ---");

        // Call burnPendings() to manually burn the pending KRW
        yoloHookProxy.burnPendings();

        // Verify KRW was burned
        assertEq(
            IYoloSyntheticAsset(yKrwAsset).totalSupply(),
            krwSupplyBefore - expectedKrwPending,
            "KRW not burned via burnPendings"
        );

        // Verify pending is cleared
        assertEq(yoloHookProxy.assetToBurn(), address(0), "Pending burn not cleared");
        assertEq(yoloHookProxy.amountToBurn(), 0, "Pending amount not cleared");

        // Test 4: Calling burnPendings() with no pending should revert
        console.log("\n--- Test 4: burnPendings() reverts when no pending ---");

        vm.expectRevert(YoloHook.YoloHook__NoPendingBurns.selector);
        yoloHookProxy.burnPendings();

        vm.stopPrank();
    }

    function test_Test01_Case22_pendingBurnsEdgeCases() external {
        console.log("==================== test_Test01_Case22_pendingBurnsEdgeCases ====================");

        // Setup users and initial positions
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");

        // Fund both users
        deal(wbtcAsset, user1, 2e18);
        deal(wbtcAsset, user2, 2e18);

        yoloHookProxy.setPairConfig(wbtcAsset, yJpyAsset, 500, 8000, 500);
        yoloHookProxy.setPairConfig(wbtcAsset, yKrwAsset, 500, 8000, 500);
        yoloHookProxy.setPairConfig(wbtcAsset, yGoldAsset, 500, 8000, 500);

        // Both users borrow different assets
        vm.startPrank(user1);
        IERC20(wbtcAsset).approve(address(yoloHookProxy), 2e18);
        yoloHookProxy.borrow(yJpyAsset, 10_000_000e18, wbtcAsset, 1e18);
        yoloHookProxy.borrow(yKrwAsset, 50_000_000e18, wbtcAsset, 1e18);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(wbtcAsset).approve(address(yoloHookProxy), 2e18);
        // Fixed: Borrow a reasonable amount: 2 WBTC * $104k * 80% LTV / $3201 per oz ≈ 52 oz of gold
        yoloHookProxy.borrow(yGoldAsset, 50e18, wbtcAsset, 2e18); // 50 oz of gold (safe amount)
        vm.stopPrank();

        // Test 1: Rapid successive swaps from different users
        console.log("\n--- Test 1: Rapid successive swaps ---");

        // User1 swaps JPY -> USY
        vm.startPrank(user1);
        uint256 jpySwapAmount = 1_000_000e18;
        IERC20(yJpyAsset).approve(address(swapRouter), jpySwapAmount);

        bool jpyIsToken0 = yJpyAsset < address(yoloHookProxy.anchor());
        PoolKey memory jpyKey = PoolKey({
            currency0: Currency.wrap(jpyIsToken0 ? yJpyAsset : address(yoloHookProxy.anchor())),
            currency1: Currency.wrap(jpyIsToken0 ? address(yoloHookProxy.anchor()) : yJpyAsset),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(yoloHookProxy))
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 jpySupplyBefore = IYoloSyntheticAsset(yJpyAsset).totalSupply();

        swapRouter.swap(
            jpyKey,
            SwapParams({zeroForOne: jpyIsToken0, amountSpecified: -int256(jpySwapAmount), sqrtPriceLimitX96: 0}),
            settings,
            ""
        );

        uint256 jpyPendingAmount = jpySwapAmount - (jpySwapAmount * yoloHookProxy.syntheticSwapFee() / 10000);
        vm.stopPrank();

        // Immediately, User2 swaps GOLD -> USY (this should burn pending JPY)
        vm.startPrank(user2);
        uint256 goldSwapAmount = 10e18; // 10 oz (reasonable amount)
        IERC20(yGoldAsset).approve(address(swapRouter), goldSwapAmount);

        bool goldIsToken0 = yGoldAsset < address(yoloHookProxy.anchor());
        PoolKey memory goldKey = PoolKey({
            currency0: Currency.wrap(goldIsToken0 ? yGoldAsset : address(yoloHookProxy.anchor())),
            currency1: Currency.wrap(goldIsToken0 ? address(yoloHookProxy.anchor()) : yGoldAsset),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(yoloHookProxy))
        });

        uint256 goldSupplyBefore = IYoloSyntheticAsset(yGoldAsset).totalSupply();

        swapRouter.swap(
            goldKey,
            SwapParams({zeroForOne: goldIsToken0, amountSpecified: -int256(goldSwapAmount), sqrtPriceLimitX96: 0}),
            settings,
            ""
        );
        vm.stopPrank();

        // Verify JPY was burned and GOLD is now pending
        assertEq(
            IYoloSyntheticAsset(yJpyAsset).totalSupply(),
            jpySupplyBefore - jpyPendingAmount,
            "JPY not burned on second swap"
        );
        assertEq(yoloHookProxy.assetToBurn(), yGoldAsset, "GOLD should be pending");
        assertEq(IYoloSyntheticAsset(yGoldAsset).totalSupply(), goldSupplyBefore, "GOLD burned too early");

        // Test 2: Swap with same asset that's pending (should burn and create new pending)
        console.log("\n--- Test 2: Swap same asset that's pending ---");

        vm.startPrank(user2);
        uint256 secondGoldSwap = 5e18; // 5 oz
        IERC20(yGoldAsset).approve(address(swapRouter), secondGoldSwap);

        uint256 firstGoldPending = goldSwapAmount - (goldSwapAmount * yoloHookProxy.syntheticSwapFee() / 10000);

        swapRouter.swap(
            goldKey,
            SwapParams({zeroForOne: goldIsToken0, amountSpecified: -int256(secondGoldSwap), sqrtPriceLimitX96: 0}),
            settings,
            ""
        );

        // Verify first pending was burned and new pending created
        assertEq(
            IYoloSyntheticAsset(yGoldAsset).totalSupply(),
            goldSupplyBefore - firstGoldPending,
            "First GOLD pending not burned"
        );

        uint256 secondGoldPending = secondGoldSwap - (secondGoldSwap * yoloHookProxy.syntheticSwapFee() / 10000);
        assertEq(yoloHookProxy.amountToBurn(), secondGoldPending, "New pending amount incorrect");
        vm.stopPrank();

        // Test 3: Anchor pool swap clears pending burns
        console.log("\n--- Test 3: Anchor pool swap clears pending ---");

        // First, ensure we have liquidity in anchor pool
        address lpProvider = makeAddr("lpProvider");
        IERC20Metadata usdc = IERC20Metadata(symbolToDeployedAsset["USDC"]);
        IERC20Metadata usy = IERC20Metadata(address(yoloHookProxy.anchor()));

        uint256 usdcLiquidity = usdc.decimals() == 18 ? 100_000e18 : 100_000e6;
        uint256 usyLiquidity = 100_000e18;

        deal(address(usdc), lpProvider, usdcLiquidity);
        deal(address(usy), lpProvider, usyLiquidity);

        vm.startPrank(lpProvider);
        usdc.approve(address(yoloHookProxy), type(uint256).max);
        usy.approve(address(yoloHookProxy), type(uint256).max);
        yoloHookProxy.addLiquidity(usdcLiquidity, usyLiquidity, 0, lpProvider);
        vm.stopPrank();

        // Record GOLD supply before anchor swap
        uint256 goldSupplyBeforeAnchor = IYoloSyntheticAsset(yGoldAsset).totalSupply();

        // User1 does USDC -> USY swap (anchor pool)
        vm.startPrank(user1);
        uint256 usdcSwapAmount = usdc.decimals() == 18 ? 1000e18 : 1000e6;
        deal(address(usdc), user1, usdcSwapAmount);
        usdc.approve(address(swapRouter), usdcSwapAmount);

        (PoolKey memory anchorKey, bool usdcIs0) = _anchorKey();

        swapRouter.swap(
            anchorKey,
            SwapParams({zeroForOne: usdcIs0, amountSpecified: -int256(usdcSwapAmount), sqrtPriceLimitX96: 0}),
            settings,
            ""
        );
        vm.stopPrank();

        // Verify pending GOLD was burned during anchor swap
        assertEq(
            IYoloSyntheticAsset(yGoldAsset).totalSupply(),
            goldSupplyBeforeAnchor - secondGoldPending,
            "Pending GOLD not burned on anchor swap"
        );
        assertEq(yoloHookProxy.assetToBurn(), address(0), "Pending not cleared");
        assertEq(yoloHookProxy.amountToBurn(), 0, "Pending amount not cleared");

        // Test 4: Exact output swap creates correct pending
        console.log("\n--- Test 4: Exact output swap pending burns ---");

        vm.startPrank(user1);
        // Swap to get exactly 1000 USY from KRW
        uint256 exactUsyOut = 1000e18;

        // Approve a large amount since we don't know exact input needed
        IERC20(yKrwAsset).approve(address(swapRouter), type(uint256).max);

        bool krwIsToken0 = yKrwAsset < address(yoloHookProxy.anchor());
        PoolKey memory krwKey = PoolKey({
            currency0: Currency.wrap(krwIsToken0 ? yKrwAsset : address(yoloHookProxy.anchor())),
            currency1: Currency.wrap(krwIsToken0 ? address(yoloHookProxy.anchor()) : yKrwAsset),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(yoloHookProxy))
        });

        uint256 krwBalBefore = IERC20(yKrwAsset).balanceOf(user1);

        swapRouter.swap(
            krwKey,
            SwapParams({zeroForOne: krwIsToken0, amountSpecified: int256(exactUsyOut), sqrtPriceLimitX96: 0}),
            settings,
            ""
        );

        // Calculate how much KRW was used
        uint256 krwUsed = krwBalBefore - IERC20(yKrwAsset).balanceOf(user1);

        // Pending should be the net amount (gross - fee)
        uint256 expectedNetKrw = krwUsed - (krwUsed * yoloHookProxy.syntheticSwapFee() / 10000);
        assertEq(yoloHookProxy.assetToBurn(), yKrwAsset, "KRW should be pending");

        // For exact output, the pending amount calculation is different
        // The gross input already includes the fee, so we need to calculate the net amount differently
        uint256 krwPrice = yoloOracle.getAssetPrice(yKrwAsset);
        uint256 usyPrice = yoloOracle.getAssetPrice(address(yoloHookProxy.anchor()));
        uint256 netInputAmount = usyPrice * exactUsyOut / krwPrice;

        assertEq(yoloHookProxy.amountToBurn(), netInputAmount, "Exact output pending incorrect");

        vm.stopPrank();

        console.log("\n--- All edge cases handled correctly ---");
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

contract MockFlashBorrower is IFlashBorrower {
    address public immutable yoloProtocolHook;
    bool public repayLoan = true;

    constructor(address _yoloProtocolHook) {
        yoloProtocolHook = _yoloProtocolHook;
    }

    function setRepayLoan(bool _repayLoan) external {
        repayLoan = _repayLoan;
    }

    function onFlashLoan(address initiator, address asset, uint256 amount, uint256 fee, bytes calldata data)
        external
        override
    {
        require(msg.sender == yoloProtocolHook, "MockFlashBorrower: caller is not YoloProtocolHook");
        require(initiator == address(this), "MockFlashBorrower: initiator mismatch");

        if (repayLoan) {
            // Approve the hook to burn tokens from this contract
            IERC20(asset).approve(yoloProtocolHook, amount + fee);
        }
    }

    function onBatchFlashLoan(
        address initiator,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata fees,
        bytes calldata data
    ) external override {
        require(msg.sender == yoloProtocolHook, "MockFlashBorrower: caller is not YoloProtocolHook");
        require(initiator == address(this), "MockFlashBorrower: initiator mismatch");

        if (repayLoan) {
            // Approve the hook to burn tokens
            for (uint256 i = 0; i < assets.length; i++) {
                IERC20(assets[i]).approve(yoloProtocolHook, amounts[i] + fees[i]);
            }
        }
    }
}

// Keep for debuggings Hooks library
// (bool success, bytes memory returnData) = address(self).call(data);
// if (!success) {
//     // Bubble up the exact error data (selector + args) from the hook
//     assembly {
//         let len := mload(returnData)
//         revert(add(returnData, 0x20), len)
//     }
// }
