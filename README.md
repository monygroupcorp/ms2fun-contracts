# ms2fun-contracts

Foundry-based Solidity contracts for the ms2.fun protocol — a multi-project launchpad ecosystem supporting ERC404 and ERC1155 token standards with integrated vault-based fee distribution and alignment incentives.

## Overview

The ms2.fun protocol features:

- **Master Registry**: Central indexing of factories, instances, and vaults with governance voting
- **Global Messaging System**: Protocol-wide activity tracking enabling single-RPC discovery of trending projects
  - Centralized on-chain message registry capturing all buys, mints, and user messages
  - Optimized bit-packing (176/256 bits) for gas efficiency
  - Auto-authorization of instances via MasterRegistry
  - Query protocol-wide activity or filter by specific projects
- **ERC404 Bonding Factory**: Creates ERC404 instances with V4 hook integration for swap tax collection
- **ERC1155 Factory**: Creates open-edition instances with enforced vault tithe (20% on creator withdraw)
- **UltraAlignmentVault**: Share-based fee hub receiving ETH from all projects, accumulating in dragnet, batch-converting to target token → V4 LP positions with O(1) fee claims
  - Contributions from direct transfers, V4 hooks (with project attribution), and ERC1155 tithes
  - Anyone can trigger conversion (incentivized with small reward)
  - Share issuance proportional to contribution: `shares = (contribution / totalPending) × liquidityUnitsAdded`
  - Delta-based fee claims support multiple claims per benefactor
- **V4 Hook Integration**: Swap taxes routed to vault with source project attribution via `receiveHookTax()`
- **Share-Based Accounting**: Elegant alternative to epoch-based tracking (O(1) claims, unlimited scalability)

## Repository Structure

```
ms2fun-contracts/
├── src/
│   ├── master/              # Master registry contracts
│   ├── registry/            # Global message registry
│   ├── libraries/           # Shared libraries (message packing, types)
│   ├── factories/           # Factory contracts (ERC404, ERC1155)
│   ├── governance/          # Governance contracts
│   ├── vaults/              # Vault contracts
│   └── shared/              # Shared interfaces and libraries
├── test/                    # Test files
├── script/                  # Deployment scripts
└── docs/                    # Documentation
```

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js (for some tooling)

### Installation

```bash
# Clone the repository
git clone <repository-url>
cd ms2fun-contracts

# Install dependencies (already included via forge install)
forge install
```

### Build

```bash
forge build
```

### Test

```bash
forge test
```

### Deploy

```bash
# Set environment variables
export PRIVATE_KEY=your_private_key
export EXEC_TOKEN=0x...

# Deploy master registry
forge script script/DeployMaster.s.sol:DeployMaster --rpc-url <rpc_url> --broadcast

# Deploy factories
forge script script/DeployERC404Factory.s.sol:DeployERC404Factory --rpc-url <rpc_url> --broadcast
```

## Core Contracts

### Master Registry (`src/master/`)
Central indexing and governance:
- `MasterRegistry.sol` - ERC1967 proxy wrapper for registry implementation
- Factory application voting system
- Instance and vault registration tracking
- Multi-factory support
- Auto-authorization of instances for global messaging

### Global Messaging System (`src/registry/`)
Protocol-wide activity tracking and discovery:
- `GlobalMessageRegistry.sol` - Centralized on-chain message storage
  - **Single-RPC Discovery**: Query all protocol activity in one call
  - **Auto-Authorization**: Instances authorized on registration via MasterRegistry
  - **Optimized Storage**: 176-bit packed metadata (timestamp, factory type, action, context, amount)
  - **Flexible Queries**: Protocol-wide, instance-specific, or paginated results
  - **Activity Types**: BUY, SELL, MINT, WITHDRAW, STAKE, UNSTAKE, CLAIM_REWARDS, DEPLOY_LIQUIDITY
- `GlobalMessagePacking.sol` - Bit-packing library for efficient metadata storage
- `GlobalMessageTypes.sol` - Constants for factory and action types
- **Benefits**:
  - Reduces frontend RPC calls from 200+ to 1 for activity discovery
  - Enables trending project discovery without centralized server
  - Captures user messages alongside transaction metadata

