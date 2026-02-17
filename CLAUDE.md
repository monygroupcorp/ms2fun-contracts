# ms2.fun Contracts

Curated launchpad for derivative art/tokens aligned to established crypto communities. Artists create projects bound to alignment vaults that buy and LP the target community's token.

## Key Concepts

- **Alignment Targets**: DAO-approved community profiles (Remilia, Pudgy, etc.) with assets and ambassadors
- **Vault Factories**: Code templates for vault strategies (e.g., UltraAlignmentVault)
- **Vault Instances**: Deployed vaults, each bound to an approved alignment target
- **Project Factories**: Code templates for project types (ERC404 bonding, ERC1155 editions, ERC721 auctions)
- **Project Instances**: Artist-created collections, each immutably bound to a vault
- **Benefactors**: Project instances that contribute fees to a vault, earn proportional LP yield

## Architecture

DAO (GrandCentral + Safe) → MasterRegistry → Alignment Targets → Vault Instances → Project Instances

MasterRegistry is UUPS upgradeable, owner is the DAO. It enforces all rules: target approval, vault/factory registration, instance-vault binding. New state variables always go at the end (storage layout safety).

## Revenue Flow

- ERC404: bonding fee (1%) → treasury. Graduation fee (2%) → split protocol + factory creator. Post-graduation V4 hook tax → vault.
- ERC1155: 20% tithe on artist withdrawals → vault.
- Vault LP yield: 5% protocol cut (includes factory creator sub-cut), 95% to benefactors.

## Governance

GrandCentral is a Moloch-pattern DAO. Shares = voting power, loot = economic rights. Proposals execute via Gnosis Safe. Conductor system delegates admin/manager/governor permissions.

## Tech Stack

Solidity 0.8.20, Foundry/Forge, Solady (Ownable, UUPS), Uniswap V4 (hooks, LP), DN404 (ERC404). Run `forge test` for full suite (~820 tests).

## File Layout

- `src/dao/` — GrandCentral DAO, StipendConductor
- `src/master/` — MasterRegistryV1 (UUPS), FeaturedQueueManager
- `src/factories/` — ERC404, ERC1155, ERC721 factories and instances
- `src/vaults/` — UltraAlignmentVault
- `src/registry/` — VaultRegistry, GlobalMessageRegistry
- `src/treasury/` — ProtocolTreasuryV1
- `docs/ARCHITECTURE.md` — Full system architecture
- `docs/plans/` — Implementation plans (historical)
