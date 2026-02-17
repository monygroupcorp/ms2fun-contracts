# ms2fun-contracts

Solidity contracts for the ms2.fun protocol — a curated launchpad for derivative art and tokens aligned to established crypto communities. Artists create projects bound to alignment vaults that buy and LP the target community's token via Uniswap V4.

## How It Works

1. **DAO approves alignment targets** — communities like Remilia (CULT) or Pudgy Penguins whose tokens the protocol aligns with
2. **Vault instances deploy** against approved targets — anyone can deploy, but MasterRegistry enforces the target is approved
3. **Artists create projects** (ERC404 bonding curves, ERC1155 editions, ERC721 auctions) bound to a vault
4. **Users buy/mint** — fees flow to the vault
5. **Vault converts fees** to the alignment token and deposits full-range V4 LP — creating permanent buying pressure and liquidity

Every participant earns: vault factory creators get yield cuts, artists get project revenue + vault fee shares, the protocol treasury captures fees at every layer, and the aligned community benefits from buying pressure on their token.

## Repository Structure

```
src/
├── dao/                # GrandCentral (Moloch DAO) + StipendConductor
├── master/             # MasterRegistryV1 (UUPS), FeaturedQueueManager
├── factories/          # ERC404, ERC1155, ERC721 factories and instances
├── vaults/             # UltraAlignmentVault (share-based fee hub)
├── registry/           # VaultRegistry, GlobalMessageRegistry
├── treasury/           # ProtocolTreasuryV1
├── interfaces/         # IAlignmentVault, IFactory, IFactoryInstance
├── libraries/          # Message packing, V4 helpers
└── shared/             # Common interfaces and utilities

test/                   # ~840 tests
script/                 # Deployment scripts
docs/                   # Architecture and implementation plans
```

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Build & Test

```bash
forge install
forge build
forge test
```

### Deploy

```bash
# Use Forge's encrypted keystore (never store keys in env vars)
cast wallet import deployer --interactive

forge script script/DeployMaster.s.sol:DeployMaster \
  --rpc-url <rpc_url> \
  --account deployer \
  --broadcast
```

See `docs/plans/launch-procedure.md` for full deployment order. After initial setup, deploy the Timelock (`script/DeployTimelock.s.sol`) and migrate ownership (`script/MigrateOwnership.s.sol`).

## Core Systems

### Alignment Targets

DAO-approved community profiles stored in MasterRegistry. Each target has a title, description, metadata URI, asset list (tokens), and ambassador list (project-provided wallets). Vault instances must point at an approved target to be registered.

```solidity
// DAO registers a target
registry.registerAlignmentTarget("Remilia", "Cyber yakuza accelerationist cult", metadataURI, assets);

// Anyone deploys a vault for that target
registry.registerVault(address(vault), "Remilia Vault", "ipfs://...", targetId);
```

### Vault System

**UltraAlignmentVault** — share-based fee distribution with O(1) claims:
- Collects ETH from project instances (hook taxes, tithes, direct contributions)
- Batch-converts to alignment token via V3/V2, deposits full-range V4 LP
- Issues shares proportional to contributions
- LP fees distributed to benefactors via delta-based claims

Fee equation:
```
LP Yield → 5% protocol cut (includes factory creator sub-cut) + 95% benefactors
```

### Factory System

| Factory | Token Standard | Fee Model |
|---------|---------------|-----------|
| **ERC404 Bonding** | Hybrid ERC20/ERC721 | 1% bonding fee, 2% graduation fee, V4 hook swap tax |
| **ERC1155 Edition** | ERC1155 multi-token | 20% tithe on artist withdrawals |
| **ERC721 Auction** | ERC721 | Auction proceeds |

All instances have an **immutable** vault reference set at construction.

### Governance (GrandCentral + Timelock)

Moloch-pattern DAO governing the protocol through a Gnosis Safe with a 48-hour timelock:
- **Shares** = voting power, **Loot** = non-voting economic rights
- Proposal lifecycle: Submit → Sponsor → Vote → Grace → Process
- **Timelock**: all owner-gated operations (upgrades, registrations, parameter changes) must pass through a 48-hour delay before execution — giving users a credible exit window
- Conductor system: delegated admin/manager/governor permissions
- Ragequit: members burn shares for proportional treasury payout
- Controls: alignment targets, factory/vault registration, ambassadors, protocol params

### Security

- **Timelock** — Solady `Timelock` with 48h minimum delay sits between the DAO and all protocol contracts. Safe proposes, anyone executes after delay, Safe can cancel during the window. Prevents instant upgrades or fund redirection from a compromised Safe.
- **Immutable bindings** — instance-to-vault references are set at construction and cannot be changed
- **Open executor** — anyone can trigger timelocked execution after delay, preventing griefing

### Registry & Discovery

- **MasterRegistry** (UUPS) — enforcement layer for all registrations
- **GlobalMessageRegistry** — protocol-wide activity feed (buys, mints, sells) with 176-bit packed messages
- **FeaturedQueueManager** — competitive rental queue for homepage visibility
- **VaultRegistry** — vault/hook metadata and registration fees

## Documentation

- **[ARCHITECTURE.md](./docs/ARCHITECTURE.md)** — Full system architecture (start here)
- **[docs/plans/](./docs/plans/)** — Implementation plans and design documents
- **[CLAUDE.md](./CLAUDE.md)** — Concise project context for AI-assisted development

## Development

```bash
# Run all tests (~840)
forge test

# Run specific test suite
forge test --match-contract AlignmentTargetsTest -v

# Run with gas reporting
forge test --gas-report

# Format
forge fmt
```

Solidity ^0.8.20. Uses Solady (Ownable, UUPS), Uniswap V4, DN404.

## License

MIT
