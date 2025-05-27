// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title   Config01_OraclesAndAssets
 * @author  0xyolodev.eth
 * @dev     This contracts configures the set of mock assets and oracles.
 */
contract Config01_OraclesAndAssets {
    struct MockAssetConfig {
        string name;
        string symbol;
        uint256 initialSupply;
    }

    struct MockOracleConfig {
        string description;
        int256 initialPrice;
    }

    MockAssetConfig[] internal mockAssetsConfig;
    MockOracleConfig[] internal mockOraclesConfig;

    constructor() {
        // Initialize Mock Assets
        mockAssetsConfig.push(MockAssetConfig("Mock DAI", "DAI", 100_000_000 * 1e18));
        mockAssetsConfig.push(MockAssetConfig("Mock USDC", "USDC", 100_000_000 * 1e18));
        mockAssetsConfig.push(MockAssetConfig("Mock USDT", "USDT", 100_000_000 * 1e18));
        mockAssetsConfig.push(MockAssetConfig("Mock USDe", "USDe", 100_000_000 * 1e18));
        mockAssetsConfig.push(MockAssetConfig("Mock WBTC", "WBTC", 100_000_000 * 1e18));
        mockAssetsConfig.push(MockAssetConfig("Mock PT-sUSDe-31JUL2025", "PT-sUSDe-31JUL2025", 10_000_000 * 1e18));
        mockAssetsConfig.push(MockAssetConfig("Mock wstETH", "wstETH", 10_000_000 * 1e18));
        mockAssetsConfig.push(MockAssetConfig("Mock WETH", "WETH", 0 * 1e18));

        // Initialize Mock Oracles
        mockOraclesConfig.push(MockOracleConfig("DAI / USD", 1 * 1e8));
        mockOraclesConfig.push(MockOracleConfig("USDC / USD", 1 * 1e8));
        mockOraclesConfig.push(MockOracleConfig("USDT / USD", 1 * 1e8));
        mockOraclesConfig.push(MockOracleConfig("USDe / USD", 1 * 1e8));
        mockOraclesConfig.push(MockOracleConfig("WBTC / USD", 104_000 * 1e8));
        mockOraclesConfig.push(MockOracleConfig("PT-sUSDe-31JUL2025 / USD", 2_600 * 1e8));
        mockOraclesConfig.push(MockOracleConfig("wstETH / USD", 3_061_441_798_33));
        mockOraclesConfig.push(MockOracleConfig("WETH / USD", 2_600 * 1e8));
    }

    function getMockAssetsLength() public view returns (uint256) {
        return mockAssetsConfig.length;
    }

    function getMockAssetName(uint256 index) public view returns (string memory) {
        return mockAssetsConfig[index].name;
    }

    function getMockAssetSymbol(uint256 index) public view returns (string memory) {
        return mockAssetsConfig[index].symbol;
    }

    function getMockAssetInitialSupply(uint256 index) public view returns (uint256) {
        return mockAssetsConfig[index].initialSupply;
    }

    function getMockOraclesLength() public view returns (uint256) {
        return mockOraclesConfig.length;
    }

    function getMockOracleDescription(uint256 index) public view returns (string memory) {
        return mockOraclesConfig[index].description;
    }

    function getMockOracleInitialPrice(uint256 index) public view returns (int256) {
        return mockOraclesConfig[index].initialPrice;
    }
}
