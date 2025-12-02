# ms2fun-contracts

Foundry-based Solidity contracts for the ms2.fun protocol — a multi-project launchpad ecosystem supporting ERC404 and ERC1155 token standards with integrated vault-based fee distribution and alignment incentives.

## Overview

The ms2.fun protocol features:

- **Master Registry**: Central indexing of factories, instances, and vaults with governance voting
- **ERC404 Bonding Factory**: Creates ERC404 instances with V4 hook integration for swap tax collection
- **ERC1155 Factory**: Creates open-edition instances with enforced vault tithe (20% on creator withdraw)
- **UltraAlignmentVault**: Centralized fee hub receiving taxes from all projects, converting ETH → target token LP positions with multi-conversion fee distribution
- **V4 Hook Integration**: ETH/WETH-based swap tax collection routed to vault (vault-scoped, applies platform-wide)
- **Conversion-Indexed Benefactor Accounting**: Lifetime fee claims from multiple conversion rounds with frozen benefactor percentages

## Repository Structure

```
ms2fun-contracts/
├── src/
│   ├── master/              # Master registry contracts
│   ├── factories/           # Factory contracts (ERC404, ERC1155)
│   ├── governance/          # Governance contracts
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

### Vault System (`src/vaults/`)
- `UltraAlignmentVault.sol` - Fee hub with trailing epoch condenser architecture
  - Receives ETH from ERC404 hooks and ERC1155 tithes
  - Converts accumulated ETH to target token and creates V4 LP positions
  - **Trailing Epoch Condenser**: O(1) fee claims via lifetime contribution ratio model
  - Decentralized epoch finalization with keeper incentives (`finalizeEpochAndStartNew()`)
  - Automatic rolling window compression (`_compressOldestEpoch()`) - keeps last 3 epochs active
  - Scales to 5000+ conversions and 2000+ benefactors without gas bloat
- `LPPositionValuation.sol` - Epoch-based tracking with immutable conversion records
  - EpochRecord struct for batching conversions and tracking benefactor contributions
  - BenefactorState minimalist tracking (lifetime ETH, last claim, timestamps)
  - Support for historical query access (backwards compatibility)

### ERC404 Ecosystem (`src/factories/erc404/`)
- `ERC404Factory.sol` - Creates bonding instances with vault-specific hooks
- `ERC404BondingInstance.sol` - DN404-based token with bonding curve mechanics
- `UltraAlignmentV4Hook.sol` - V4 hook collecting swap taxes → vault
- `UltraAlignmentHookFactory.sol` - Creates vault-scoped hook instances

### ERC1155 Ecosystem (`src/factories/erc1155/`)
- `ERC1155Factory.sol` - Creates open-edition instances with vault link
- `ERC1155Instance.sol` - ERC1155 with enforced 20% vault tithe on creator withdraw

## Documentation

### Essential Guides
- **[MANUAL_REVIEW_GUIDE.md](./MANUAL_REVIEW_GUIDE.md)** - Comprehensive review checklist (15 sections, 100+ verification points)
- **[SWAP_AND_LP_STUBS.md](./SWAP_AND_LP_STUBS.md)** - Implementation guide for swap and LP position stubs
- **[benefactor-accounting-redesign.md](./.claude/plans/benefactor-accounting-redesign.md)** - Multi-conversion accounting architecture (in .claude/plans/)

### Key Concepts
- **Conversion-Indexed Benefactor Accounting**: Per-conversion immutable records instead of singular overwriting mappings
- **Multi-Claim Support**: Benefactors claim multiple times from same conversion as LP fees accumulate
- **Frozen Percentages**: Benefactor stakes locked at conversion time, independent of LP value fluctuations
- **O(k) Scaling**: Benefactor claims loop through conversions they participated in (k ≈ 50-100), not all conversions

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
