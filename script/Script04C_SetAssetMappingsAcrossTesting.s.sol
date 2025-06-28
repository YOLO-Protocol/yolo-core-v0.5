// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/*---------- IMPORT FORGE SCRIPTS ----------*/
import {Script, console} from "forge-std/Script.sol";

/*---------- IMPORT CONTRACTS ----------*/
import {YoloAccrossBridge} from "@yolo/contracts/cross-chain/YoloAcrossBridge.sol";

/**
 * @title   Script04C_SetAssetMappingsAcrossTesting
 * @author  0xyolodev.eth
 * @notice  Set asset mappings for cross-chain transfers using Across Protocol
 * @dev     You need to update the addresses below from the output of Script04A and Script04B
 */
contract Script04C_SetAssetMappingsAcrossTesting is Script {
    
    // ***************** //
    // *** CONSTANTS *** //
    // ***************** //
    
    /*----- Chain IDs -----*/
    uint256 constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 constant ARBITRUM_CHAIN_ID = 421614;
    
    /*----- UPDATE THESE ADDRESSES FROM SCRIPT04A OUTPUT -----*/
    address constant SEPOLIA_BRIDGE = 0x1aCB05dF81618fE007C0456E757Db0d37BF2542a; // FROM SCRIPT04A
    address constant SEPOLIA_ASSET = 0x7b211372beb7Cc1b2749Da654B3109378458d070;  // FROM SCRIPT04A
    
    /*----- UPDATE THESE ADDRESSES FROM SCRIPT04B OUTPUT -----*/
    address constant ARBITRUM_BRIDGE = 0x44BaF498b01Ca6c54D0624030a8F738925289CfE; // FROM SCRIPT04B
    address constant ARBITRUM_ASSET = 0x872f1725Df988025cd562ee3A08ba4b3d14E08be;  // FROM SCRIPT04B

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== SETTING UP ACROSS CROSS-CHAIN ASSET MAPPINGS ===");
        console.log("Sepolia Bridge:", SEPOLIA_BRIDGE);
        console.log("Arbitrum Bridge:", ARBITRUM_BRIDGE);
        console.log("Sepolia Asset:", SEPOLIA_ASSET);
        console.log("Arbitrum Asset:", ARBITRUM_ASSET);
        console.log("");
        
        // Get RPC URLs
        string memory sepoliaRpc = vm.envString("SEPOLIA_RPC");
        string memory arbitrumRpc = vm.envString("ARBITRUM_SEPOLIA_RPC");
        
        // Setup Sepolia -> Arbitrum mapping
        console.log("1. Setting up Sepolia -> Arbitrum configuration...");
        vm.createSelectFork(sepoliaRpc);
        vm.startBroadcast(deployerPrivateKey);
        
        YoloAccrossBridge sepoliaBridge = YoloAccrossBridge(SEPOLIA_BRIDGE);
        sepoliaBridge.setSupportedChain(ARBITRUM_CHAIN_ID, true);
        sepoliaBridge.setDestinationBridgeAddress(ARBITRUM_CHAIN_ID, ARBITRUM_BRIDGE);
        sepoliaBridge.setAssetMapping(ARBITRUM_CHAIN_ID, SEPOLIA_ASSET, ARBITRUM_ASSET);
        
        vm.stopBroadcast();
        console.log("  Sepolia -> Arbitrum configuration complete!");
        
        // Setup Arbitrum -> Sepolia mapping
        console.log("2. Setting up Arbitrum -> Sepolia configuration...");
        vm.createSelectFork(arbitrumRpc);
        vm.startBroadcast(deployerPrivateKey);
        
        YoloAccrossBridge arbitrumBridge = YoloAccrossBridge(ARBITRUM_BRIDGE);
        arbitrumBridge.setSupportedChain(SEPOLIA_CHAIN_ID, true);
        arbitrumBridge.setDestinationBridgeAddress(SEPOLIA_CHAIN_ID, SEPOLIA_BRIDGE);
        arbitrumBridge.setAssetMapping(SEPOLIA_CHAIN_ID, ARBITRUM_ASSET, SEPOLIA_ASSET);
        
        vm.stopBroadcast();
        console.log("  Arbitrum -> Sepolia configuration complete!");
        
        console.log("");
        console.log("=== ACROSS ASSET MAPPINGS SETUP COMPLETE ===");
        console.log("Ready for cross-chain transfers via Across Protocol!");
    }
}