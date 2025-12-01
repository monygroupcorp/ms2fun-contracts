# ms2fun-contracts

Foundry-based Solidity repository for the ms2.fun launchpad ecosystem. This repository contains the core smart contracts that power a multi-project launchpad supporting ERC404 and ERC1155 token standards.

## Overview

The ms2.fun launchpad is a decentralized platform for launching and managing token projects. It features:

- **Factory Application System**: Factory creators submit applications with voting by EXEC token holders
- **Dynamic Pricing**: Supply and demand-based pricing for featured promotions
- **ERC404 Support**: Factory for deploying ERC404 token instances with advanced features
- **ERC1155 Support**: Factory for deploying ERC1155 multi-edition token instances
- **Ultra-Alignment System**: Advanced hook and vault systems for ERC404 tokens
- **Governance**: EXEC token holder voting system

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

## Contracts

### Master Registry

The `MasterRegistry` is the central contract managing factory applications, instance registration, and featured promotions.

- **Factory Application System**: Submit applications with ETH fee, vote with EXEC tokens
- **Dynamic Pricing**: Automatic price discovery for featured promotions
- **Instance Tracking**: Register and track all deployed instances

### ERC404 Factory

Factory for deploying ERC404 token instances with features like:
- Bonding curves
- Liquidity pools
- Chat integration
- Balance minting
- Portfolio tracking

### ERC1155 Factory

Factory for deploying ERC1155 multi-edition token instances.

### Governance

EXEC token holder voting system for proposals and upgrades.

## Documentation

See the `docs/` directory for detailed documentation:
- `ARCHITECTURE.md` - System architecture overview
- `MASTER_CONTRACT.md` - Master registry documentation
- `ERC404_FACTORY.md` - ERC404 factory documentation
- `ERC1155_FACTORY.md` - ERC1155 factory documentation
- `ULTRA_ALIGNMENT.md` - Ultra-Alignment system documentation
- `SECURITY.md` - Security considerations

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
