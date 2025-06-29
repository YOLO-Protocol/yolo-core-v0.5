// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/oracles/ChainlinkFunctionsHybridOracle.sol";

/**
 * @title   Script05B_TestChainlinkFunctionsHybridOracle
 * @author  0xyolodev.eth
 * @notice  Comprehensive testing script for ChainlinkFunctionsHybridOracle
 * @dev     Tests both traditional price feed and Functions API integration
 *
 * Usage:
 * forge script script/Script05B_TestChainlinkFunctionsHybridOracle.s.sol --broadcast
 */
contract Script05B_TestChainlinkFunctionsHybridOracle is Script {
    // Update this with your deployed oracle address
    address constant ORACLE_ADDRESS = 0xA1BFa90d29ef1A075AeC9D69744a40C1203c196d; // SEPOLIA DEPLOYMENT WITH FIXED API
    uint64 constant SUBSCRIPTION_ID = 5232; // CHAINLINK FUNCTIONS SUBSCRIPTION ID

    ChainlinkFunctionsHybridOracle public oracle;

    function run() external {
        string memory sepoliaRpc = vm.envString("SEPOLIA_RPC");
        vm.createSelectFork(sepoliaRpc);

        require(ORACLE_ADDRESS != address(0), "Please update ORACLE_ADDRESS");
        require(SUBSCRIPTION_ID != 0, "Please update SUBSCRIPTION_ID");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        oracle = ChainlinkFunctionsHybridOracle(ORACLE_ADDRESS);

        console.log("=== ChainlinkFunctionsHybridOracle Testing ===");
        console.log("Oracle Address:", address(oracle));
        console.log("Test Runner:", vm.addr(deployerPrivateKey));
        console.log("");

        // Step 1: Update subscription ID if needed
        if (oracle.subscriptionId() != SUBSCRIPTION_ID) {
            console.log("=== Updating Subscription Configuration ===");
            vm.startBroadcast(deployerPrivateKey);
            oracle.updateConfiguration(oracle.donId(), SUBSCRIPTION_ID, oracle.gasLimit());
            vm.stopBroadcast();
            console.log("Subscription ID updated to:", SUBSCRIPTION_ID);
            console.log("");
        }

        // Step 2: Test original price feed
        console.log("=== Testing Original Price Feed ===");
        testOriginalPrice();

        // Step 3: Trigger off-chain price fetch
        console.log("=== Triggering Off-Chain Price Fetch ===");
        bytes32 requestId = triggerPriceFetch();

        // Step 4: Wait 30 seconds (simulated)
        console.log("=== Waiting 30 seconds for Oracle Response ===");
        console.log("Note: In real testing, wait 30 seconds before running verification");
        console.log("Request ID to monitor:", vm.toString(requestId));
        console.log("");

        // Step 5: Instructions for manual verification
        console.log("=== Manual Verification Steps ===");
        console.log("1. Wait 30 seconds for Chainlink Functions to process");
        console.log("2. Run verification script: Script05C_VerifyChainlinkFunctionsHybridOracle.s.sol");
        console.log("3. Check if Functions price is newer than feed price");
        console.log("4. Verify 8-decimal format conformity");
        console.log("");

        console.log("=== Test Complete ===");
    }

    function testOriginalPrice() internal view {
        // Get current oracle data
        int256 currentPrice = oracle.latestAnswer();
        uint256 currentTimestamp = oracle.latestTimestamp();
        uint256 currentRound = oracle.latestRound();

        console.log("Current XAU/USD Price:", vm.toString(currentPrice));
        console.log("Current Timestamp:", currentTimestamp);
        console.log("Current Round:", currentRound);
        console.log("Price in USD:", vm.toString(uint256(currentPrice) / 1e8));

        // Get oracle comparison
        (int256 functionsPrice, uint256 functionsTime, int256 feedPrice, uint256 feedTime) =
            oracle.getOracleComparison();

        console.log("");
        console.log("--- Oracle Source Breakdown ---");
        console.log("Functions Price:", vm.toString(functionsPrice));
        console.log("Functions Timestamp:", functionsTime);
        console.log("Price Feed Price:", vm.toString(feedPrice));
        console.log("Price Feed Timestamp:", feedTime);
        console.log("Using Functions Source:", oracle.getActiveSource());
        console.log("");

        // Verify 8-decimal format
        require(currentPrice > 0, "Price should be positive");
        require(currentPrice > 100000000, "XAU price should be > $1 (in 8 decimals)");
        require(currentPrice < 1000000000000, "XAU price should be < $10,000 (in 8 decimals)");
        console.log("[ OK ] Price format validation passed");
        console.log("");
    }

    function triggerPriceFetch() internal returns (bytes32 requestId) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Check if Functions are enabled
        require(oracle.functionsEnabled(), "Functions must be enabled");
        require(!oracle.emergencyMode(), "Emergency mode must be disabled");

        console.log("Triggering pullPrice() function...");

        vm.startBroadcast(deployerPrivateKey);
        requestId = oracle.pullPrice();
        vm.stopBroadcast();

        console.log("Price fetch triggered successfully");
        console.log("Request ID:", vm.toString(requestId));
        console.log("Last Request ID:", vm.toString(oracle.lastRequestId()));
        console.log("");

        return requestId;
    }
}
