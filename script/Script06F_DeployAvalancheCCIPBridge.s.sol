// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*---------- IMPORT FOUNDRY ----------*/
import "forge-std/Script.sol";

/*---------- IMPORT CONTRACTS ----------*/
import {YoloCCIPBridge} from "@yolo/contracts/cross-chain/YoloCCIPBridge.sol";

/**
 * @title   Script06F_DeployAvalancheCCIPBridge
 * @author  0xyolodev.eth
 * @dev     Deploy and configure CCIP bridge on Avalanche Mainnet
 */
contract Script06F_DeployAvalancheCCIPBridge is Script {
    // Network configuration
    string constant NETWORK_NAME = "avalanche-mainnet";
    uint64 constant AVALANCHE_MAINNET_CHAIN_SELECTOR = 6433500567565415381;
    uint64 constant BASE_SEPOLIA_CHAIN_SELECTOR = 10344971235874465080;
    address constant AVALANCHE_MAINNET_ROUTER = 0x27F39D0af3303703750D4001fCc1844c6491563c;
    address constant YOLO_HOOK_PROXY = 0x3Ea806c10F85fB809812B2422d7C4b994E1CFffF;

    // Asset addresses on Avalanche Mainnet
    address constant USY_AVAX = 0x7cf2eEB65083D18325e957927Ff93B772243ef91;
    address constant YJPY_AVAX = 0x6Cf1c00c0fE85e63bf8068f77a72a8e264ef8F09;
    address constant YKRW_AVAX = 0xFa0337dB79F1a02Ce1C438c90D091749B95181Dd;
    address constant YXAU_AVAX = 0xD38A68510CB16da21455304905f2C1Ef4C0DC2B6;
    address constant YNVDA_AVAX = 0xe6F11C405Eed9a1073e93C4031b81b5389E95F4B;
    address constant YTSLA_AVAX = 0x56cC676F58e3fd7e8b1E5E9195E35Bbf7cAda6d5;

    // Asset addresses on Base Sepolia
    address constant USY_BASE = 0x5FF62705aA2F6dEAe0F8f3a771298440124A9988;
    address constant YJPY_BASE = 0x67Bb3cc52448866CD7743efF45823f30d344b1D6;
    address constant YKRW_BASE = 0x0dbe9B2A4A428d514e6D45817Ec05E5738b89530;
    address constant YXAU_BASE = 0x1091392b50De97065c829d749cad8B6e2f129dc3;
    address constant YNVDA_BASE = 0xaf1034de923559E1AF90B67ac9c4f84A4EcEff1a;
    address constant YTSLA_BASE = 0xd74688447440407e926A98e9311Bde7190a7B437;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console.log("==========================================");
        console.log("    AVALANCHE MAINNET CCIP BRIDGE DEPLOYMENT");
        console.log("==========================================");
        console.log("Deployer:", deployer);
        console.log("Network:", NETWORK_NAME);
        console.log("==========================================");

        vm.startBroadcast(deployerKey);

        // Deploy CCIP Bridge
        YoloCCIPBridge bridge = new YoloCCIPBridge(
            AVALANCHE_MAINNET_ROUTER,
            YOLO_HOOK_PROXY,
            AVALANCHE_MAINNET_CHAIN_SELECTOR
        );

        console.log("CCIP Bridge deployed at:", address(bridge));

        // Configure supported chain
        bridge.setSupportedChain(BASE_SEPOLIA_CHAIN_SELECTOR, true);
        console.log("Added support for Base Sepolia");

        // Configure asset mappings to Base Sepolia
        _configureAssetMapping(bridge, USY_AVAX, USY_BASE, "USY");
        _configureAssetMapping(bridge, YJPY_AVAX, YJPY_BASE, "yJPY");
        _configureAssetMapping(bridge, YKRW_AVAX, YKRW_BASE, "yKRW");
        _configureAssetMapping(bridge, YXAU_AVAX, YXAU_BASE, "yXAU");
        _configureAssetMapping(bridge, YNVDA_AVAX, YNVDA_BASE, "yNVDA");
        _configureAssetMapping(bridge, YTSLA_AVAX, YTSLA_BASE, "yTSLA");

        vm.stopBroadcast();

        console.log("==========================================");
        console.log("    DEPLOYMENT COMPLETED SUCCESSFULLY");
        console.log("==========================================");
        console.log("Bridge Address:", address(bridge));
        console.log("Target Chain: Base Sepolia");
        console.log("Assets Mapped: 6 (USY, yJPY, yKRW, yXAU, yNVDA, yTSLA)");
    }

    function _configureAssetMapping(
        YoloCCIPBridge bridge,
        address localAsset,
        address remoteAsset,
        string memory symbol
    ) internal {
        bridge.setAssetMapping(BASE_SEPOLIA_CHAIN_SELECTOR, localAsset, remoteAsset);
        console.log(string.concat("Mapped ", symbol, ": ", vm.toString(localAsset), " -> ", vm.toString(remoteAsset)));
    }
}