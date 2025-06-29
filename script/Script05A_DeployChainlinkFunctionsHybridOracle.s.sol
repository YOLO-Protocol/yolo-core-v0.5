// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/oracles/ChainlinkFunctionsHybridOracle.sol";

/**
 * @title   Script05A_DeployChainlinkFunctionsHybridOracle
 * @author  0xyolodev.eth
 * @notice  Deploy ChainlinkFunctionsHybridOracle for XAU/USD price with real API integration
 * @dev     Deploys on Sepolia testnet with Chainlink Functions configuration
 *
 * Usage:
 * forge script script/Script05A_DeployChainlinkFunctionsHybridOracle.s.sol --broadcast --verify
 */
contract Script05A_DeployChainlinkFunctionsHybridOracle is Script {
    // **********************//
    // *** CONFIGURATION *** //
    // ********************** //

    // Chainlink Functions Sepolia Configuration (2025)
    address constant FUNCTIONS_ROUTER = 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0;
    bytes32 constant DON_ID = 0x66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000; // "fun-ethereum-sepolia-1"
    uint32 constant GAS_LIMIT = 300000;

    // Existing XAU/USD Price Feed on Sepolia
    address constant XAU_USD_PRICE_FEED = 0xC5981F461d74c46eB4b0CF3f4Ec79f025573B0Ea;

    // Chainlink Functions subscription ID
    uint64 constant DEFAULT_SUBSCRIPTION_ID = 5232; // CHAINLINK FUNCTIONS SUBSCRIPTION ID

    // JavaScript source code for API call - FIXED: Invert XAU rate since API returns XAU per USD, not USD per XAU
    string constant API_SOURCE = "const response = await Functions.makeHttpRequest({"
        "url: 'https://api.coinbase.com/v2/exchange-rates'," "method: 'GET'" "});" "if (response.error) {"
        "throw Error('Request failed');" "}" "const data = response.data;"
        "if (!data.data || !data.data.rates || !data.data.rates.XAU) {" "throw Error('Invalid response format');" "}"
        "const xauPerUsd = parseFloat(data.data.rates.XAU);" "if (isNaN(xauPerUsd) || xauPerUsd <= 0) {"
        "throw Error('Invalid XAU rate');" "}" "const usdPerXau = 1 / xauPerUsd;"
        "const priceWith8Decimals = Math.round(usdPerXau * 100000000);"
        "return Functions.encodeInt256(priceWith8Decimals);";

    // Deployment results
    ChainlinkFunctionsHybridOracle public deployedOracle;

    function run() external {
        string memory sepoliaRpc = vm.envString("SEPOLIA_RPC");
        vm.createSelectFork(sepoliaRpc);

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployerAddress = vm.addr(deployerPrivateKey);

        console.log("=== ChainlinkFunctionsHybridOracle Deployment ===");
        console.log("Deployer:", deployerAddress);
        console.log("Functions Router:", FUNCTIONS_ROUTER);
        console.log("XAU/USD Price Feed:", XAU_USD_PRICE_FEED);
        console.log("DON ID:", vm.toString(DON_ID));
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy the hybrid oracle
        deployedOracle = new ChainlinkFunctionsHybridOracle(
            FUNCTIONS_ROUTER, XAU_USD_PRICE_FEED, API_SOURCE, DON_ID, DEFAULT_SUBSCRIPTION_ID, GAS_LIMIT
        );

        vm.stopBroadcast();

        console.log("=== Deployment Results ===");
        console.log("ChainlinkFunctionsHybridOracle:", address(deployedOracle));
        console.log("");

        // Verify deployment
        console.log("=== Verifying Deployment ===");
        console.log("Owner:", deployedOracle.owner());
        console.log("Price Feed Address:", deployedOracle.getPriceFeedAddress());
        console.log("Functions Enabled:", deployedOracle.functionsEnabled());
        console.log("Emergency Mode:", deployedOracle.emergencyMode());
        console.log("");

        // Get initial price from traditional feed
        console.log("=== Initial Price Feed Test ===");
        int256 initialPrice = deployedOracle.latestAnswer();
        uint256 initialTimestamp = deployedOracle.latestTimestamp();
        console.log("Initial XAU/USD Price:", vm.toString(initialPrice));
        console.log("Initial Timestamp:", initialTimestamp);
        console.log("Price in USD (8 decimals):", vm.toString(uint256(initialPrice) / 1e8));
        console.log("");

        // Display oracle comparison
        console.log("=== Oracle Source Comparison ===");
        (int256 functionsPrice, uint256 functionsTime, int256 feedPrice, uint256 feedTime) =
            deployedOracle.getOracleComparison();

        console.log("Functions Price:", vm.toString(functionsPrice));
        console.log("Functions Timestamp:", functionsTime);
        console.log("Feed Price:", vm.toString(feedPrice));
        console.log("Feed Timestamp:", feedTime);
        console.log("Active Source (Functions):", deployedOracle.getActiveSource());
        console.log("");

        // Instructions for next steps
        console.log("=== Next Steps ===");
        console.log("1. Create Chainlink Functions subscription at: https://functions.chain.link/sepolia");
        console.log("2. Fund subscription with at least 2 LINK tokens");
        console.log("3. Add consumer contract:", address(deployedOracle));
        console.log("4. Update subscription ID using: updateConfiguration()");
        console.log("5. Test pullPrice() function to fetch off-chain data");
        console.log("");
        console.log("=== Deployment Complete ===");
    }
}
