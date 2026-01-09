# ms2fun-contracts

Foundry-based Solidity contracts for the ms2.fun protocol — a multi-project launchpad ecosystem supporting ERC404 and ERC1155 token standards with integrated vault-based fee distribution and alignment incentives.

## Overview

The ms2.fun protocol features:

- **Master Registry**: Central indexing of factories, instances, and vaults with governance voting
  - **Vault Query System**: Comprehensive queries for vault discovery and ranking
    - TVL-based rankings (by accumulated fees)
    - Popularity rankings (by instance count)
    - Vault-to-instance reverse lookups
    - Paginated vault listings with full metadata
- **Governance System**: Decentralized approval voting for factories and vaults
  - **Factory Approval Governance**: EXEC token-based voting with deposit mechanics
  - **Vault Approval Governance**: Community-driven vault approval with escalating challenge deposits
  - Three-phase voting: Initial Vote → Challenge Window → Challenge Vote → Lame Duck
  - Metadata standards for applications (factory and vault specs)
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
# IMPORTANT: Store your private key securely using Forge's keystore
# Create a keystore account (you'll be prompted for a password):
cast wallet import deployer --interactive

# Set environment variables
export EXEC_TOKEN=0x...

# Deploy master registry (using your keystore account)
forge script script/DeployMaster.s.sol:DeployMaster \
  --rpc-url <rpc_url> \
  --account deployer \
  --broadcast

# Deploy factories (using your keystore account)
forge script script/DeployERC404Factory.s.sol:DeployERC404Factory \
  --rpc-url <rpc_url> \
  --account deployer \
  --broadcast
```

**Security Note**: Never store private keys in environment variables or `.env` files. Always use Forge's encrypted keystore via `cast wallet import` and the `--account` flag.

## Core Contracts

### Master Registry (`src/master/`)
Central indexing and governance:
- `MasterRegistryV1.sol` - UUPS upgradeable registry implementation
- Factory and vault application voting system
- Instance and vault registration tracking with comprehensive queries
- **Vault Query System**:
  - `getTotalVaults()` - Total registered vault count
  - `getInstancesByVault(address)` - Reverse lookup: vault → instances using it
  - `getVaults(startIndex, endIndex)` - Paginated vault listings with metadata
  - `getVaultsByPopularity(limit)` - Vaults ranked by instance count (most used)
  - `getVaultsByTVL(limit)` - Vaults ranked by accumulated fees (highest TVL)
- Multi-factory support with factory query functions
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

### Governance System (`src/governance/`)
Decentralized approval voting for protocol components:
- `FactoryApprovalGovernance.sol` - Community voting for factory approval
  - EXEC token-based deposit voting (MIN_DEPOSIT: 1M EXEC)
  - Initial vote period (7 days) → Challenge window (7 days)
  - Escalating challenge deposits (sum of all previous yay votes)
  - Lame duck period (3 days) for final coordination
  - Vote retrieval after application resolution
- `VaultApprovalGovernance.sol` - Community voting for vault approval
  - Same mechanics as factory governance
  - Standardized metadata requirements (see VAULT_METADATA_STANDARD.md)
  - Auto-registration via MasterRegistry on approval
- `VotingPower.sol` - EXEC token voting power calculator

### Vault System (`src/vaults/`)
- `UltraAlignmentVault.sol` - Share-based fee hub with V2/V3/V4 liquidity management
  - **IAlignmentVault Interface Compliance**: Standardized vault interface for ecosystem compatibility
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

### Governance System
- **[VAULT_GOVERNANCE_STRATEGY.md](./VAULT_GOVERNANCE_STRATEGY.md)** - Governance design philosophy
  - Three-phase voting mechanism (Initial → Challenge → Challenge Vote → Lame Duck)
  - Escalating challenge deposits and capital efficiency
  - Metadata standards for vault applications
- **[VAULT_METADATA_STANDARD.md](./docs/VAULT_METADATA_STANDARD.md)** - Vault application metadata specification
  - Required fields (strategy, risks, contact information)
  - Optional fields (audit reports, features, dependencies)
  - JSON schema and validation checklist
  - Complete example applications

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
- **[IAlignmentVault Interface](./src/interfaces/IAlignmentVault.sol)** - Standard vault interface specification
  - Fee reception methods (receiveHookTax, receive)
  - Fee claiming and share queries
  - Compliance requirements for vault approval

### Key Concepts

#### Governance
- **Escalating Challenge Deposits**: Challengers must deposit >= sum of all previous yay votes
  - Prevents spam challenges while allowing legitimate concerns
  - Capital-efficient: only serious challengers with community backing can proceed
- **Three-Phase Voting**: Initial Vote → Challenge Window → Challenge Vote → Lame Duck
  - Phase 1: Community signals support via EXEC deposits
  - Phase 2: Window for challenges (anyone can challenge if they meet deposit requirement)
  - Phase 3: If challenged, vote on whether challenge is valid
  - Phase 4: Lame duck period for coordination before registration
- **Vote Retrieval**: Voters can withdraw deposits after application is resolved (approved/rejected)

#### Vault Queries
- **TVL Ranking**: Vaults sorted by `accumulatedFees()` (via IAlignmentVault interface)
  - Try-catch pattern for graceful handling of non-compliant vaults
  - Bubble sort implementation (acceptable for view functions)
- **Popularity Ranking**: Vaults sorted by instance count (how many projects use them)
  - Tracks via `vaultInstances` reverse mapping
  - Updated automatically on instance registration
- **Bidirectional Tracking**: Both vault→instances and instance→vault lookups supported
  - Enables "find all projects using this vault" queries
  - Powers vault leaderboards and discovery

#### Vault Architecture
- **Share-Based Accounting**: Replacement for complex epoch-based tracking
  - Shares = (contribution / totalPending) × liquidityUnitsAdded
  - Fee distribution = (accumulatedFees × benefactorShares) / totalShares
- **Dragnet Contribution Model**: Accumulate contributions until batch conversion, deferred to public function
- **Multi-Claim Support**: Delta tracking via `shareValueAtLastClaim` enables multiple claims
- **O(1) Fee Claims**: No iteration required, pure ratio-based calculation
- **V2/V3/V4 Integration**: Realistic DEX routing considering majority token positioning

## Usage Examples

### Querying Vaults

```solidity
// Get total number of registered vaults
uint256 totalVaults = masterRegistry.getTotalVaults();

