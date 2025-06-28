// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/*---------- IMPORT FORGE SCRIPTS ----------*/
import {Script, console} from "forge-std/Script.sol";

/*---------- IMPORT CONTRACTS ----------*/
import {MockYoloCrossChainTesterHook} from "@yolo/contracts/mocks/MockYoloCrossChainTesterHook.sol";
import {YoloCCIPBridge} from "@yolo/contracts/cross-chain/YoloCCIPBridge.sol";

/**
 * @title   Script03B_DeployArbitrumCCIPTesting
 * @author  0xyolodev.eth
 * @notice  Deploy contracts on Arbitrum Sepolia
 */
contract Script03B_DeployArbitrumCCIPTesting is Script {
    
    // ***************** //
    // *** CONSTANTS *** //
    // ***************** //
    
    /*----- Arbitrum Sepolia Configuration -----*/
    uint64 constant CHAIN_SELECTOR = 3478487238524512106;
    address constant CCIP_ROUTER = 0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165;
    
    /*----- Test Configuration -----*/
    string constant ASSET_NAME = "Test Yolo USD";
    string constant ASSET_SYMBOL = "TUSY";
    uint8 constant ASSET_DECIMALS = 18;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== DEPLOYING ON ARBITRUM SEPOLIA ===");
        console.log("Deployer address:", deployer);
        console.log("Chain Selector:", CHAIN_SELECTOR);
        console.log("CCIP Router:", CCIP_ROUTER);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy Mock Hook
        MockYoloCrossChainTesterHook hook = new MockYoloCrossChainTesterHook();
        console.log("ARBITRUM_HOOK:", address(hook));
        
        // Deploy CCIP Bridge
        YoloCCIPBridge bridge = new YoloCCIPBridge(
            CCIP_ROUTER,
            address(hook),
            CHAIN_SELECTOR
        );
        console.log("ARBITRUM_BRIDGE:", address(bridge));
        
        // Create test asset
        address asset = hook.createNewYoloAsset(ASSET_NAME, ASSET_SYMBOL, ASSET_DECIMALS);
        console.log("ARBITRUM_ASSET:", asset);
        
        // Register bridge
        hook.registerBridge(address(bridge));
        console.log("Bridge registered with Hook");
        
        vm.stopBroadcast();
        
        console.log("");
        console.log("=== ARBITRUM DEPLOYMENT COMPLETE ===");
        console.log("Copy these addresses for next scripts:");
        console.log("ARBITRUM_HOOK=", address(hook));
        console.log("ARBITRUM_BRIDGE=", address(bridge));
        console.log("ARBITRUM_ASSET=", asset);
        console.log("ARBITRUM_CHAIN_SELECTOR=", CHAIN_SELECTOR);
    }
}