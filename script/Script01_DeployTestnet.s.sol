// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*---------- IMPORT FOUNDRY ----------*/
import "forge-std/Script.sol";

/*---------- IMPORT CONTRACTS ----------*/
import {PublicTransparentUpgradeableProxy} from "@yolo/contracts/proxy/PublicTransparentUpgradeableProxy.sol";
import {YoloHook} from "@yolo/contracts/core/YoloHook.sol";
import {YoloOracle} from "@yolo/contracts/core/YoloOracle.sol";
import {SyntheticAssetLogic} from "@yolo/contracts/core/SyntheticAssetLogic.sol";
import {StakedYoloUSD} from "@yolo/contracts/tokenization/StakedYoloUSD.sol";
import {IPoolManager, ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IFlashBorrower} from "@yolo/contracts/interfaces/IFlashBorrower.sol";
import {IYoloSyntheticAsset} from "@yolo/contracts/interfaces/IYoloSyntheticAsset.sol";
import {MockWETH} from "@yolo/contracts/mocks/MockWETH.sol";
import {MockERC20} from "@yolo/contracts/mocks/MockERC20.sol";
import {MockPriceOracle} from "@yolo/contracts/mocks/MockPriceOracle.sol";
import {IWETH} from "@yolo/contracts/interfaces/IWETH.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager, ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PublicTransparentUpgradeableProxy} from "@yolo/contracts/proxy/PublicTransparentUpgradeableProxy.sol";

/*---------- IMPORT CONFIGS ----------*/
import {Config01_OraclesAndAssets} from "@yolo/test/config/Config01_OraclesAndAssets.sol";
import {Config02_AssetAndCollateralInitialization} from
    "@yolo/test/config/Config02_AssetAndCollateralInitialization.sol";

/*---------- IMPORT LIBRARIES ----------*/
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/**
 * @title   Script01_DeployTestnet
 * @author  0xyolodev.eth
 * @dev     This contract deploys the entire YOLO Protocol V0.5 suite for fresh deployment.
 *          Features: compound interest, expirable positions, sUSY receipt tokens.
 *          NO MIGRATION - fresh deployment only.
 */
