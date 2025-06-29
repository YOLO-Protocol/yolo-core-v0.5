// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

//   Usage:
//   1. Run Script04A with --rpc-url $SEPOLIA_RPC --skip-simulation --broadcast
//   2. Run Script04B with --rpc-url $ARBITRUM_SEPOLIA_RPC --skip-simulation --broadcast
//   3. Update addresses in Script04C and Script04D from the outputs
//   4. Run Script04C with --skip-simulation --broadcast
//   5. Run Script04D with --skip-simulation --broadcast

//   The scripts expect SEPOLIA_RPC and ARBITRUM_SEPOLIA_RPC environment variables.

/*---------- IMPORT FORGE SCRIPTS ----------*/
import {Script, console} from "forge-std/Script.sol";

/*---------- IMPORT CONTRACTS ----------*/
import {MockYoloCrossChainTesterHook} from "@yolo/contracts/mocks/MockYoloCrossChainTesterHook.sol";
import {YoloAccrossBridge} from "@yolo/contracts/cross-chain/YoloAcrossBridge.sol";

/**
 * @title   Script04A_DeploySepoliaAcrossTesting
 * @author  0xyolodev.eth
 * @notice  Deploy contracts on Ethereum Sepolia for Across Protocol testing
 */
contract Script04A_DeploySepoliaAcrossTesting is Script {
    // ***************** //
    // *** CONSTANTS *** //
    // ***************** //

    /*----- Ethereum Sepolia Configuration -----*/
    uint256 constant CHAIN_ID = 11155111;
    address constant SPOKE_POOL = 0x5ef6C01E11889d86803e0B23e3cB3F9E9d97B662;

    /*----- Test Configuration -----*/
    uint256 constant TEST_AMOUNT = 1000 * 1e18;
    string constant ASSET_NAME = "Test Yolo USD";
    string constant ASSET_SYMBOL = "TUSY";
    uint8 constant ASSET_DECIMALS = 18;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== DEPLOYING ON ETHEREUM SEPOLIA (ACROSS) ===");
        console.log("Deployer address:", deployer);
        console.log("Chain ID:", CHAIN_ID);
        console.log("Across SpokePool:", SPOKE_POOL);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Mock Hook
        MockYoloCrossChainTesterHook hook = new MockYoloCrossChainTesterHook();
        console.log("SEPOLIA_HOOK:", address(hook));

        // Deploy Across Bridge
        YoloAccrossBridge bridge = new YoloAccrossBridge(address(hook), SPOKE_POOL, deployer);
        console.log("SEPOLIA_BRIDGE:", address(bridge));

        // Create test asset
        address asset = hook.createNewYoloAsset(ASSET_NAME, ASSET_SYMBOL, ASSET_DECIMALS);
        console.log("SEPOLIA_ASSET:", asset);

        // Register bridge
        hook.registerBridge(address(bridge));
        console.log("Bridge registered with Hook");

        // Mint test tokens
        hook.mintForTesting(asset, TEST_AMOUNT, deployer);
        console.log("Test tokens minted:", TEST_AMOUNT);

        vm.stopBroadcast();

        console.log("");
        console.log("=== SEPOLIA DEPLOYMENT COMPLETE ===");
        console.log("Copy these addresses for next scripts:");
        console.log("SEPOLIA_HOOK=", address(hook));
        console.log("SEPOLIA_BRIDGE=", address(bridge));
        console.log("SEPOLIA_ASSET=", asset);
        console.log("SEPOLIA_CHAIN_ID=", CHAIN_ID);
    }
}
