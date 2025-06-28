// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/*---------- IMPORT FORGE SCRIPTS ----------*/
import {Script, console} from "forge-std/Script.sol";

/*---------- IMPORT CONTRACTS ----------*/
import {YoloAccrossBridge} from "@yolo/contracts/cross-chain/YoloAcrossBridge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title   Script04D_TestCrossChainTransferAcrossTesting
 * @author  0xyolodev.eth
 * @notice  Test cross-chain transfer from Sepolia to Arbitrum using Across Protocol, wait, then check results
 * @dev     You need to update the addresses below from the output of Script04A and Script04B
 */
contract Script04D_TestCrossChainTransferAcrossTesting is Script {
    
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
    
    /*----- Test Configuration -----*/
    uint256 constant TRANSFER_AMOUNT = 100 * 1e18; // 100 tokens

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== TESTING ACROSS CROSS-CHAIN TRANSFER ===");
        console.log("Transfer Amount:", TRANSFER_AMOUNT);
        console.log("From: Sepolia ->", "To: Arbitrum");
        console.log("Protocol: Across Protocol");
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
        console.log("2. Initiating cross-chain transfer via Across...");
        vm.createSelectFork(sepoliaRpc);
        
        YoloAccrossBridge sepoliaBridge = YoloAccrossBridge(SEPOLIA_BRIDGE);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Note: Across Protocol uses pure messaging for synthetic assets (no fees required)
        console.log("  Across uses 0-amount deposits for pure messaging");
        
        // Perform cross-chain transfer
        bytes32 depositId = sepoliaBridge.crossChain(
            SEPOLIA_ASSET,
            TRANSFER_AMOUNT,
            ARBITRUM_CHAIN_ID,
            deployer
        );
        
        vm.stopBroadcast();
        
        console.log("  Cross-chain transfer initiated!");
        console.log("  Deposit ID:", vm.toString(depositId));
        
        // Check balance after burn
        uint256 sepoliaBalanceAfter = IERC20(SEPOLIA_ASSET).balanceOf(deployer);
        console.log("  Sepolia balance after burn:", sepoliaBalanceAfter);
        console.log("  Tokens burned:", sepoliaBalanceBefore - sepoliaBalanceAfter);
        
        // Wait for Across message processing
        console.log("3. Waiting 30 seconds for Across message processing...");
        console.log("  Note: Testnet fills typically take around 1 minute");
        vm.sleep(30000); // 30 seconds
        
        // Check final balances
        console.log("4. Checking final balances after Across processing...");
        
        // Check Arbitrum balance
        vm.createSelectFork(arbitrumRpc);
        uint256 arbitrumBalanceAfter = IERC20(ARBITRUM_ASSET).balanceOf(deployer);
        console.log("  Arbitrum balance after:", arbitrumBalanceAfter);
        console.log("  Tokens received:", arbitrumBalanceAfter - arbitrumBalanceBefore);
        
        // Final summary
        console.log("");
        console.log("=== ACROSS CROSS-CHAIN TRANSFER TEST RESULTS ===");
        console.log("Deposit ID:", vm.toString(depositId));
        console.log("Transfer Amount:", TRANSFER_AMOUNT);
        console.log("Tokens Burned on Sepolia:", sepoliaBalanceBefore - sepoliaBalanceAfter);
        console.log("Tokens Received on Arbitrum:", arbitrumBalanceAfter - arbitrumBalanceBefore);
        
        if (arbitrumBalanceAfter - arbitrumBalanceBefore == TRANSFER_AMOUNT) {
            console.log("SUCCESS: Across cross-chain transfer completed successfully!");
        } else if (arbitrumBalanceAfter == arbitrumBalanceBefore) {
            console.log("PENDING: Transfer may still be processing.");
            console.log("Note: Testnet fills typically take around 1 minute (vs 2s on mainnet)");
            console.log("Check Across Explorer for deposit status:");
            console.log("https://testnet.across.to/");
        } else {
            console.log("WARNING: Unexpected balance change. Check transaction details.");
        }
        
        console.log("");
        console.log("=== TEST COMPLETE ===");
    }
}