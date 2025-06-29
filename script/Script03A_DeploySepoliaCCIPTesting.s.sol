// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

//   Usage:
//   1. Run Script03A with --rpc-url $SEPOLIA_RPC --skip-simulation --broadcast
//   2. Run Script03B with --rpc-url $ARBITRUM_RPC --skip-simulation --broadcast
//   3. Update addresses in Script03C and Script03D from the outputs
//   4. Run Script03C with --skip-simulation --broadcast
//   5. Run Script03D with --skip-simulation --broadcast

/*---------- IMPORT FORGE SCRIPTS ----------*/
import {Script, console} from "forge-std/Script.sol";

/*---------- IMPORT CONTRACTS ----------*/
import {MockYoloCrossChainTesterHook} from "@yolo/contracts/mocks/MockYoloCrossChainTesterHook.sol";
import {YoloCCIPBridge} from "@yolo/contracts/cross-chain/YoloCCIPBridge.sol";

/**
 * @title   Script03A_DeploySepoliaCCIPTesting
 * @author  0xyolodev.eth
 * @notice  Deploy contracts on Ethereum Sepolia
 */
contract Script03A_DeploySepoliaCCIPTesting is Script {
    // ***************** //
    // *** CONSTANTS *** //
    // ***************** //

    /*----- Ethereum Sepolia Configuration -----*/
    uint64 constant CHAIN_SELECTOR = 16015286601757825753;
    address constant CCIP_ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;

    /*----- Test Configuration -----*/
    uint256 constant TEST_AMOUNT = 1000 * 1e18;
    string constant ASSET_NAME = "Test Yolo USD";
    string constant ASSET_SYMBOL = "TUSY";
    uint8 constant ASSET_DECIMALS = 18;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== DEPLOYING ON ETHEREUM SEPOLIA ===");
        console.log("Deployer address:", deployer);
        console.log("Chain Selector:", CHAIN_SELECTOR);
        console.log("CCIP Router:", CCIP_ROUTER);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Mock Hook
        MockYoloCrossChainTesterHook hook = new MockYoloCrossChainTesterHook();
        console.log("SEPOLIA_HOOK:", address(hook));

        // Deploy CCIP Bridge
        YoloCCIPBridge bridge = new YoloCCIPBridge(CCIP_ROUTER, address(hook), CHAIN_SELECTOR);
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
        console.log("SEPOLIA_CHAIN_SELECTOR=", CHAIN_SELECTOR);
    }
}