### Vault System (`src/vaults/`)
- `UltraAlignmentVault.sol` - Share-based fee hub with V2/V3/V4 liquidity management
  - **Share-Based Architecture** (elegant refactor of epoch-based complexity):
    - Contributions accumulate in dragnet from multiple sources (direct transfers, hooks, project taxes)
    - Single batch conversion triggered by anyone (incentivized with small reward)
    - Shares issued proportional to contributions: `shares = (contribution / totalPending) × liquidityUnitsAdded`
    - O(1) fee claims via share ratio: `ethClaimed = (accumulatedFees × benefactorShares) / totalShares`
    - Multi-claim support via delta tracking: only new fees since last claim are transferred
  - **DEX Integration** (realistic V2/V3/V4 routing):
    - `_swapETHForTarget()`: Routes through V2/V3 pools where target token typically has deep liquidity
    - Accounts for slippage and majority token positioning in V2/V3 pools
    - `_checkTargetAssetPriceAndPurchasePower()`: Queries DEX prices, validates oracle alignment
    - `_calculateProportionOfEthToSwapBasedOnVaultOwnedLpTickValues()`: Dynamic swap ratio based on vault's LP position
    - `_checkCurrentVaultOwnedLpTickValues()`: Tracks vault's V4 LP position range and liquidity
  - **Performance**:
    - O(1) receive operations (direct contribution tracking)
    - O(1) fee claims (share-based ratio calculation, no iteration)
    - O(n) conversion (n = active benefactors in current dragnet)
    - Scales to unlimited conversions and benefactors
  - **Receiver Functions**:
    - `receive() external payable`: Direct ETH contributions, auto-tracked as pending
    - `receiveHookTax(Currency, uint256, address)`: Hook-attributed contributions with project source tracking

### ERC404 Ecosystem (`src/factories/erc404/`)
- `ERC404Factory.sol` - Creates bonding instances with vault-specific hooks
- `ERC404BondingInstance.sol` - DN404-based token with bonding curve mechanics
- `UltraAlignmentV4Hook.sol` - V4 hook collecting swap taxes → vault
- `UltraAlignmentHookFactory.sol` - Creates vault-scoped hook instances

### ERC1155 Ecosystem (`src/factories/erc1155/`)
- `ERC1155Factory.sol` - Creates open-edition instances with vault link
- `ERC1155Instance.sol` - ERC1155 with enforced 20% vault tithe on creator withdraw

## Documentation

### System Architecture
- **[ARCHITECTURE.md](./docs/ARCHITECTURE.md)** - Complete system architecture documentation
  - System overview and contract interaction flows
  - Core components and integration patterns
  - Global messaging system architecture
  - Uniswap V4 integration, fee distribution, queue rental
  - Deployment guide and security considerations

### Global Messaging
- **[GLOBAL_MESSAGING.md](./docs/GLOBAL_MESSAGING.md)** - Global messaging system deep-dive
  - Protocol-wide activity tracking architecture
  - Bit-packing optimization and data structures
  - Frontend integration patterns and query examples
  - Auto-authorization flow and security model
  - Performance characteristics and scaling analysis

### Vault Architecture
- **[ULTRA_ALIGNMENT.md](./docs/ULTRA_ALIGNMENT.md)** - High-level system overview of share-based fee distribution
  - Dragnet accumulation model, share issuance, delta-based claims
  - Integration points with ERC404 hooks and ERC1155 tithes
  - Real-world fee distribution examples with walkthroughs
- **[VAULT_ARCHITECTURE.md](./docs/VAULT_ARCHITECTURE.md)** - Technical deep-dive into share-based vault design
  - Data structures and storage layout
  - Complete function reference and signatures
  - Performance characteristics and scaling analysis
  - V2→V3→V4 pool routing for DEX integration

### Key Concepts
- **Share-Based Accounting**: Replacement for complex epoch-based tracking
  - Shares = (contribution / totalPending) × liquidityUnitsAdded
  - Fee distribution = (accumulatedFees × benefactorShares) / totalShares
- **Dragnet Contribution Model**: Accumulate contributions until batch conversion, deferred to public function
- **Multi-Claim Support**: Delta tracking via `shareValueAtLastClaim` enables multiple claims
- **O(1) Fee Claims**: No iteration required, pure ratio-based calculation
- **V2/V3/V4 Integration**: Realistic DEX routing considering majority token positioning

## Development

### Code Style

- Solidity version: ^0.8.20
- Use Foundry's formatter: `forge fmt`
- Follow NatSpec documentation standards

### Testing

- Unit tests for all contracts
- Integration tests for workflows
- Fuzz testing for critical functions

## License

MIT or AGPL-3.0

## References

- [CONTRACT_REQUIREMENTS.md](./CONTRACT_REQUIREMENTS.md) - Complete requirements specification
- [Foundry Book](https://book.getfoundry.sh/)
- [ERC404 Specification](https://eips.ethereum.org/EIPS/eip-404)
- [ERC1155 Specification](https://eips.ethereum.org/EIPS/eip-1155)
