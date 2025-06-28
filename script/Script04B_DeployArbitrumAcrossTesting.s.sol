// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/*---------- IMPORT FORGE SCRIPTS ----------*/
import {Script, console} from "forge-std/Script.sol";

/*---------- IMPORT CONTRACTS ----------*/
import {MockYoloCrossChainTesterHook} from "@yolo/contracts/mocks/MockYoloCrossChainTesterHook.sol";
import {YoloAccrossBridge} from "@yolo/contracts/cross-chain/YoloAcrossBridge.sol";

/**
 * @title   Script04B_DeployArbitrumAcrossTesting
 * @author  0xyolodev.eth
 * @notice  Deploy contracts on Arbitrum Sepolia for Across Protocol testing
 */
contract Script04B_DeployArbitrumAcrossTesting is Script {
    
    // ***************** //
    // *** CONSTANTS *** //
    // ***************** //
    
    /*----- Arbitrum Sepolia Configuration -----*/
    uint256 constant CHAIN_ID = 421614;
    address constant SPOKE_POOL = 0x7E63A5f1a8F0B4d0934B2f2327DAED3F6bb2ee75;
    
    /*----- Test Configuration -----*/
    string constant ASSET_NAME = "Test Yolo USD";
    string constant ASSET_SYMBOL = "TUSY";
    uint8 constant ASSET_DECIMALS = 18;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== DEPLOYING ON ARBITRUM SEPOLIA (ACROSS) ===");
        console.log("Deployer address:", deployer);
        console.log("Chain ID:", CHAIN_ID);
        console.log("Across SpokePool:", SPOKE_POOL);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy Mock Hook
        MockYoloCrossChainTesterHook hook = new MockYoloCrossChainTesterHook();
        console.log("ARBITRUM_HOOK:", address(hook));
        
        // Deploy Across Bridge
        YoloAccrossBridge bridge = new YoloAccrossBridge(
            address(hook),
            SPOKE_POOL,
            deployer
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
        console.log("ARBITRUM_CHAIN_ID=", CHAIN_ID);
    }
}