// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/*---------- IMPORT FORGE SCRIPTS ----------*/
import {Script, console} from "forge-std/Script.sol";

/*---------- IMPORT CONTRACTS ----------*/
import {YoloCCIPBridge} from "@yolo/contracts/cross-chain/YoloCCIPBridge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Successfully tested cross-chain transfer from Sepolia to Arbitrum using CCIP.
// https://ccip.chain.link/#/side-drawer/msg/0xb89da0fb51eb39cce0b2db41c2e1c61abdcd54539efce3e4c79645919a043f69

/**
 * @title   Script03D_TestCrossChainTransferCCIPTesting
 * @author  0xyolodev.eth
 * @notice  Test cross-chain transfer from Sepolia to Arbitrum, wait, then check results
 * @dev     You need to update the addresses below from the output of Script03A and Script03B
 */
contract Script03D_TestCrossChainTransferCCIPTesting is Script {
    
    // ***************** //
    // *** CONSTANTS *** //
    // ***************** //
    
    /*----- Chain Selectors -----*/
    uint64 constant SEPOLIA_CHAIN_SELECTOR = 16015286601757825753;
    uint64 constant ARBITRUM_CHAIN_SELECTOR = 3478487238524512106;
    
    /*----- UPDATE THESE ADDRESSES FROM SCRIPT03A OUTPUT -----*/
    address constant SEPOLIA_BRIDGE = 0x03692eD42FB0e2F618d22082C8a13A9E9db99ed2; // UPDATE THIS
    address constant SEPOLIA_ASSET = 0x01d134cd8C6c773C1D0179CE0695ec70F1eB1240;  // UPDATE THIS
    
    /*----- UPDATE THESE ADDRESSES FROM SCRIPT03B OUTPUT -----*/
    address constant ARBITRUM_BRIDGE = 0x6d5Cc7C72Af979cb4d69404386A4F15f5488d0BB; // UPDATE THIS
    address constant ARBITRUM_ASSET = 0xbb5c7944a0DDfc66e177ebF552471347f70cEfB2;  // UPDATE THIS
    
    /*----- Test Configuration -----*/
    uint256 constant TRANSFER_AMOUNT = 100 * 1e18; // 100 tokens

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== TESTING CROSS-CHAIN TRANSFER ===");
        console.log("Transfer Amount:", TRANSFER_AMOUNT);
        console.log("From: Sepolia ->", "To: Arbitrum");
        console.log("");
        
        // Get RPC URLs
        string memory sepoliaRpc = vm.envString("SEPOLIA_RPC");
        string memory arbitrumRpc = vm.envString("ARBITRUM_SEPOLIA_RPC");
        
        // Check initial balances
        console.log("1. Checking initial balances...");
        
        // Check Sepolia balance
        vm.createSelectFork(sepoliaRpc);
        uint256 sepoliaBalanceBefore = IERC20(SEPOLIA_ASSET).balanceOf(deployer);
        console.log("  Sepolia balance before:", sepoliaBalanceBefore);
        
        // Check Arbitrum balance
        vm.createSelectFork(arbitrumRpc);
        uint256 arbitrumBalanceBefore = IERC20(ARBITRUM_ASSET).balanceOf(deployer);
        console.log("  Arbitrum balance before:", arbitrumBalanceBefore);
        
        // Initiate cross-chain transfer from Sepolia
        console.log("2. Initiating cross-chain transfer...");
        vm.createSelectFork(sepoliaRpc);
        
        YoloCCIPBridge sepoliaBridge = YoloCCIPBridge(payable(SEPOLIA_BRIDGE));
        
        // Get required fee
        uint256 fee = sepoliaBridge.getFee(ARBITRUM_CHAIN_SELECTOR, SEPOLIA_ASSET, TRANSFER_AMOUNT);
        console.log("  Required CCIP fee:", fee);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Approve bridge to spend tokens
        IERC20(SEPOLIA_ASSET).approve(address(sepoliaBridge), TRANSFER_AMOUNT);
        console.log("  Approved bridge to spend tokens");
        
        // Perform cross-chain transfer
        bytes32 messageId = sepoliaBridge.crossChain{value: fee}(
            SEPOLIA_ASSET,
            TRANSFER_AMOUNT,
            ARBITRUM_CHAIN_SELECTOR,
            deployer
        );
        
        vm.stopBroadcast();
        
        console.log("  Cross-chain transfer initiated!");
        console.log("  Message ID:", vm.toString(messageId));
        
        // Check balance after burn
        uint256 sepoliaBalanceAfter = IERC20(SEPOLIA_ASSET).balanceOf(deployer);
        console.log("  Sepolia balance after burn:", sepoliaBalanceAfter);
        console.log("  Tokens burned:", sepoliaBalanceBefore - sepoliaBalanceAfter);
        
        // Wait for CCIP message processing
        console.log("3. Waiting 30 seconds for CCIP message processing...");
        vm.sleep(30000); // 30 seconds
        
        // Check final balances
        console.log("4. Checking final balances after CCIP processing...");
        
        // Check Arbitrum balance
        vm.createSelectFork(arbitrumRpc);
        uint256 arbitrumBalanceAfter = IERC20(ARBITRUM_ASSET).balanceOf(deployer);
        console.log("  Arbitrum balance after:", arbitrumBalanceAfter);
        console.log("  Tokens received:", arbitrumBalanceAfter - arbitrumBalanceBefore);
        
        // Final summary
        console.log("");
        console.log("=== CROSS-CHAIN TRANSFER TEST RESULTS ===");
        console.log("Message ID:", vm.toString(messageId));
        console.log("Transfer Amount:", TRANSFER_AMOUNT);
        console.log("Tokens Burned on Sepolia:", sepoliaBalanceBefore - sepoliaBalanceAfter);
        console.log("Tokens Received on Arbitrum:", arbitrumBalanceAfter - arbitrumBalanceBefore);
        
        if (arbitrumBalanceAfter - arbitrumBalanceBefore == TRANSFER_AMOUNT) {
            console.log("SUCCESS: Cross-chain transfer completed successfully!");
        } else if (arbitrumBalanceAfter == arbitrumBalanceBefore) {
            console.log("PENDING: Transfer may still be processing. Check CCIP Explorer:");
            console.log("https://ccip.chain.link/msg/", vm.toString(messageId));
        } else {
            console.log("WARNING: Unexpected balance change. Check transaction details.");
        }
        
        console.log("");
        console.log("=== TEST COMPLETE ===");
    }
}
// Successfully tested cross-chain transfer from Sepolia to Arbitrum using CCIP.
// https://ccip.chain.link/#/side-drawer/msg/0xb89da0fb51eb39cce0b2db41c2e1c61abdcd54539efce3e4c79645919a043f69