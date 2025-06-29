// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/oracles/ChainlinkFunctionsHybridOracle.sol";

/**
 * @title Script05C_VerifyChainlinkFunctionsHybridOracle
 * @notice Verification script to check if off-chain price was fetched successfully
 * @dev Run this 30+ seconds after triggering pullPrice() to verify the result
 *
 * Usage:
 * forge script script/Script05C_VerifyChainlinkFunctionsHybridOracle.s.sol
 */
contract Script05C_VerifyChainlinkFunctionsHybridOracle is Script {
    // Update this with your deployed oracle address
    address constant ORACLE_ADDRESS = 0xA1BFa90d29ef1A075AeC9D69744a40C1203c196d; // SEPOLIA DEPLOYMENT WITH FIXED API

    ChainlinkFunctionsHybridOracle public oracle;

    function run() external {
        string memory sepoliaRpc = vm.envString("SEPOLIA_RPC");
        vm.createSelectFork(sepoliaRpc);

        require(ORACLE_ADDRESS != address(0), "Please update ORACLE_ADDRESS");

        oracle = ChainlinkFunctionsHybridOracle(ORACLE_ADDRESS);

        console.log("=== ChainlinkFunctionsHybridOracle Verification ===");
        console.log("Oracle Address:", address(oracle));
        console.log("");

        // Step 1: Get current oracle state
        console.log("=== Current Oracle State ===");
        verifyCurrentState();

        // Step 2: Compare oracle sources
        console.log("=== Oracle Source Comparison ===");
        compareOracleSources();

        // Step 3: Verify 8-decimal format
        console.log("=== Price Format Verification ===");
        verifyPriceFormat();

        // Step 4: Check Functions integration
        console.log("=== Functions Integration Check ===");
        checkFunctionsIntegration();

        console.log("=== Verification Complete ===");
    }

    function verifyCurrentState() internal view {
        int256 currentPrice = oracle.latestAnswer();
        uint256 currentTimestamp = oracle.latestTimestamp();
        uint256 currentRound = oracle.latestRound();
        bool isUsingFunctions = oracle.getActiveSource();

        console.log("Latest Answer:", vm.toString(currentPrice));
        console.log("Latest Timestamp:", currentTimestamp);
        console.log("Latest Round:", currentRound);
        console.log("Using Functions Source:", isUsingFunctions);
        console.log("Price in USD:", vm.toString(uint256(currentPrice) / 1e8));
        console.log("");
    }

    function compareOracleSources() internal view {
        (int256 functionsPrice, uint256 functionsTime, int256 feedPrice, uint256 feedTime) =
            oracle.getOracleComparison();

        console.log("Functions Price:", vm.toString(functionsPrice));
        console.log("Functions Timestamp:", functionsTime);
        console.log("Functions USD Price:", vm.toString(uint256(functionsPrice) / 1e8));
        console.log("");
        console.log("Price Feed Price:", vm.toString(feedPrice));
        console.log("Price Feed Timestamp:", feedTime);
        console.log("Price Feed USD Price:", vm.toString(uint256(feedPrice) / 1e8));
        console.log("");

        // Check if Functions price is newer
        if (functionsTime > feedTime) {
            console.log("[ OK ] Functions price is NEWER than price feed");
            console.log("Time difference:", functionsTime - feedTime, "seconds");
        } else if (functionsTime == feedTime) {
            console.log("[ WARN ] Functions and feed timestamps are EQUAL");
        } else {
            console.log("[ ERROR ] Functions price is OLDER than price feed");
            console.log("Time difference:", feedTime - functionsTime, "seconds");
        }
        console.log("");

        // Check price difference
        if (functionsPrice != feedPrice) {
            uint256 priceDiff =
                functionsPrice > feedPrice ? uint256(functionsPrice - feedPrice) : uint256(feedPrice - functionsPrice);
            uint256 percentDiff = (priceDiff * 10000) / uint256(feedPrice); // basis points
            console.log("Price Difference:", vm.toString(priceDiff));
            console.log("Percentage Difference:", vm.toString(percentDiff / 100));
            console.log("Decimal Part:", vm.toString(percentDiff % 100));
        } else {
            console.log("Prices are IDENTICAL");
        }
        console.log("");
    }

    function verifyPriceFormat() internal view {
        int256 currentPrice = oracle.latestAnswer();

        // Verify positive price
        if (currentPrice > 0) {
            console.log("[ OK ] Price is positive");
        } else {
            console.log("[ ERROR ] Price is not positive:", vm.toString(currentPrice));
        }

        // Verify reasonable XAU price range (8 decimals)
        int256 minPrice = 150000000000; // $1,500 in 8 decimals
        int256 maxPrice = 500000000000; // $5,000 in 8 decimals

        if (currentPrice >= minPrice && currentPrice <= maxPrice) {
            console.log("[ OK ] Price is within reasonable XAU range");
        } else {
            console.log("[ WARN ] Price might be outside typical XAU range");
            console.log("Current:", vm.toString(uint256(currentPrice) / 1e8), "USD");
            console.log("Expected range: $1,500 - $5,000");
        }

        // Verify 8-decimal format
        uint256 priceUint = uint256(currentPrice);
        if (priceUint % 1e8 == priceUint) {
            // Check if it's less than 1e8
            console.log("[ WARN ] Price might not be in 8-decimal format");
        } else {
            console.log("[ OK ] Price appears to be in 8-decimal format");
        }
        console.log("");
    }

    function checkFunctionsIntegration() internal view {
        bool functionsEnabled = oracle.functionsEnabled();
        bool emergencyMode = oracle.emergencyMode();
        bytes32 lastRequestId = oracle.lastRequestId();

        console.log("Functions Enabled:", functionsEnabled);
        console.log("Emergency Mode:", emergencyMode);
        console.log("Last Request ID:", vm.toString(lastRequestId));

        if (lastRequestId != bytes32(0)) {
            console.log("[ OK ] Functions requests have been made");
        } else {
            console.log("[ WARN ] No Functions requests detected");
        }

        if (functionsEnabled && !emergencyMode) {
            console.log("[ OK ] Functions are properly configured");
        } else {
            console.log("[ WARN ] Functions may not be fully operational");
        }
        console.log("");

        // Configuration check
        console.log("--- Configuration Details ---");
        console.log("DON ID:", vm.toString(oracle.donId()));
        console.log("Subscription ID:", oracle.subscriptionId());
        console.log("Gas Limit:", oracle.gasLimit());
        console.log("Price Feed Address:", oracle.getPriceFeedAddress());
        console.log("");
    }
}
