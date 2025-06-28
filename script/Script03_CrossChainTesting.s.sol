// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/*---------- IMPORT FORGE SCRIPTS ----------*/
import {Script, console} from "forge-std/Script.sol";

/*---------- IMPORT CONTRACTS ----------*/
import {MockYoloCrossChainTesterHook} from "@yolo/contracts/mocks/MockYoloCrossChainTesterHook.sol";
import {YoloCCIPBridge} from "@yolo/contracts/cross-chain/YoloCCIPBridge.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title   Script03_CrossChainTesting
 * @author  0xyolodev.eth
 * @notice  Deployment and testing script for cross-chain functionality using CCIP
 * @dev     This script deploys MockYoloHook and YoloCCIPBridge on two different chains
 *          and tests cross-chain asset transfers between them
 * 
 * Usage:
 * 1. Set CHAIN_A_RPC and CHAIN_B_RPC in your environment
 * 2. Ensure PRIVATE_KEY is set in .env
 * 3. Run: forge script script/Script03_CrossChainTesting.s.sol --broadcast
 */
contract Script03_CrossChainTesting is Script {
    
    // ***************** //
    // *** CONSTANTS *** //
    // ***************** //
    
    /*----- Chain Configuration -----*/
    // Ethereum Sepolia Testnet
    uint64 constant CHAIN_A_SELECTOR = 16015286601757825753;
    address constant CHAIN_A_ROUTER = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59; // Sepolia CCIP Router
    
    // Polygon Mumbai Testnet  
    uint64 constant CHAIN_B_SELECTOR = 12532609583862916517;
    address constant CHAIN_B_ROUTER = 0x1035CabC275068e0F4b745A29CEDf38E13aF41b1; // Mumbai CCIP Router
    
    /*----- Test Configuration -----*/
    uint256 constant TEST_AMOUNT = 1000 * 1e18; // 1000 tokens
    string constant ASSET_NAME = "Test Yolo USD";
    string constant ASSET_SYMBOL = "TUSY";
    uint8 constant ASSET_DECIMALS = 18;

    // ************************* //
    // *** CONTRACT VARIABLES *** //
    // ************************* //
    
    /*----- Chain A Contracts -----*/
    MockYoloCrossChainTesterHook public chainAHook;
    YoloCCIPBridge public chainABridge;
    address public chainAAsset;
    
    /*----- Chain B Contracts -----*/
    MockYoloCrossChainTesterHook public chainBHook;
    YoloCCIPBridge public chainBBridge;
    address public chainBAsset;
    
    /*----- Test Variables -----*/
    uint256 public deployerPrivateKey;
    address public deployer;

    // ***************//
    // *** EVENTS *** //
    // ************** //
    
    event ChainADeploymentComplete(address hook, address bridge, address asset);
    event ChainBDeploymentComplete(address hook, address bridge, address asset);
    event CrossChainTestComplete(bytes32 messageId, uint256 amount);

    // *******************//
    // *** MAIN SCRIPT *** //
    // ****************** //

    function run() external {
        // Load private key from environment
        deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== YOLO CROSS-CHAIN TESTING SCRIPT ===");
        console.log("Deployer address:", deployer);
        console.log("");

        // Deploy on Chain A (Ethereum Sepolia)
        console.log("1. Deploying on Chain A (Ethereum Sepolia)...");
        deployChainA();
        
        // Deploy on Chain B (Polygon Mumbai)
        console.log("2. Deploying on Chain B (Polygon Mumbai)...");
        deployChainB();
        
        // Setup cross-chain mapping
        console.log("3. Setting up cross-chain asset mapping...");
        setupCrossChainMapping();
        
        // Perform cross-chain test
        console.log("4. Performing cross-chain transfer test...");
        performCrossChainTest();
        
        console.log("=== CROSS-CHAIN TESTING COMPLETE ===");
        printDeploymentSummary();
    }

    // ******************************//
    // *** DEPLOYMENT FUNCTIONS *** //
    // ***************************** //

    /**
     * @notice  Deploy contracts on Chain A (Ethereum Sepolia)
     */
    function deployChainA() internal {
        // Set Chain A RPC (you need to set this in your environment)
        string memory chainARpc = vm.envString("CHAIN_A_RPC");
        vm.createSelectFork(chainARpc);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy Mock Hook
        chainAHook = new MockYoloCrossChainTesterHook();
        console.log("  Chain A Hook deployed at:", address(chainAHook));
        
        // Deploy CCIP Bridge
        chainABridge = new YoloCCIPBridge(
            CHAIN_A_ROUTER,
            address(chainAHook),
            CHAIN_A_SELECTOR
        );
        console.log("  Chain A Bridge deployed at:", address(chainABridge));
        
        // Create test asset
        chainAAsset = chainAHook.createNewYoloAsset(ASSET_NAME, ASSET_SYMBOL, ASSET_DECIMALS);
        console.log("  Chain A Asset created at:", chainAAsset);
        
        // Register bridge with hook
        chainAHook.registerBridge(address(chainABridge));
        console.log("  Chain A Bridge registered with Hook");
        
        // Mint test tokens to deployer
        chainAHook.mintForTesting(chainAAsset, TEST_AMOUNT, deployer);
        console.log("  Chain A Test tokens minted:", TEST_AMOUNT);
        
        vm.stopBroadcast();
        
        emit ChainADeploymentComplete(address(chainAHook), address(chainABridge), chainAAsset);
        console.log("  Chain A deployment complete!");
        console.log("");
    }

    /**
     * @notice  Deploy contracts on Chain B (Polygon Mumbai)
     */
    function deployChainB() internal {
        // Set Chain B RPC (you need to set this in your environment)
        string memory chainBRpc = vm.envString("CHAIN_B_RPC");
        vm.createSelectFork(chainBRpc);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy Mock Hook
        chainBHook = new MockYoloCrossChainTesterHook();
        console.log("  Chain B Hook deployed at:", address(chainBHook));
        
        // Deploy CCIP Bridge
        chainBBridge = new YoloCCIPBridge(
            CHAIN_B_ROUTER,
            address(chainBHook),
            CHAIN_B_SELECTOR
        );
        console.log("  Chain B Bridge deployed at:", address(chainBBridge));
        
        // Create test asset (same name/symbol as Chain A for testing)
        chainBAsset = chainBHook.createNewYoloAsset(ASSET_NAME, ASSET_SYMBOL, ASSET_DECIMALS);
        console.log("  Chain B Asset created at:", chainBAsset);
        
        // Register bridge with hook
        chainBHook.registerBridge(address(chainBBridge));
        console.log("  Chain B Bridge registered with Hook");
        
        vm.stopBroadcast();
        
        emit ChainBDeploymentComplete(address(chainBHook), address(chainBBridge), chainBAsset);
        console.log("  Chain B deployment complete!");
        console.log("");
    }

    /**
     * @notice  Setup cross-chain asset mapping between chains
     */
    function setupCrossChainMapping() internal {
        // Setup Chain A -> Chain B mapping
        string memory chainARpc = vm.envString("CHAIN_A_RPC");
        vm.createSelectFork(chainARpc);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Enable Chain B on Chain A bridge
        chainABridge.setSupportedChain(CHAIN_B_SELECTOR, true);
        console.log("  Chain A: Enabled Chain B support");
        
        // Map Chain A asset to Chain B asset
        chainABridge.setAssetMapping(CHAIN_B_SELECTOR, chainAAsset, chainBAsset);
        console.log("  Chain A: Mapped asset to Chain B");
        
        vm.stopBroadcast();
        
        // Setup Chain B -> Chain A mapping
        string memory chainBRpc = vm.envString("CHAIN_B_RPC");
        vm.createSelectFork(chainBRpc);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Enable Chain A on Chain B bridge
        chainBBridge.setSupportedChain(CHAIN_A_SELECTOR, true);
        console.log("  Chain B: Enabled Chain A support");
        
        // Map Chain B asset to Chain A asset
        chainBBridge.setAssetMapping(CHAIN_A_SELECTOR, chainBAsset, chainAAsset);
        console.log("  Chain B: Mapped asset to Chain A");
        
        vm.stopBroadcast();
        
        console.log("  Cross-chain mapping setup complete!");
        console.log("");
    }

    /**
     * @notice  Perform cross-chain transfer test from Chain A to Chain B
     */
    function performCrossChainTest() internal {
        // Switch to Chain A for sending
        string memory chainARpc = vm.envString("CHAIN_A_RPC");
        vm.createSelectFork(chainARpc);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Check initial balance
        uint256 initialBalance = IERC20(chainAAsset).balanceOf(deployer);
        console.log("  Initial balance on Chain A:", initialBalance);
        
        // Approve bridge to spend tokens
        IERC20(chainAAsset).approve(address(chainABridge), TEST_AMOUNT);
        console.log("  Approved bridge to spend tokens");
        
        // Get required fee
        uint256 fee = chainABridge.getFee(CHAIN_B_SELECTOR, chainAAsset, TEST_AMOUNT);
        console.log("  Required CCIP fee:", fee);
        
        // Perform cross-chain transfer (Note: This will fail in test environment without real CCIP)
        // In a real environment, you would send with proper fee
        try chainABridge.crossChain{value: fee}(
            chainAAsset,
            TEST_AMOUNT,
            CHAIN_B_SELECTOR,
            deployer
        ) returns (bytes32 messageId) {
            console.log("  Cross-chain transfer initiated!");
            console.log("  Message ID:", vm.toString(messageId));
            emit CrossChainTestComplete(messageId, TEST_AMOUNT);
        } catch Error(string memory reason) {
            console.log("  Cross-chain transfer failed (expected in test):", reason);
            console.log("  This is normal - CCIP requires real network connectivity");
        }
        
        vm.stopBroadcast();
        
        console.log("  Cross-chain test complete!");
        console.log("");
    }

    // ***************************//
    // *** UTILITY FUNCTIONS *** //
    // ************************** //

    /**
     * @notice  Print deployment summary
     */
    function printDeploymentSummary() internal view {
        console.log("=== DEPLOYMENT SUMMARY ===");
        console.log("");
        console.log("Chain A (Ethereum Sepolia):");
        console.log("  Hook:", address(chainAHook));
        console.log("  Bridge:", address(chainABridge));
        console.log("  Asset:", chainAAsset);
        console.log("  Chain Selector:", CHAIN_A_SELECTOR);
        console.log("");
        console.log("Chain B (Polygon Mumbai):");
        console.log("  Hook:", address(chainBHook));
        console.log("  Bridge:", address(chainBBridge));
        console.log("  Asset:", chainBAsset);
        console.log("  Chain Selector:", CHAIN_B_SELECTOR);
        console.log("");
        console.log("Test Configuration:");
        console.log("  Asset Name:", ASSET_NAME);
        console.log("  Asset Symbol:", ASSET_SYMBOL);
        console.log("  Test Amount:", TEST_AMOUNT);
        console.log("");
        console.log("Next Steps:");
        console.log("1. Fund bridges with native tokens for CCIP fees");
        console.log("2. Test actual cross-chain transfers on live testnets");
        console.log("3. Monitor CCIP Explorer for message status");
        console.log("");
        console.log("=== END SUMMARY ===");
    }

    /**
     * @notice  Helper function to convert bytes32 to string for logging
     */
    function bytes32ToString(bytes32 _bytes32) internal pure returns (string memory) {
        uint8 i = 0;
        while(i < 32 && _bytes32[i] != 0) {
            i++;
        }
        bytes memory bytesArray = new bytes(i);
        for (i = 0; i < 32 && _bytes32[i] != 0; i++) {
            bytesArray[i] = _bytes32[i];
        }
        return string(bytesArray);
    }
}