contract Script01_DeployTestnet is Script, Config01_OraclesAndAssets, Config02_AssetAndCollateralInitialization {
    IWETH public weth;
    mapping(string => address) public symbolToDeployedAsset;
    mapping(string => address) public symbolToDeployedOracle;
    mapping(address => address) public assetToOracle;
    mapping(address => bool) public matchedOracle;

    YoloHook public yoloHookImplementation;
    YoloHook public yoloHookProxy;
    YoloOracle public yoloOracle;
    SyntheticAssetLogic public syntheticAssetLogic;
    StakedYoloUSD public sUSY;

    mapping(string => address) yoloAssetToAddress;

    IPoolManager POOL_MANAGER = IPoolManager(0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32);

    // For convenience
    address public yJpyAsset; // Yolo Asset
    address public yKrwAsset; // Yolo Asset
    address public yGoldAsset; // Yolo Asset
    address public yNvdaAsset; // Yolo Asset
    address public yTslaAsset; // Yolo Asset
    address public wbtcAsset; // Collateral
    address public ptUsdeAsset; // Collateral

    address public usy;

    function run() external {
        // A. Load env variables
        string memory rpcUrl = vm.envString("RPC_URL");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        uint256 forkId = vm.createFork(rpcUrl);
        console.log("Deployer: ", deployer);
        vm.selectFork(forkId);

        // B. Broadcast deployment tx using private key
        vm.startBroadcast(deployerKey);

        // C. Deploy Mock Oracles & Mock Assets

        // C-1. Deploy Mock Assets based on the configuration
        for (uint256 i = 0; i < getMockAssetsLength(); i++) {
            string memory name = getMockAssetName(i);
            string memory symbol = getMockAssetSymbol(i);
            uint256 supply = getMockAssetInitialSupply(i);

            if (keccak256(abi.encodePacked(symbol)) != keccak256(abi.encodePacked("WETH"))) {
                MockERC20 token = new MockERC20(name, symbol, supply);
                symbolToDeployedAsset[symbol] = address(token);
                // _writeAddressToFile(symbol, address(token));
                _logContractAddress(symbol, address(token));
            } else {
                MockWETH mockWeth = new MockWETH();
                symbolToDeployedAsset[symbol] = address(mockWeth);
                weth = IWETH(address(mockWeth));
                // _writeAddressToFile(symbol, address(mockWeth));
                _logContractAddress(symbol, address(mockWeth));
            }
        }

        // C-2. Deploy Mock Oracles based on the configuration
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

            _logContractAddress(description, address(oracle));
        }

        // C-3. Deploy Yolo Assets' oracles from Config02
        for (uint256 i = 0; i < yoloAssetsArray.length; i++) {
            // 2A. Deploy MockOracles
            MockOracleConfig memory oracleConfig = yoloAssetsArray[i].oracleConfig;
            MockPriceOracle oracle = new MockPriceOracle(oracleConfig.initialPrice, oracleConfig.description);
            yoloAssetsArray[i].oracle = address(oracle);

            _logContractAddress(oracleConfig.description, address(oracle));
        }

        // D. Deploy YOLO Protocol's Implementation & Proxy
        uint160 allFlags = uint160(Hooks.ALL_HOOK_MASK);

        address CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

        // D-1. Compute Hook Implementation Salt

        bytes memory implementationConstructorArgs = abi.encode(address(POOL_MANAGER));
        (address implementationTargetAddress, bytes32 implementationSalt) =
            HookMiner.find(CREATE2_DEPLOYER, allFlags, type(YoloHook).creationCode, implementationConstructorArgs);

        yoloHookImplementation = new YoloHook{salt: implementationSalt}(address(POOL_MANAGER));
        require(
            address(yoloHookImplementation) == implementationTargetAddress,
            "Script01_DeployTestnet: hook implementation address mismatch"
        );

        console.log("Calculated Implementation Address: ", implementationTargetAddress);
        console.log("Calculated Implementation Salt: ");
        console.logBytes(abi.encodePacked(implementationSalt));
        console.log("Calculated Implementation Address Binary Form: ");
        _logAddressAsBinary(implementationTargetAddress);

        // D-2. Compute Hook Proxy Salt

        bytes memory proxyConstructorArgs = abi.encode(implementationTargetAddress, deployer, "");
        (address proxyTargetAddress, bytes32 proxySalt) = HookMiner.find(
            CREATE2_DEPLOYER, allFlags, type(PublicTransparentUpgradeableProxy).creationCode, proxyConstructorArgs
        );
        console.log("Calculated Proxy Address: ", proxyTargetAddress);
        console.log("Calculated Proxy Salt: ");
        console.logBytes(abi.encodePacked(proxySalt));
        console.log("Calculated Proxy Address Binary Form: ");
        _logAddressAsBinary(proxyTargetAddress);

        // D-3. Deploy implementation & proxy to target addresses using CREATE2
        yoloHookImplementation = new YoloHook{salt: implementationSalt}(address(POOL_MANAGER));
        require(
            address(yoloHookImplementation) == implementationTargetAddress,
            "Script01_DeployTestnet: hook implementation address mismatch"
        );
        _logContractAddress("YoloHookImplementation: ", address(yoloHookImplementation));

        PublicTransparentUpgradeableProxy yoloHookProxyInProxy;
        yoloHookProxyInProxy =
            new PublicTransparentUpgradeableProxy{salt: proxySalt}(address(yoloHookImplementation), deployer, "");
        yoloHookProxy = YoloHook(address(yoloHookProxyInProxy));
        require(address(yoloHookProxy) == proxyTargetAddress, "Script01_DeployTestnet: hook proxy address mismatch");
        _logContractAddress("YoloHookProxy: ", address(yoloHookProxy));

        // E. Deploy YoloOracle
        // E-1. Extract the deployed assets and oracles from the base contract

        address[] memory assets = new address[](getMockAssetsLength());
        address[] memory oracles = new address[](getMockAssetsLength());

        for (uint256 i = 0; i < getMockAssetsLength(); i++) {
            string memory symbol = getMockAssetSymbol(i);
            assets[i] = symbolToDeployedAsset[symbol];

            string memory description = string(abi.encodePacked(symbol, " / USD"));
            // console.log("Description: ", description);
            address oracleAddress = symbolToDeployedOracle[description];
            // console.log("Oracle Address: ", oracleAddress);
            require(oracleAddress != address(0), string(abi.encodePacked("Oracle not found for ", symbol)));
            oracles[i] = oracleAddress;

            console.log(string(abi.encodePacked("Linked Oracle for Asset: ", symbol)), oracleAddress);
        }

        // E-2/ Deploy the YoloOracle contract
        yoloOracle = new YoloOracle(assets, oracles);
        _logContractAddress("YoloOracle: ", address(yoloOracle));

        // E-3. Deploy SyntheticAssetLogic delegate contract
        syntheticAssetLogic = new SyntheticAssetLogic();
        _logContractAddress("SyntheticAssetLogic: ", address(syntheticAssetLogic));
        console.log("YoloHook Implementation Owner Is: ", yoloHookImplementation.owner());
        console.log("YoloHook Proxy Before Initializa Owner Is: ", yoloHookProxy.owner());

        // F. Initialize the YoloHook proxy contract
        yoloHookProxy.initialize(
            address(weth),
            deployer,
            address(yoloOracle),
            5, // 0.05% stable swap fee
            20, // 0.2% synthetic swap fee
            10, // 0.1% flash loan fee
            symbolToDeployedAsset["USDC"] // USDC address
        );
        console.log("YoloHook Proxy Owner After Initialize Is: ", yoloHookProxy.owner());

        // F-2. Set SyntheticAssetLogic delegate contract
        yoloHookProxy.setSyntheticAssetLogic(address(syntheticAssetLogic));
        console.log("SyntheticAssetLogic set on YoloHook");

        usy = address(yoloHookProxy.anchor());

        // F-3. Deploy and set sUSY token
        sUSY = new StakedYoloUSD(address(yoloHookProxy));
        _logContractAddress("StakedYoloUSD (sUSY): ", address(sUSY));
        yoloHookProxy.setSUSYToken(address(sUSY));
        console.log("sUSY token deployed and set on YoloHook");

        // G. Set Hook on YoloOracle
        yoloOracle.setHook(address(yoloHookProxy));
        yoloOracle.setAnchor(address(yoloHookProxy.anchor()));

        // H. Create All Yolo Assets
        for (uint256 i = 0; i < yoloAssetsArray.length; i++) {
            // H-1. Create New Yolo Assets
            address yoloAsset = yoloHookProxy.createNewYoloAsset(
                yoloAssetsArray[i].name,
                yoloAssetsArray[i].symbol,
                yoloAssetsArray[i].decimals,
                yoloAssetsArray[i].oracle
            );

            yoloAssetToAddress[yoloAssetsArray[i].symbol] = yoloAsset;

            console.log(yoloAssetsArray[i].symbol, ":", yoloAsset);

            // H-2. Configure Yolo Assets
            yoloHookProxy.setYoloAssetConfig(
                yoloAsset,
                yoloAssetsArray[i].assetConfiguration.maxMintableCap,
                yoloAssetsArray[i].assetConfiguration.maxFlashLoanableAmount
            );
        }

        // I. Register and whitelist all collaterals
        for (uint256 i = 0; i < collateralAssetsArray.length; i++) {
            address asset = symbolToDeployedAsset[collateralAssetsArray[i].symbol];
            require(asset != address(0), "Invalid asset address");
            address priceSource = yoloOracle.getSourceOfAsset(asset);
            require(priceSource != address(0), "Invalid price source");

            // setCollateralConfig()
            yoloHookProxy.setCollateralConfig(asset, collateralAssetsArray[i].supplyCap, priceSource);
        }

        // J. Set convenience variables
        yJpyAsset = yoloAssetToAddress["yJPY"];
        yKrwAsset = yoloAssetToAddress["yKRW"];
        yGoldAsset = yoloAssetToAddress["yXAU"];
        yNvdaAsset = yoloAssetToAddress["yNVDA"];
        yTslaAsset = yoloAssetToAddress["yTSLA"];
        wbtcAsset = symbolToDeployedAsset["WBTC"];
        ptUsdeAsset = symbolToDeployedAsset["PT-sUSDe-31JUL2025"];

        // H. Quick setup pair configs for testings
        address[] memory collateralAssets = new address[](2);
        collateralAssets[0] = wbtcAsset;
        collateralAssets[1] = ptUsdeAsset;

        address[] memory yoloAssets = new address[](6);
        yoloAssets[0] = address(yoloHookProxy.anchor()); // USY
        yoloAssets[1] = yJpyAsset;
        yoloAssets[2] = yKrwAsset;
        yoloAssets[3] = yGoldAsset;
        yoloAssets[4] = yNvdaAsset;
        yoloAssets[5] = yTslaAsset;

        // Quickly Setup PairConfigs
        for (uint256 i = 0; i < collateralAssets.length; i++) {
            for (uint256 j = 0; j < yoloAssets.length; j++) {
                uint256 interestRate = 500; // 5%
                uint256 ltv = i == 0 ? 8000 : 7000; // 80% or 70%
                uint256 liquidationPenalty = 500; // 5%

                yoloHookProxy.setPairConfig(collateralAssets[i], yoloAssets[j], interestRate, ltv, liquidationPenalty);
            }
        }

        console.log("Successfully Setup Pair Configurations");

        // I-2. Configure expiration for yield-bearing collaterals (e.g., PT-sUSDe)
        // Make PT-sUSDe positions expirable with 6 month expiry
        for (uint256 j = 0; j < yoloAssets.length; j++) {
            yoloHookProxy.setExpirationConfig(
                ptUsdeAsset, // PT-sUSDe as expirable collateral
                yoloAssets[j], // All yolo assets
                true, // isExpirable = true
                180 days // 6 months expiry period
            );
        }
        console.log("Successfully Setup Expiration Configurations for PT-sUSDe");

        // I. Mint Sufficient USY for further use
        // Deplosit 100 WBTC and mint 1_000_000 USY
        IERC20Metadata(wbtcAsset).approve(address(yoloHookProxy), type(uint256).max);
        yoloHookProxy.setYoloAssetConfig(address(yoloHookProxy.anchor()), 10_000_000e18, 10_000_000e18);
        yoloHookProxy.borrow(address(yoloHookProxy.anchor()), 1_500_000e18, wbtcAsset, 100e18);
        console.log("USY Balance of Deployer: ", IERC20Metadata(address(yoloHookProxy.anchor())).balanceOf(deployer));

        // K. Add Liquidity to Anchor Pool (this will mint sUSY tokens)
        usy = address(yoloHookProxy.anchor());
        address usdc = symbolToDeployedAsset["USDC"];

        IERC20Metadata(usy).approve(address(yoloHookProxy), type(uint256).max);
        IERC20Metadata(usdc).approve(address(yoloHookProxy), type(uint256).max);
        yoloHookProxy.addLiquidity(1_000_000e18, 1_000_000e18, 0, deployer);

        console.log("Successfully Added Liquidity on Anchor Pool!");
        console.log("sUSY Balance of Deployer: ", sUSY.balanceOf(deployer));
        console.log("sUSY Exchange Rate: ", sUSY.getExchangeRate());
    }
    // ********************************* //
    // *** INTERNAL HELPER FUNCTIONS *** //
    // ********************************* //

    function _writeAddressToFile(string memory name, address addr) internal {
        string memory path = string.concat("logs/", name, ".address");
        vm.writeFile(path, vm.toString(addr));
    }

    function _logContractAddress(string memory name, address addr) internal {
        console.log(name, ": ", addr);
    }

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

    function _logAddressAsBinary(address _addr) public {
        bytes20 b = bytes20(_addr);
        bytes memory out = new bytes(160); // 20 bytes * 8 bits

        for (uint256 i = 0; i < 20; i++) {
            uint8 byteVal = uint8(b[i]);
            for (uint256 j = 0; j < 8; j++) {
                out[i * 8 + (7 - j)] = (byteVal & (1 << j)) != 0 ? bytes1("1") : bytes1("0");
            }
        }

        console.log(string(out));
    }
}
