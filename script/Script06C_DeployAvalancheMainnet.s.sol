// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*---------- IMPORT FOUNDRY ----------*/
import "forge-std/Script.sol";

/*---------- IMPORT CONTRACTS ----------*/
import {PublicTransparentUpgradeableProxy} from "@yolo/contracts/proxy/PublicTransparentUpgradeableProxy.sol";
import {YoloHook} from "@yolo/contracts/core/YoloHook.sol";
import {YoloOracle} from "@yolo/contracts/core/YoloOracle.sol";
import {SyntheticAssetLogic} from "@yolo/contracts/core/SyntheticAssetLogic.sol";
import {MockWETH} from "@yolo/contracts/mocks/MockWETH.sol";
import {MockERC20} from "@yolo/contracts/mocks/MockERC20.sol";
import {MockPriceOracle} from "@yolo/contracts/mocks/MockPriceOracle.sol";
import {IWETH} from "@yolo/contracts/interfaces/IWETH.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/*---------- IMPORT CONFIGS ----------*/
import {Config01_OraclesAndAssets} from "@yolo/test/config/Config01_OraclesAndAssets.sol";
import {Config02_AssetAndCollateralInitialization} from
    "@yolo/test/config/Config02_AssetAndCollateralInitialization.sol";

/*---------- IMPORT LIBRARIES ----------*/
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/**
 * @title   Script06C_DeployAvalancheMainnet
 * @author  0xyolodev.eth
 * @dev     Deploy YOLO Protocol on Avalanche Mainnet
 *          IMPORTANT: This is a MAINNET deployment - be extra careful with private keys
 */
