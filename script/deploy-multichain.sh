#!/bin/bash

# YOLO Protocol Multi-Chain Deployment Script
# This script deploys YOLO Protocol across multiple chains

set -e  # Exit on any error

echo "=========================================="
echo "    YOLO PROTOCOL MULTI-CHAIN DEPLOYMENT"
echo "=========================================="

# Check if .env file exists
if [ ! -f .env ]; then
    echo "Error: .env file not found!"
    echo "Please create a .env file with the following variables:"
    echo "  PRIVATE_KEY=<your-private-key>"
    echo "  BASE_SEPOLIA_RPC=<base-sepolia-rpc>"
    echo "  UNICHAIN_SEPOLIA_RPC=<unichain-sepolia-rpc>"
    echo "  AVAX_MAINNET_RPC=<avalanche-mainnet-rpc>"
    echo "  INK_MAINNET_RPC=<ink-mainnet-rpc>"
    exit 1
fi

# Load environment variables
source .env

# Create logs directory
mkdir -p logs/deployments

# Function to deploy to a specific chain
deploy_chain() {
    local script_name=$1
    local chain_name=$2
    local rpc_url=$3
    
    echo ""
    echo "=========================================="
    echo "Deploying to $chain_name..."
    echo "=========================================="
    
    if [ -z "$rpc_url" ]; then
        echo "Warning: RPC URL for $chain_name not found in .env"
        echo "Skipping $chain_name deployment"
        return 1
    fi
    
    # Run the deployment script
    forge script script/$script_name --rpc-url $rpc_url --broadcast --verify
    
    if [ $? -eq 0 ]; then
        echo "✅ $chain_name deployment successful!"
    else
        echo "❌ $chain_name deployment failed!"
        return 1
    fi
}

# Deploy to each chain
echo ""
echo "Phase 1: Deploying YOLO Protocol to all chains..."

# Base Sepolia (Testnet)
if [ ! -z "$BASE_SEPOLIA_RPC" ]; then
    deploy_chain "Script06A_DeployBaseSepolia.s.sol:Script06A_DeployBaseSepolia" "Base Sepolia" "$BASE_SEPOLIA_RPC"
else
    echo "Skipping Base Sepolia - RPC URL not configured"
fi

# Unichain Sepolia (Testnet)
if [ ! -z "$UNICHAIN_SEPOLIA_RPC" ]; then
    deploy_chain "Script06B_DeployUnichainSepolia.s.sol:Script06B_DeployUnichainSepolia" "Unichain Sepolia" "$UNICHAIN_SEPOLIA_RPC"
else
    echo "Skipping Unichain Sepolia - RPC URL not configured"
fi

# Avalanche Mainnet
if [ ! -z "$AVAX_MAINNET_RPC" ]; then
    echo ""
    echo "⚠️  WARNING: Avalanche Mainnet deployment - Please confirm"
    read -p "Deploy to Avalanche MAINNET? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        deploy_chain "Script06C_DeployAvalancheMainnet.s.sol:Script06C_DeployAvalancheMainnet" "Avalanche Mainnet" "$AVAX_MAINNET_RPC"
    else
        echo "Skipping Avalanche Mainnet deployment"
    fi
else
    echo "Skipping Avalanche Mainnet - RPC URL not configured"
fi

# Ink Mainnet
if [ ! -z "$INK_MAINNET_RPC" ]; then
    echo ""
    echo "⚠️  WARNING: Ink Mainnet deployment - Please confirm"
    read -p "Deploy to Ink MAINNET? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        deploy_chain "Script06D_DeployInkMainnet.s.sol:Script06D_DeployInkMainnet" "Ink Mainnet" "$INK_MAINNET_RPC"
    else
        echo "Skipping Ink Mainnet deployment"
    fi
else
    echo "Skipping Ink Mainnet - RPC URL not configured"
fi

echo ""
echo "Phase 2: Deploying CCIP Bridges..."

# Deploy CCIP bridges (only on supported chains)
if [ ! -z "$BASE_SEPOLIA_RPC" ] && [ ! -z "$AVAX_MAINNET_RPC" ]; then
    echo ""
    echo "Deploying CCIP bridges between Base Sepolia and Avalanche Mainnet..."
    
    # Deploy Base Sepolia CCIP Bridge
    echo "Deploying Base Sepolia CCIP Bridge..."
    forge script script/Script06E_DeployBaseSepaliaCCIPBridge.s.sol:Script06E_DeployBaseSepaliaCCIPBridge --rpc-url $BASE_SEPOLIA_RPC --broadcast
    
    if [ $? -eq 0 ]; then
        echo "✅ Base Sepolia CCIP bridge deployment successful!"
        
        # Deploy Avalanche Mainnet CCIP Bridge
        echo "Deploying Avalanche Mainnet CCIP Bridge..."
        forge script script/Script06F_DeployAvalancheCCIPBridge.s.sol:Script06F_DeployAvalancheCCIPBridge --rpc-url $AVAX_MAINNET_RPC --broadcast
        
        if [ $? -eq 0 ]; then
            echo "✅ Avalanche Mainnet CCIP bridge deployment successful!"
        else
            echo "❌ Avalanche Mainnet CCIP bridge deployment failed!"
        fi
    else
        echo "❌ Base Sepolia CCIP bridge deployment failed!"
    fi
else
    echo "Skipping CCIP bridge deployment - requires both Base Sepolia and Avalanche Mainnet RPC URLs"
fi

echo ""
echo "=========================================="
echo "    DEPLOYMENT SUMMARY"
echo "=========================================="
echo ""
echo "Deployment logs saved to: logs/deployments/"
echo ""
echo "Please check the following files for deployment details:"
echo "  - logs/deployments/base-sepolia-deployment.json"
echo "  - logs/deployments/unichain-sepolia-deployment.json"
echo "  - logs/deployments/avalanche-mainnet-deployment.json"
echo "  - logs/deployments/ink-mainnet-deployment.json"
echo "  - logs/deployments/ccip-bridges-deployment.json"
echo ""
echo "=========================================="
echo "    DEPLOYMENT COMPLETE"
echo "=========================================="