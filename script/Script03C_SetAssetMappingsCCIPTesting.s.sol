// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/*---------- IMPORT FORGE SCRIPTS ----------*/
import {Script, console} from "forge-std/Script.sol";

/*---------- IMPORT CONTRACTS ----------*/
import {YoloCCIPBridge} from "@yolo/contracts/cross-chain/YoloCCIPBridge.sol";

/**
 * @title   Script03C_SetAssetMappingsCCIPTesting
 * @author  0xyolodev.eth
 * @notice  Set asset mappings for cross-chain transfers
 * @dev     You need to update the addresses below from the output of Script03A and Script03B
 */
contract Script03C_SetAssetMappingsCCIPTesting is Script {
    // ***************** //
    // *** CONSTANTS *** //
    // ***************** //

    /*----- Chain Selectors -----*/
    uint64 constant SEPOLIA_CHAIN_SELECTOR = 16015286601757825753;
    uint64 constant ARBITRUM_CHAIN_SELECTOR = 3478487238524512106;

    /*----- UPDATE THESE ADDRESSES FROM SCRIPT03A OUTPUT -----*/
    address constant SEPOLIA_BRIDGE = 0x03692eD42FB0e2F618d22082C8a13A9E9db99ed2; // UPDATE THIS
    address constant SEPOLIA_ASSET = 0x01d134cd8C6c773C1D0179CE0695ec70F1eB1240; // UPDATE THIS

    /*----- UPDATE THESE ADDRESSES FROM SCRIPT03B OUTPUT -----*/
    address constant ARBITRUM_BRIDGE = 0x6d5Cc7C72Af979cb4d69404386A4F15f5488d0BB; // UPDATE THIS
    address constant ARBITRUM_ASSET = 0xbb5c7944a0DDfc66e177ebF552471347f70cEfB2; // UPDATE THIS

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("=== SETTING UP CROSS-CHAIN ASSET MAPPINGS ===");
        console.log("Sepolia Bridge:", SEPOLIA_BRIDGE);
        console.log("Arbitrum Bridge:", ARBITRUM_BRIDGE);
        console.log("Sepolia Asset:", SEPOLIA_ASSET);
        console.log("Arbitrum Asset:", ARBITRUM_ASSET);
        console.log("");

        // Get RPC URLs
        string memory sepoliaRpc = vm.envString("SEPOLIA_RPC");
        string memory arbitrumRpc = vm.envString("ARBITRUM_SEPOLIA_RPC");

        // Setup Sepolia -> Arbitrum mapping
        console.log("1. Setting up Sepolia -> Arbitrum mapping...");
        vm.createSelectFork(sepoliaRpc);
        vm.startBroadcast(deployerPrivateKey);

        YoloCCIPBridge sepoliaBridge = YoloCCIPBridge(payable(SEPOLIA_BRIDGE));
        sepoliaBridge.setSupportedChain(ARBITRUM_CHAIN_SELECTOR, true);
        sepoliaBridge.setAssetMapping(ARBITRUM_CHAIN_SELECTOR, SEPOLIA_ASSET, ARBITRUM_ASSET);

        vm.stopBroadcast();
        console.log("  Sepolia -> Arbitrum mapping complete!");

        // Setup Arbitrum -> Sepolia mapping
        console.log("2. Setting up Arbitrum -> Sepolia mapping...");
        vm.createSelectFork(arbitrumRpc);
        vm.startBroadcast(deployerPrivateKey);

        YoloCCIPBridge arbitrumBridge = YoloCCIPBridge(payable(ARBITRUM_BRIDGE));
        arbitrumBridge.setSupportedChain(SEPOLIA_CHAIN_SELECTOR, true);
        arbitrumBridge.setAssetMapping(SEPOLIA_CHAIN_SELECTOR, ARBITRUM_ASSET, SEPOLIA_ASSET);

        vm.stopBroadcast();
        console.log("  Arbitrum -> Sepolia mapping complete!");

        console.log("");
        console.log("=== ASSET MAPPINGS SETUP COMPLETE ===");
        console.log("Ready for cross-chain transfers!");
    }
}
