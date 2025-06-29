# YOLO Protocol Deployment Scripts

This directory contains deployment scripts for YOLO Protocol across multiple chains.

## Quick Start

```bash
# Deploy to all chains
./deploy-multichain.sh

# Or deploy individually
forge script script/Script06A_DeployBaseSepolia.s.sol --rpc-url $BASE_SEPOLIA_RPC --broadcast
```

## Deployment Scripts

### Script06 Series - Multi-Chain Deployment

- **Script06A_DeployBaseSepolia.s.sol** - Deploy to Base Sepolia testnet
- **Script06B_DeployUnichainSepolia.s.sol** - Deploy to Unichain Sepolia testnet
- **Script06C_DeployAvalancheMainnet.s.sol** - Deploy to Avalanche C-Chain mainnet ⚠️
- **Script06D_DeployInkMainnet.s.sol** - Deploy to Ink mainnet ⚠️
- **Script06E_DeployBaseSepaliaCCIPBridge.s.sol** - Deploy CCIP bridge on Base Sepolia
- **Script06F_DeployAvalancheCCIPBridge.s.sol** - Deploy CCIP bridge on Avalanche Mainnet

### Deployment Components

Each deployment includes:
- YoloHook (Implementation + Proxy)
- YoloOracle with price feeds
- Mock assets (USDC, WETH, WBTC, PT-sUSDe)
- Synthetic assets (USY, yJPY, yKRW, yXAU, yNVDA, yTSLA)
- Collateral configurations
- Initial liquidity (1M USDC + 1M USY)

### CCIP Bridge Deployment

CCIP bridges are deployed on chains that support Chainlink CCIP:
- Base Sepolia ↔ Avalanche Mainnet
- Configures bidirectional asset mappings
- Enables native cross-chain transfers for all YOLO synthetic assets

## Configuration

### Pool Manager Addresses

| Chain | Pool Manager Address | Status |
|-------|---------------------|---------|
| Base Sepolia | 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408 | ✅ Configured |
| Unichain Sepolia | 0x00b036b58a818b1bc34d502d3fe730db729e62ac | ✅ Configured |
| Avalanche Mainnet | 0x06380c0e0912312b5150364b9dc4542ba0dbbc85 | ✅ Configured |
| Ink Mainnet | 0x360e68faccca8ca495c1b759fd9eee466db9fb32 | ✅ Configured |

### CCIP Configuration

| Chain | CCIP Router | Chain Selector |
|-------|-------------|----------------|
| Base Sepolia | 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93 | 10344971235874465080 |
| Avalanche Mainnet | 0x27F39D0af3303703750D4001fCc1844c6491563c | 6433500567565415381 |

## Deployment Logs

All deployments are logged to `logs/deployments/`:
- `base-sepolia-deployment.json`
- `unichain-sepolia-deployment.json`
- `avalanche-mainnet-deployment.json`
- `ink-mainnet-deployment.json`
- `ccip-bridges-deployment.json`

## Important Notes

1. **Mainnet Deployments**: Avalanche and Ink are MAINNET deployments. Double-check all parameters.
2. **Pool Manager**: Update POOL_MANAGER addresses for Avalanche and Ink mainnet before deployment.
3. **Gas Requirements**: Ensure sufficient native tokens for deployment gas costs.
4. **CCIP Fees**: CCIP operations require LINK tokens for message fees.
5. **Rehypothecation**: Currently disabled as requested. Can be enabled post-deployment.

## Other Scripts

- **Script01_DeployTestnet.s.sol** - Original testnet deployment script
- **Script02_DeployRehypothecation.s.sol** - Deployment with rehypothecation enabled
- **Script03A-D** - CCIP testing scripts (Sepolia ↔ Arbitrum Sepolia)
- **Script04A-D** - Across Protocol testing scripts
- **Script05** - Reserved for future use

## Support

For deployment issues:
1. Check deployment logs in `logs/deployments/`
2. Verify RPC URLs in `.env`
3. Ensure sufficient gas on all chains
4. Verify Pool Manager addresses for target chains