contract Script06C_DeployAvalancheMainnet is
    Script,
    Config01_OraclesAndAssets,
    Config02_AssetAndCollateralInitialization
{
    // Network specific constants
    string constant NETWORK_NAME = "avalanche-mainnet";
    IPoolManager constant POOL_MANAGER = IPoolManager(0x06380C0e0912312B5150364B9DC4542BA0DbBc85);
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Core Protocol Contracts
    IWETH public weth;
    YoloHook public yoloHookImplementation;
    YoloHook public yoloHookProxy;
    YoloOracle public yoloOracle;
    SyntheticAssetLogic public syntheticAssetLogic;

    // Asset mappings
    mapping(string => address) public symbolToDeployedAsset;
    mapping(string => address) public symbolToDeployedOracle;
    mapping(address => address) public assetToOracle;
    mapping(string => address) yoloAssetToAddress;

    // Convenience variables
    address public usdc;
    address public usy;
    address public yJpyAsset;
    address public yKrwAsset;
    address public yGoldAsset;
    address public yNvdaAsset;
    address public yTslaAsset;
    address public wbtcAsset;
    address public ptUsdeAsset;

    // Deployment log file
    string constant DEPLOYMENT_LOG = "logs/deployments/avalanche-mainnet-deployment.json";

    function run() external {
        // A. Load environment variables
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        string memory rpcUrl = vm.envString("AVAX_MAINNET_RPC");

        console.log("==========================================");
        console.log("    YOLO PROTOCOL DEPLOYMENT - AVALANCHE MAINNET");
        console.log("==========================================");
        console.log("WARNING: THIS IS A MAINNET DEPLOYMENT");
        console.log("Deployer:", deployer);
        console.log("Network:", NETWORK_NAME);
        console.log("Pool Manager:", address(POOL_MANAGER));
        console.log("==========================================");

        // Safety check for mainnet deployment
        require(address(POOL_MANAGER) != address(0), "Pool Manager address not set for Avalanche mainnet");

        vm.startBroadcast(deployerKey);

        // B. Deploy Mock Assets and Oracles
        _deployMockAssets();
        _deployMockOracles();
        _deployYoloAssetOracles();

        // C. Deploy Core YOLO Protocol
        _deployYoloProtocol(deployer);

        // D. Initialize Protocol
        _initializeProtocol(deployer);

        // E. Deploy and Configure Logic Contracts
        _deployLogicContracts();

        // F. Create and Configure Yolo Assets
        _createYoloAssets();

        // G. Configure Collaterals and Pairs
        _configureCollateralsAndPairs();

        // H. Initial Setup for Testing
        _setupInitialState(deployer);

        // I. Log deployment information
        _logDeploymentInfo();

        vm.stopBroadcast();

        console.log("==========================================");
        console.log("    DEPLOYMENT COMPLETED SUCCESSFULLY");
        console.log("==========================================");
    }

    function _deployMockAssets() internal {
        console.log("Deploying Mock Assets...");

        for (uint256 i = 0; i < getMockAssetsLength(); i++) {
            string memory name = getMockAssetName(i);
            string memory symbol = getMockAssetSymbol(i);
            uint256 supply = getMockAssetInitialSupply(i);

            if (keccak256(abi.encodePacked(symbol)) != keccak256(abi.encodePacked("WETH"))) {
                MockERC20 token = new MockERC20(name, symbol, supply);
                symbolToDeployedAsset[symbol] = address(token);
            } else {
                // On Avalanche, use WAVAX instead of WETH
                MockWETH mockWeth = new MockWETH();
                symbolToDeployedAsset[symbol] = address(mockWeth);
                weth = IWETH(address(mockWeth));
            }

            console.log(string.concat(symbol, ":"), symbolToDeployedAsset[symbol]);
        }
    }

    function _deployMockOracles() internal {
        console.log("Deploying Mock Oracles...");

        for (uint256 i = 0; i < getMockOraclesLength(); i++) {
            string memory description = getMockOracleDescription(i);
            int256 price = getMockOracleInitialPrice(i);

            MockPriceOracle oracle = new MockPriceOracle(price, description);
            symbolToDeployedOracle[description] = address(oracle);

            // Link asset to oracle
            string memory symbol = _extractSymbolFromDescription(description);
            address asset = symbolToDeployedAsset[symbol];
            if (asset != address(0)) {
                assetToOracle[asset] = address(oracle);
            }

            console.log(string.concat(description, ":"), address(oracle));
        }
    }

    function _deployYoloAssetOracles() internal {
        console.log("Deploying Yolo Asset Oracles...");

        for (uint256 i = 0; i < yoloAssetsArray.length; i++) {
            MockOracleConfig memory oracleConfig = yoloAssetsArray[i].oracleConfig;
            MockPriceOracle oracle = new MockPriceOracle(oracleConfig.initialPrice, oracleConfig.description);
            yoloAssetsArray[i].oracle = address(oracle);

            console.log(string.concat(oracleConfig.description, ":"), address(oracle));
        }
    }

    function _deployYoloProtocol(address deployer) internal {
        console.log("Deploying YOLO Protocol Core...");

        uint160 allFlags = uint160(Hooks.ALL_HOOK_MASK);

        // Deploy Hook Implementation
        bytes memory implementationConstructorArgs = abi.encode(address(POOL_MANAGER));
        (address implementationTargetAddress, bytes32 implementationSalt) =
            HookMiner.find(CREATE2_DEPLOYER, allFlags, type(YoloHook).creationCode, implementationConstructorArgs);

        yoloHookImplementation = new YoloHook{salt: implementationSalt}(address(POOL_MANAGER));
        require(address(yoloHookImplementation) == implementationTargetAddress, "Hook implementation address mismatch");

        console.log("YoloHook Implementation:", address(yoloHookImplementation));

        // Deploy Hook Proxy
        bytes memory proxyConstructorArgs = abi.encode(implementationTargetAddress, deployer, "");
        (address proxyTargetAddress, bytes32 proxySalt) = HookMiner.find(
            CREATE2_DEPLOYER, allFlags, type(PublicTransparentUpgradeableProxy).creationCode, proxyConstructorArgs
        );

        PublicTransparentUpgradeableProxy yoloHookProxyInProxy =
            new PublicTransparentUpgradeableProxy{salt: proxySalt}(address(yoloHookImplementation), deployer, "");
        yoloHookProxy = YoloHook(address(yoloHookProxyInProxy));
        require(address(yoloHookProxy) == proxyTargetAddress, "Hook proxy address mismatch");

        console.log("YoloHook Proxy:", address(yoloHookProxy));

        // Deploy YoloOracle
        address[] memory assets = new address[](getMockAssetsLength());
        address[] memory oracles = new address[](getMockAssetsLength());

        for (uint256 i = 0; i < getMockAssetsLength(); i++) {
            string memory symbol = getMockAssetSymbol(i);
            assets[i] = symbolToDeployedAsset[symbol];

            string memory description = string(abi.encodePacked(symbol, " / USD"));
            address oracleAddress = symbolToDeployedOracle[description];
            require(oracleAddress != address(0), string(abi.encodePacked("Oracle not found for ", symbol)));
            oracles[i] = oracleAddress;
        }

        yoloOracle = new YoloOracle(assets, oracles);
        console.log("YoloOracle:", address(yoloOracle));
    }

    function _initializeProtocol(address deployer) internal {
        console.log("Initializing YOLO Protocol...");

        usdc = symbolToDeployedAsset["USDC"];
        require(usdc != address(0), "USDC not deployed");

        yoloHookProxy.initialize(
            address(weth),
            deployer,
            address(yoloOracle),
            5, // 0.05% stable swap fee
            20, // 0.2% synthetic swap fee
            10, // 0.1% flash loan fee
            usdc // USDC address
        );

        usy = address(yoloHookProxy.anchor());
        console.log("USY Token:", usy);

        // Set Hook on YoloOracle
        yoloOracle.setHook(address(yoloHookProxy));
        yoloOracle.setAnchor(usy);
    }

    function _deployLogicContracts() internal {
        console.log("Deploying Logic Contracts...");

        syntheticAssetLogic = new SyntheticAssetLogic();

        console.log("SyntheticAssetLogic:", address(syntheticAssetLogic));

        yoloHookProxy.setSyntheticAssetLogic(address(syntheticAssetLogic));
    }

    function _createYoloAssets() internal {
        console.log("Creating Yolo Assets...");

        for (uint256 i = 0; i < yoloAssetsArray.length; i++) {
            address yoloAsset = yoloHookProxy.createNewYoloAsset(
                yoloAssetsArray[i].name,
                yoloAssetsArray[i].symbol,
                yoloAssetsArray[i].decimals,
                yoloAssetsArray[i].oracle
            );

            yoloAssetToAddress[yoloAssetsArray[i].symbol] = yoloAsset;
            console.log(string.concat(yoloAssetsArray[i].symbol, ":"), yoloAsset);

            yoloHookProxy.setYoloAssetConfig(
                yoloAsset,
                yoloAssetsArray[i].assetConfiguration.maxMintableCap,
                yoloAssetsArray[i].assetConfiguration.maxFlashLoanableAmount
            );
        }

        // Set convenience variables
        yJpyAsset = yoloAssetToAddress["yJPY"];
        yKrwAsset = yoloAssetToAddress["yKRW"];
        yGoldAsset = yoloAssetToAddress["yXAU"];
        yNvdaAsset = yoloAssetToAddress["yNVDA"];
        yTslaAsset = yoloAssetToAddress["yTSLA"];
    }

    function _configureCollateralsAndPairs() internal {
        console.log("Configuring Collaterals and Pairs...");

        // Register collaterals
        for (uint256 i = 0; i < collateralAssetsArray.length; i++) {
            address asset = symbolToDeployedAsset[collateralAssetsArray[i].symbol];
            require(asset != address(0), "Invalid asset address");
            address priceSource = yoloOracle.getSourceOfAsset(asset);
            require(priceSource != address(0), "Invalid price source");

            yoloHookProxy.setCollateralConfig(asset, collateralAssetsArray[i].supplyCap, priceSource);
        }

        // Set convenience variables
        wbtcAsset = symbolToDeployedAsset["WBTC"];
        ptUsdeAsset = symbolToDeployedAsset["PT-sUSDe-31JUL2025"];

        // Setup pair configurations
        address[] memory collateralAssets = new address[](2);
        collateralAssets[0] = wbtcAsset;
        collateralAssets[1] = ptUsdeAsset;

        address[] memory yoloAssets = new address[](6);
        yoloAssets[0] = usy;
        yoloAssets[1] = yJpyAsset;
        yoloAssets[2] = yKrwAsset;
        yoloAssets[3] = yGoldAsset;
        yoloAssets[4] = yNvdaAsset;
        yoloAssets[5] = yTslaAsset;

        for (uint256 i = 0; i < collateralAssets.length; i++) {
            for (uint256 j = 0; j < yoloAssets.length; j++) {
                uint256 interestRate = 500; // 5%
                uint256 ltv = i == 0 ? 8000 : 7000; // 80% for WBTC, 70% for PT-sUSDe
                uint256 liquidationPenalty = 500; // 5%

                yoloHookProxy.setPairConfig(collateralAssets[i], yoloAssets[j], interestRate, ltv, liquidationPenalty);
            }
        }
    }

    function _setupInitialState(address deployer) internal {
        console.log("Setting up Initial State...");

        // Mint USY for liquidity provision
        IERC20Metadata(wbtcAsset).approve(address(yoloHookProxy), type(uint256).max);
        yoloHookProxy.setYoloAssetConfig(usy, 10_000_000e18, 10_000_000e18);
        yoloHookProxy.borrow(usy, 1_500_000e18, wbtcAsset, 100e18);

        console.log("Minted 1.5M USY tokens using 100 WBTC as collateral");

        // Add liquidity to anchor pool
        IERC20Metadata(usy).approve(address(yoloHookProxy), type(uint256).max);
        IERC20Metadata(usdc).approve(address(yoloHookProxy), type(uint256).max);

        uint256 usdcAmount = IERC20Metadata(usdc).decimals() == 18 ? 1_000_000e18 : 1_000_000e6;
        yoloHookProxy.addLiquidity(usdcAmount, 1_000_000e18, 0, deployer);

        console.log("Added 1M USY + 1M USDC liquidity to anchor pool");
    }

    function _logDeploymentInfo() internal {
        console.log("==========================================");
        console.log("         DEPLOYMENT SUMMARY");
        console.log("==========================================");

        // Create deployment log
        string memory deploymentInfo = string.concat(
            "{\n",
            '  "network": "',
            NETWORK_NAME,
            '",\n',
            '  "chainId": "',
            vm.toString(block.chainid),
            '",\n',
            '  "timestamp": "',
            vm.toString(block.timestamp),
            '",\n',
            '  "deployer": "',
            vm.toString(vm.addr(vm.envUint("PRIVATE_KEY"))),
            '",\n',
            '  "poolManager": "',
            vm.toString(address(POOL_MANAGER)),
            '",\n',
            '  "contracts": {\n',
            '    "YoloHookImplementation": "',
            vm.toString(address(yoloHookImplementation)),
            '",\n',
            '    "YoloHookProxy": "',
            vm.toString(address(yoloHookProxy)),
            '",\n',
            '    "YoloOracle": "',
            vm.toString(address(yoloOracle)),
            '",\n',
            '    "SyntheticAssetLogic": "',
            vm.toString(address(syntheticAssetLogic)),
            '",\n',
            '    "USDC": "',
            vm.toString(usdc),
            '",\n',
            '    "USY": "',
            vm.toString(usy),
            '",\n',
            '    "WETH": "',
            vm.toString(address(weth)),
            '",\n',
            '    "WBTC": "',
            vm.toString(wbtcAsset),
            '",\n',
            '    "PT-sUSDe": "',
            vm.toString(ptUsdeAsset),
            '",\n',
            '    "yJPY": "',
            vm.toString(yJpyAsset),
            '",\n',
            '    "yKRW": "',
            vm.toString(yKrwAsset),
            '",\n',
            '    "yXAU": "',
            vm.toString(yGoldAsset),
            '",\n',
            '    "yNVDA": "',
            vm.toString(yNvdaAsset),
            '",\n',
            '    "yTSLA": "',
            vm.toString(yTslaAsset),
            '"\n',
            "  },\n",
            '  "configuration": {\n',
            '    "stableSwapFee": "0.05%",\n',
            '    "syntheticSwapFee": "0.2%",\n',
            '    "flashLoanFee": "0.1%",\n',
            '    "collateralLTV": {\n',
            '      "WBTC": "80%",\n',
            '      "PT-sUSDe": "70%"\n',
            "    },\n",
            '    "interestRate": "5%",\n',
            '    "liquidationPenalty": "5%"\n',
            "  }\n",
            "}"
        );

        // Create logs directory if it doesn't exist
        // vm.createDir("logs", true);
        // vm.createDir("logs/deployments", true);

        // vm.writeFile(DEPLOYMENT_LOG, deploymentInfo);

        console.log("Core Contracts:");
        console.log("  YoloHook Proxy:", address(yoloHookProxy));
        console.log("  YoloOracle:", address(yoloOracle));
        console.log("");
        console.log("Tokens:");
        console.log("  USDC:", usdc);
        console.log("  USY:", usy);
        console.log("  WETH/WAVAX:", address(weth));
        console.log("  WBTC:", wbtcAsset);
        console.log("");
        console.log("Synthetic Assets:");
        console.log("  yJPY:", yJpyAsset);
        console.log("  yKRW:", yKrwAsset);
        console.log("  yXAU:", yGoldAsset);
        console.log("  yNVDA:", yNvdaAsset);
        console.log("  yTSLA:", yTslaAsset);
        console.log("");
        console.log("Deployment log saved to:", DEPLOYMENT_LOG);
    }

    // Helper function to extract symbol from oracle description
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
}
