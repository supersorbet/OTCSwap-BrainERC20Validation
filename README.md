# 🧠 BasedBrains OTC Swap Escrow

> **A gas-optimized Over-The-Counter (OTC) swap system for ERC20s, with added BrainERC20 validation (OPTIONAL). This contract and lib was deployed and mildly used on mainnet, but is now paused until further notice (unrelated issues, nothing to do with the contract. still fully usable)**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-^0.8.26-blue.svg)](https://docs.soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Framework-Foundry-red.svg)](https://getfoundry.sh/)

---

- **🎯 Validated Trades**: Support for "Brain tokens" from the BasedAI Brains NFTs
- **⚡ Optimized**: Bitmap-based storage, ~80% reduction in tracking operations
- **🔄 Upgradeable**: UUPS- simply remove the UUPS logic/libs and use a base contstructor instead of initializer.
- **📊 Market Analytics**: Price discovery and token market data aggregation

---

## 🏗️ **Architecture**

### Core

| Contract | Description | Purpose |
|----------|-------------|---------|
| **`OTCEscrowV1point2.sol`** | Main escrow contract | Handles swap creation, execution, and state management |
| **`xUUPSSwapLib.sol`** | Market analysis lib | Price discovery & token analytics |

### Key Features

- **🎨 Dual Token Types**: Support for both "Brain tokens" (fee-free) and regular ERC20s (w/ configurable fees)
- **⏰ Time-Limited Orders**: Automatic expiration system prevents stale orders
- **📈  Analytics**: Real-time market data including best bid/ask prices and volume tracking
- **🔄 Batch Operations**: Efficient bulk processing for token validation

---

## 💡 **How It Works**

### 1. **Swap Creation**
```solidity
/// User creates a swap offer
uint256 swapId = escrow.createSwap(
    tokenA,      /// Token being offered
    amountA,     /// Amount being offered  
    tokenB,      /// Token being requested
    amountB,     /// Amount being requested
    expiration   /// When offer expires
);
```

### 2. **Swap Acceptance**
```solidity
/// Another user accepts the swap
escrow.acceptSwap(swapId);
/// Tokens automatically exchanged
```

### 3. **Analytics**
```solidity
/// Get realtime market data for any token
(uint256 buyCount, uint256 sellCount, uint256 lowestSell, 
 uint256 highestBuy, uint256 totalVolume) = 
    escrow.getTokenMarketData(tokenAddress);
```

---

##  📊 **Advanced Features**

### Fee Structure
- **Regular Tokens**: Configurable fee rate (default: 0.69%)
- **Dynamic Treasury**: Fees support continued devving
---

## 🛠️ **Dev Setup**

### Prerequisites
- [Foundry](https://getfoundry.sh/) installed
- Node.js 16+ (for additional tooling)
- Git

### Installation
```bash
git clone <repository-url>
cd codeslaw-ethereum-otc-swap
forge install
```

### Compile Contracts
```bash
forge build
```

### Run Tests
```bash
forge test
forge test -vvv  # Verbose output
```

### Gas Analysis
```bash
forge test --gas-report
```

---

## 📁 **Project Structure**

```
├── contracts/           # 📜 Main contracts (more visible)
│   ├── OTCEscrowV1point2.sol
│   └── xUUPSSwapLib.sol
├── src/                # 🔧 Foundry source (for compilation)
├── test/               # 🧪 Comprehensive test suite
├── script/             # 📝 Deployment and management scripts
├── docs/               # 📚 Additional documentation
├── lib/                # 📦 Dependencies (Solady, Forge-std)
└── foundry.toml        # ⚙️ Foundry configuration
```

---

## 🎯 **Use Cases**

### DeFi Applications
- **OTC Trading Desks**: Large volume trades without slippage
- **Token Launches**: Fair price discovery for new tokens
- **Arb**: Cross-exchange price differences
- **Portfolio Rebalancing**: Efficient asset swapping
---

## 🔧 **Configuration**

### Environment Variables
```bash
# .env file
MAINNET_RPC_URL=your_mainnet_rpc
SEPOLIA_RPC_URL=your_sepolia_rpc  
PRIVATE_KEY=your_private_key
ETHERSCAN_API_KEY=your_etherscan_key
```

### Foundry Config
The project uses optimized compiler settings:
- Solidity 0.8.26
- 1337 optimizer runs
- Via-IR

---
