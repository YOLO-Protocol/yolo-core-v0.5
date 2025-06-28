# YOLO Protocol V0

```___  _ ____  _     ____    ____  ____  ____  _____  ____  ____  ____  _    
\  \///  _ \/ \   /  _ \  /  __\/  __\/  _ \/__ __\/  _ \/   _\/  _ \/ \   
 \  / | / \|| |   | / \|  |  \/||  \/|| / \|  / \  | / \||  /  | / \|| |   
 / /  | \_/|| |_/\| \_/|  |  __/|    /| \_/|  | |  | \_/||  \__| \_/|| |_/\
/_/   \____/\____/\____/  \_/   \_/\_\\____/  \_/  \____/\____/\____/\____/
                                                                           
```

This repository contains the core smart contracts for Yolo Protocol V0.

## Project Background

Yolo Protocol V0 is the extension and continuity of our Hackhathon Project: 
- [Hackathon Devfolio](https://devfolio.co/projects/yolo-protocol-univ-hook-b899):
- [Hackathon Github](https://github.com/alvinyap510/hackathon-yolo-protocol-hook):

### Hackathon Winning
- We managed to win First Prize in Base Batch #001 Hackathon's DeFi Track - [Winning Announcement](https://x.com/base/status/1930340248086831484?s=46&t=z7o3TezWDqEiMiQE-Q3QPQ)


### Incubator Placement
- We are currently part of the [Uniswap V4 Hook Incubator - Cohort UHI5](https://atrium.academy/uniswap), where we are evolving the protocol beyond its MVP into a <b>production-ready modular DeFi infrastructure</b>.
- We are also currently an incubatee of [Incubase - an incubator joint ventured between Base & Hashed Emergence](https://x.com/HashedEM/status/1928437083841888411)

## What is YOLO Protocol?

YOLO Protocol is a modular DeFi engine built on top of Uniswap V4, combining core features of multiple blue-chip protocols — all within a single Uniswap V4 Hook:

    - 🏦 MakerDAO/Abracadabra-like
      - An overcollateralized stablecoin YOLO USD (USY) backed by yield-bearing tokens(YBTs)
  
    - ⚖️ Synthetix-style
      - Synthetic assets (currencies, shares, commodities) minting & swapping within Uniswap itself, without the need of any prior liquidity

    - ⚙️ Gearbox-style
      - Execute permissionless leverage of up to 20x on YBT positions (PT-sUSDe vs USY) with low liquidation risk

Since YOLO Protocol has the ability to create synthetic assets on-chain, future iteration we plan to expand it into an <b>on-chain CFD-like experience trading platform</b> utilizing the aforementioned core features of YOLO Protocol's Hook. 
  > (<b>Think about an on-chain eToro / Plus500 / IG.com, where you can execute on-chain 20x leverage by collateralizing USY, and being liquidated promptly</b>)

## How to run

### 1. Make sure you have git, foundry and pnpm installed

### 2. Git clone this repo to your local directory
```
git clone git@github.com:YOLO-Protocol/yolo-core-v0.git
cd yolo-core-v0
```

### 3. Install dependencies
```
forge install
pnpm install
```

### 4. Run the tests
```
forge test
```

## What You Can Do

### Development Commands

```bash
# Build the contracts
forge build

# Run all tests
forge test

# Run tests with detailed output
forge test -vvv

# Run specific test
forge test --match-test testAddLiquidity

# Check contract sizes
forge build --sizes

# Format code
forge fmt

# Generate gas report
forge test --gas-report

# Run static analysis
forge analyze
```

### Deployment

```bash
# Create .env file with your RPC_URL and PRIVATE_KEY
cp .env.example .env

# Deploy to testnet
forge script script/Script01_DeployTestnet.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast

# Verify contracts (after deployment)
forge verify-contract <CONTRACT_ADDRESS> <CONTRACT_NAME> --rpc-url $RPC_URL
```

### Testing & Development

- **Run comprehensive test suite**: 22 test cases covering liquidity, swaps, borrowing, liquidations, and flash loans
- **Test individual components**: Use `--match-test` to run specific functionality tests
- **Gas optimization**: Analyze gas usage with `--gas-report` flag
- **Contract size monitoring**: Check size limits with `--sizes` flag

### Key Features to Explore

1. **Liquidity Management**: Add/remove liquidity to USDC/USY anchor pool
2. **Synthetic Asset Trading**: Swap synthetic assets without prior liquidity
3. **Collateralized Borrowing**: Deposit collateral and borrow against it
4. **Flash Loans**: Utilize instant liquidity for arbitrage and liquidations
5. **Interest Accrual**: Time-based compound interest on borrowed positions
6. **Liquidation System**: Oracle-triggered liquidations with penalties

### Project Structure

- `src/core/` - Main protocol contracts (YoloHook, YoloOracle)
- `src/libraries/` - Mathematical libraries (StableMath, FullMath)
- `src/interfaces/` - Contract interfaces
- `test/` - Comprehensive test suite
- `script/` - Deployment and utility scripts

## Resources
- [Uniswap V4 Docs](https://docs.uniswap.org/contracts/v4/overview)