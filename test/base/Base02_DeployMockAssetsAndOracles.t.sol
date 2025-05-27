// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@yolo/test/config/Config01_OraclesAndAssets.sol";
import "@yolo/contracts/mocks/MockPriceOracle.sol";
import "@yolo/contracts/mocks/MockERC20.sol";
import {MockWETH} from "@yolo/contracts/mocks/MockWETH.sol";
import {MockPriceOracle} from "@yolo/contracts/mocks/MockPriceOracle.sol";
import {IWETH} from "@yolo/contracts/interfaces/IWETH.sol";

/**
 * @title   Base02_DeployMockAssetsAndOracles
 * @author  0xyolodev.eth
 * @dev     This contract serves as the best contract for deploying mock assets and oracles
 *          in a testing environment.
 */
contract Base02_DeployMockAssetsAndOracles is Test, Config01_OraclesAndAssets {
    IWETH public weth;

    mapping(string => address) public symbolToDeployedAsset;
    mapping(string => address) public symbolToDeployedOracle;
    mapping(address => address) public assetToOracle;
    mapping(address => bool) public matchedOracle;

    function setUp() public virtual {
        // Deploy Mock Assets based on the configuration
        for (uint256 i = 0; i < getMockAssetsLength(); i++) {
            string memory name = getMockAssetName(i);
            string memory symbol = getMockAssetSymbol(i);
            uint256 supply = getMockAssetInitialSupply(i);

            if (keccak256(abi.encodePacked(symbol)) != keccak256(abi.encodePacked("WETH"))) {
                MockERC20 token = new MockERC20(name, symbol, supply);
                symbolToDeployedAsset[symbol] = address(token);
            } else {
                MockWETH mockWeth = new MockWETH();
                symbolToDeployedAsset[symbol] = address(mockWeth);
                weth = IWETH(address(mockWeth));
            }

            emit log_named_address(string(abi.encodePacked("Deployed Asset: ", symbol)), symbolToDeployedAsset[symbol]);
        }

        // Deploy Mock Oracles based on the configuration
        for (uint256 i = 0; i < getMockOraclesLength(); i++) {
            string memory description = getMockOracleDescription(i);
            int256 price = getMockOracleInitialPrice(i);

            MockPriceOracle oracle = new MockPriceOracle(price, description);
            symbolToDeployedOracle[description] = address(oracle);

            // Link the asset to its corresponding oracle
            string memory symbol = _extractSymbolFromDescription(description);
            address asset = symbolToDeployedAsset[symbol];
            if (asset != address(0)) {
                assetToOracle[asset] = address(oracle);
            }

            emit log_named_address(string(abi.encodePacked("Deployed Oracle: ", description)), address(oracle));
        }
    }

    /**
     * @notice  Ensure WETH is properly set up with deposit and withdraw functionality.
     */
    function test_Base02_Case01_WethProperlySetup() external {
        // Check if WETH is deployed and has the correct initial state
        assertTrue(address(weth) != address(0), "Base02: WETH not deployed");
        assertEq(weth.balanceOf(address(this)), 0, "Base02: Initial WETH balance should be zero");

        // Test deposit functionality
        uint256 depositAmount = 1 ether;
        weth.deposit{value: depositAmount}();
        assertEq(
            weth.balanceOf(address(this)),
            depositAmount,
            "Base02: WETH balance after deposit should match deposit amount"
        );

        // Test withdraw functionality
        weth.withdraw(depositAmount);
        console.log("WETH balance after withdraw:", weth.balanceOf(address(this)));
        assertEq(weth.balanceOf(address(this)), 0, "Base02: WETH balance after withdraw should be zero");
    }

    /**
     * @notice  Make sure all assets have corresponding oracles deployed, and it is no oracles were
     *          reused.
     */
    function test_Base02_Case02_AllAssetsHaveOracles() external {
        for (uint256 i = 0; i < getMockAssetsLength(); i++) {
            string memory symbol = getMockAssetSymbol(i);
            address asset = symbolToDeployedAsset[symbol];

            address oracle = assetToOracle[asset];

            emit log_named_address(string(abi.encodePacked("Asset: ", symbol)), asset);
            emit log_named_address("Oracle:", oracle);

            assertTrue(oracle != address(0), string(abi.encodePacked("Base02: No oracle found for asset: ", symbol)));
            assertTrue(
                matchedOracle[oracle] == false, string(abi.encodePacked("Base02: Oracle reused for asset: ", symbol))
            );
            matchedOracle[oracle] = true;
        }
    }

    // ********************************* //
    // *** INTERNAL HELPER FUNCTIONS *** //
    // ********************************* //

    function _extractSymbolFromDescription(string memory description) internal pure returns (string memory) {
        bytes memory descBytes = bytes(description);
        uint256 length = 0;

        for (uint256 i = 0; i < descBytes.length; i++) {
            if (descBytes[i] == bytes(" ")[0] || descBytes[i] == bytes("/")[0]) {
                break;
            }
            length++;
        }

        bytes memory symbolBytes = new bytes(length);
        for (uint256 j = 0; j < length; j++) {
            symbolBytes[j] = descBytes[j];
        }

        return string(symbolBytes);
    }

    // ************************** //
    // *** FALLBACK FUNCTIONS *** //
    // ************************** //

    /**
     * @notice  Added to allow the contract to receive ETH, which is necessary for WETH withdrawals.
     */
    receive() external payable virtual {}

    /**
     * @notice  Added to allow the contract to receive ETH, which is necessary for WETH withdrawals.
     */
    fallback() external payable virtual {}
}
