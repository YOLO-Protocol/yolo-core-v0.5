// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "./base/Base02_DeployMockAssetsAndOracles.t.sol";
import "@yolo/contracts/core/YoloOracle.sol";
import "@yolo/contracts/mocks/MockPriceOracle.sol";
import "@yolo/contracts/mocks/MockERC20.sol";
import {MockWETH} from "@yolo/contracts/mocks/MockWETH.sol";

/**
 * @title   TestContract02_YoloOracle
 * @author  0xyolodev.eth
 * @dev     This contract is used to test the YoloOracle contract to ensure that it behaves
 *          as expected when aggregating price feeds from multiple sources.
 */
contract TestContract02_YoloOracle is Test, Base02_DeployMockAssetsAndOracles {
    YoloOracle public yoloOracle;

    address public owner;
    address public nonOwner;
    address public mockHook;
    address public anchorAsset;

    address[] public assets;
    address[] public oracles;

    function setUp() public override {
        super.setUp();

        owner = address(this);
        nonOwner = address(0x1234);
        mockHook = address(0x5678);

        // Collect all deployed assets and their corresponding oracles
        for (uint256 i = 0; i < getMockAssetsLength(); i++) {
            string memory symbol = getMockAssetSymbol(i);
            address asset = symbolToDeployedAsset[symbol];
            address oracle = assetToOracle[asset];

            assets.push(asset);
            oracles.push(oracle);
        }

        // Deploy YoloOracle with initial assets and sources
        yoloOracle = new YoloOracle(assets, oracles);

        // Deploy a mock anchor asset for testing
        MockERC20 mockAnchor = new MockERC20("Yolo USD", "yUSD", 1000000 * 1e18);
        anchorAsset = address(mockAnchor);

        console.log("YoloOracle deployed at:", address(yoloOracle));
        emit log_named_uint("Total assets configured:", assets.length);
    }

    /**
     * @dev Test that YoloOracle is properly initialized with all assets and price sources
     */
    function test_Contract02_Case01_oracleInitialization() public {
        // Verify all assets have price sources and can return prices
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 price = yoloOracle.getAssetPrice(assets[i]);
            assertTrue(price > 0, "Asset price should be greater than zero");

            emit log_named_address("Asset", assets[i]);
            emit log_named_uint("Price", price);
        }
    }

    /**
     * @dev Test getting prices for multiple assets in batch
     */
    function test_Contract02_Case02_batchPriceRetrieval() public {
        uint256[] memory prices = yoloOracle.getAssetsPrices(assets);

        assertEq(prices.length, assets.length, "Prices array length should match assets length");

        for (uint256 i = 0; i < prices.length; i++) {
            assertTrue(prices[i] > 0, "Each price should be greater than zero");

            // Verify batch price matches individual price
            uint256 individualPrice = yoloOracle.getAssetPrice(assets[i]);
            assertEq(prices[i], individualPrice, "Batch price should match individual price");
        }
    }

    /**
     * @dev Test setting asset sources by owner
     */
    function test_Contract02_Case03_setAssetSourcesByOwner() public {
        // Deploy a new mock oracle
        MockPriceOracle newOracle = new MockPriceOracle(2000 * 1e8, "TEST / USD");

        address[] memory newAssets = new address[](1);
        address[] memory newSources = new address[](1);
        newAssets[0] = assets[0]; // Use existing asset
        newSources[0] = address(newOracle);

        // Should succeed when called by owner
        yoloOracle.setAssetSources(newAssets, newSources);

        // Verify the price source was updated
        uint256 newPrice = yoloOracle.getAssetPrice(assets[0]);
        assertEq(newPrice, 2000 * 1e8, "Price should match new oracle price");
    }

    /**
     * @dev Test that only owner or hook can set asset sources
     */
    function test_Contract02_Case04_onlyOwnerOrHookCanSetSources() public {
        MockPriceOracle newOracle = new MockPriceOracle(3000 * 1e8, "TEST / USD");

        address[] memory newAssets = new address[](1);
        address[] memory newSources = new address[](1);
        newAssets[0] = assets[0];
        newSources[0] = address(newOracle);

        // Should fail when called by non-owner/non-hook
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("YoloOracle__CallerNotOwnerOrHook()"));
        yoloOracle.setAssetSources(newAssets, newSources);

        // Set hook first
        yoloOracle.setHook(mockHook);

        // Should succeed when called by hook
        vm.prank(mockHook);
        yoloOracle.setAssetSources(newAssets, newSources);

        uint256 updatedPrice = yoloOracle.getAssetPrice(assets[0]);
        assertEq(updatedPrice, 3000 * 1e8, "Price should be updated by hook");
    }

    /**
     * @dev Test setting and using hook functionality
     */
    function test_Contract02_Case05_hookFunctionality() public {
        // Initially no hook should be set
        assertEq(address(yoloOracle.yoloHook()), address(0), "Hook should be initially unset");

        // Set hook (only owner can do this)
        yoloOracle.setHook(mockHook);
        assertEq(address(yoloOracle.yoloHook()), mockHook, "Hook should be set correctly");

        // Non-owner should not be able to set hook
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", nonOwner));
        yoloOracle.setHook(address(0x9999));
    }

    /**
     * @dev Test anchor asset functionality
     */
    function test_Contract02_Case06_anchorAssetFunctionality() public {
        // Initially no anchor should be set
        assertEq(yoloOracle.anchor(), address(0), "Anchor should be initially unset");

        // Set anchor (only owner can do this)
        yoloOracle.setAnchor(anchorAsset);
        assertEq(yoloOracle.anchor(), anchorAsset, "Anchor should be set correctly");

        // Anchor asset should return fixed price of 1e8
        uint256 anchorPrice = yoloOracle.getAssetPrice(anchorAsset);
        assertEq(anchorPrice, 1e8, "Anchor asset should return fixed price of 1e8");

        // Should not be able to set anchor twice
        vm.expectRevert(abi.encodeWithSignature("YoloOracle__AnchorAlreadySet()"));
        yoloOracle.setAnchor(address(0x9999));
    }

    /**
     * @dev Test error handling for unsupported assets
     */
    function test_Contract02_Case07_unsupportedAssetError() public {
        address unsupportedAsset = address(0x1111);

        vm.expectRevert(abi.encodeWithSignature("YoloOracle__UnsupportedAsset()"));
        yoloOracle.getAssetPrice(unsupportedAsset);
    }

    /**
     * @dev Test parameter validation in setAssetSources
     */
    function test_Contract02_Case08_parameterValidation() public {
        address[] memory testAssets = new address[](2);
        address[] memory testSources = new address[](1); // Mismatched length

        testAssets[0] = assets[0];
        testAssets[1] = assets[1];
        testSources[0] = oracles[0];

        // Should revert due to length mismatch
        vm.expectRevert(abi.encodeWithSignature("YoloOracle__ParamsLengthMismatch()"));
        yoloOracle.setAssetSources(testAssets, testSources);

        // Should revert when trying to set zero address as price source
        address[] memory singleAsset = new address[](1);
        address[] memory zeroSource = new address[](1);
        singleAsset[0] = assets[0];
        zeroSource[0] = address(0);

        vm.expectRevert(abi.encodeWithSignature("YoloOracle__PriceSourceCannotBeZero()"));
        yoloOracle.setAssetSources(singleAsset, zeroSource);
    }

    /**
     * @dev Test batch price retrieval with mixed asset types
     */
    function test_Contract02_Case09_mixedAssetPricing() public {
        // Set anchor first
        yoloOracle.setAnchor(anchorAsset);

        // Create mixed array with regular assets and anchor
        address[] memory mixedAssets = new address[](3);
        mixedAssets[0] = assets[0]; // Regular asset
        mixedAssets[1] = anchorAsset; // Anchor asset
        mixedAssets[2] = assets[1]; // Regular asset

        uint256[] memory prices = yoloOracle.getAssetsPrices(mixedAssets);

        assertTrue(prices[0] > 0, "Regular asset should have market price");
        assertEq(prices[1], 1e8, "Anchor asset should return 1e8");
        assertTrue(prices[2] > 0, "Regular asset should have market price");
    }

    /**
     * @dev Test oracle behavior with negative prices from price source
     */
    function test_Contract02_Case10_negativePriceHandling() public {
        // Deploy oracle with negative price
        MockPriceOracle negativeOracle = new MockPriceOracle(-1000 * 1e8, "NEGATIVE / USD");

        address[] memory testAsset = new address[](1);
        address[] memory testSource = new address[](1);
        testAsset[0] = assets[0];
        testSource[0] = address(negativeOracle);

        yoloOracle.setAssetSources(testAsset, testSource);

        // Should return 0 for negative prices
        uint256 price = yoloOracle.getAssetPrice(assets[0]);
        assertEq(price, 0, "Negative price should return 0");
    }

    /**
     * @dev Test ownership transfer functionality
     */
    function test_Contract02_Case11_ownershipTransfer() public {
        // Initially owner should be this contract
        assertEq(yoloOracle.owner(), owner, "Initial owner should be test contract");

        // Transfer ownership
        yoloOracle.transferOwnership(nonOwner);

        // Old owner should no longer be able to set anchor
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", owner));
        yoloOracle.setAnchor(anchorAsset);

        // New owner should be able to set anchor
        vm.prank(nonOwner);
        yoloOracle.setAnchor(anchorAsset);

        assertEq(yoloOracle.anchor(), anchorAsset, "New owner should be able to set anchor");
    }

    /**
     * @dev Test comprehensive price source updates
     */
    function test_Contract02_Case12_comprehensivePriceUpdates() public {
        // Deploy multiple new oracles with different prices
        MockPriceOracle oracle1 = new MockPriceOracle(5000 * 1e8, "TEST1 / USD");
        MockPriceOracle oracle2 = new MockPriceOracle(6000 * 1e8, "TEST2 / USD");
        MockPriceOracle oracle3 = new MockPriceOracle(7000 * 1e8, "TEST3 / USD");

        address[] memory updateAssets = new address[](3);
        address[] memory updateSources = new address[](3);

        updateAssets[0] = assets[0];
        updateAssets[1] = assets[1];
        updateAssets[2] = assets[2];
        updateSources[0] = address(oracle1);
        updateSources[1] = address(oracle2);
        updateSources[2] = address(oracle3);

        // Update sources
        yoloOracle.setAssetSources(updateAssets, updateSources);

        // Verify all prices were updated
        assertEq(yoloOracle.getAssetPrice(assets[0]), 5000 * 1e8, "Asset 0 price should be updated");
        assertEq(yoloOracle.getAssetPrice(assets[1]), 6000 * 1e8, "Asset 1 price should be updated");
        assertEq(yoloOracle.getAssetPrice(assets[2]), 7000 * 1e8, "Asset 2 price should be updated");

        // Verify batch retrieval works with updated prices
        uint256[] memory batchPrices = yoloOracle.getAssetsPrices(updateAssets);
        assertEq(batchPrices[0], 5000 * 1e8, "Batch price 0 should match");
        assertEq(batchPrices[1], 6000 * 1e8, "Batch price 1 should match");
        assertEq(batchPrices[2], 7000 * 1e8, "Batch price 2 should match");
    }

    /**
     * @dev Test edge case with empty arrays
     */
    function test_Contract02_Case13_emptyArrayHandling() public {
        address[] memory emptyAssets = new address[](0);

        uint256[] memory prices = yoloOracle.getAssetsPrices(emptyAssets);
        assertEq(prices.length, 0, "Empty input should return empty array");
    }
}
