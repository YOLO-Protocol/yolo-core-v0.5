// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "./base/Base01_DeployUniswapV4Pool.t.sol";
import "./base/Base02_DeployMockAssetsAndOracles.t.sol";
/*---------- IMPORT CONTRACTS ----------*/
import {PublicTransparentUpgradeableProxy} from "@yolo/contracts/proxy/PublicTransparentUpgradeableProxy.sol";
import {YoloHook} from "@yolo/contracts/core/YoloHook.sol";
import {YoloOracle} from "@yolo/contracts/core/YoloOracle.sol";
/*---------- IMPORT LIBRARIES & TYPES ----------*/
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

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

        // Initialize USY Balance
        IERC20Metadata usy = IERC20Metadata(address(yoloHookProxy.anchor()));
        assertNotEq(address(usy), address(0), "Test01: USY anchor address is zero");
        deal(address(usy), address(this), 100_000_000e18); // 100_000 USY

        // Approve Hook to pull tokens
        usdc.approve(address(yoloHookProxy), type(uint256).max);
        usy.approve(address(yoloHookProxy), type(uint256).max);

        // Initial balances
        uint256 balUsdcBefore = usdc.balanceOf(address(this));
        uint256 balUsyBefore = usy.balanceOf(address(this));
        console.log("User USDC Before:", balUsdcBefore);
        console.log("User USY Before:", balUsyBefore);

        // Construct the PoolKey for the anchor pool

        // // A. Try to add liquidity to the anchor pool via PoolManager
        // // vm.expectRevert("Test01: Cannot add liquidity on PoolManager");
        // manager.addLiquidity(
        //     symbolToDeployedAsset["USDC"],
        //     symbolToDeployedAsset["USY"],
        //     100_000e6, // 100_000 USDC
        //     100_000e18 // 100_000 USY
        // );
    }

    // function test_Test01_Case02_addAndRemoveLiquidityOnHook() external {
    //     console.log("==================== test_Test01_Case02_addAndRemoveLiquidityOnHook ====================");

    //     // Initialize USDC Balance
    //     IERC20Metadata usdc = IERC20Metadata(symbolToDeployedAsset["USDC"]);
    //     console.log("User USDC Balance Before:", usdc.balanceOf(address(this))); // 100_000_000 USDC;

    //     // Initialize USY Balance
    //     IERC20Metadata usy = IERC20Metadata(address(yoloHookProxy.anchor()));
    //     assertNotEq(usy, address(0), "Test01: USY anchor address is zero");
    //     deal(usy, address(this), 100_000_000e18); // 100_000 USY
    //     console.log("User USY Balance Before:", IERC20Metadata(usy).balanceOf(address(this)));

    //     // A. Add liquidity to the anchor pool
    // }

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
}