// Get top 10 vaults by TVL (accumulated fees)
(
    address[] memory topVaults,
    uint256[] memory tvls,
    string[] memory names
) = masterRegistry.getVaultsByTVL(10);

// Get top 10 most popular vaults (by instance count)
(
    address[] memory popularVaults,
    uint256[] memory instanceCounts,
    string[] memory names
) = masterRegistry.getVaultsByPopularity(10);

// Get all instances using a specific vault
address[] memory instances = masterRegistry.getInstancesByVault(vaultAddress);

// Paginated vault query (get vaults 0-100)
(
    address[] memory vaultAddresses,
    IMasterRegistry.VaultInfo[] memory vaultInfos,
    uint256 total
) = masterRegistry.getVaults(0, 100);
```

### Applying for Vault Approval

```solidity
// 1. Deploy your vault (must implement IAlignmentVault)
MyCustomVault vault = new MyCustomVault(...);

// 2. Prepare metadata (see VAULT_METADATA_STANDARD.md)
string memory metadataURI = "ipfs://Qm..."; // Points to JSON metadata

// 3. Submit application (0.1 ETH fee)
bytes32[] memory features = new bytes32[](2);
features[0] = keccak256("UniswapV4");
features[1] = keccak256("AutoCompound");

masterRegistry.applyForVault{value: 0.1 ether}(
    address(vault),
    "UniswapV4LP",           // Vault type
    "My-Custom-Vault",        // URL-safe name
    "My Custom Vault",        // Display title
    metadataURI,
    features
);

// 4. Community votes using EXEC tokens
// 5. After approval, vault is automatically registered
```

## Development

### Code Style

- Solidity version: ^0.8.20
- Use Foundry's formatter: `forge fmt`
- Follow NatSpec documentation standards

### Testing

```bash
# Run all tests
forge test

# Run specific test suites
forge test --match-path test/governance/VaultApprovalGovernance.t.sol  # Vault governance tests (28 tests)
forge test --match-path test/master/MasterRegistryVaultQueries.t.sol  # Vault query tests (24 tests)
forge test --match-path test/vaults/VaultInterfaceCompliance.t.sol     # IAlignmentVault compliance tests

# Run with verbosity
forge test -vvv
```

**Test Coverage:**
- Unit tests for all contracts
- Integration tests for complete workflows
- Governance voting scenarios (deposits, challenges, withdrawals)
- Vault query edge cases (pagination, sorting, empty results)
- Fuzz testing for critical functions
- Interface compliance verification

## License

MIT or AGPL-3.0

## References

- [CONTRACT_REQUIREMENTS.md](./CONTRACT_REQUIREMENTS.md) - Complete requirements specification
- [Foundry Book](https://book.getfoundry.sh/)
- [ERC404 Specification](https://eips.ethereum.org/EIPS/eip-404)
- [ERC1155 Specification](https://eips.ethereum.org/EIPS/eip-1155)
