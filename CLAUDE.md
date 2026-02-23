# ms2.fun Contracts

Curated launchpad for derivative art/tokens aligned to established crypto communities. Artists create projects bound to alignment vaults that buy and LP the target community's token.

## Key Concepts

- **Alignment Targets**: DAO-approved community profiles (Remilia, Pudgy, etc.) with assets and ambassadors. Managed by AlignmentRegistryV1.
- **Vault Instances**: Deployed vaults, each bound to an approved alignment target
- **Project Factories**: Code templates for project types (ERC404 bonding, ERC1155 editions, ERC721 auctions)
- **Project Instances**: Artist-created collections, each immutably bound to a vault
- **Benefactors**: Project instances that contribute fees to a vault, earn proportional LP yield

## Architecture

```
DAO (GrandCentral + Safe) → Timelock
  → AlignmentRegistry (curation: targets + ambassadors)
  → MasterRegistry (registration: factories, vaults, instances)
  → GlobalMessageRegistry (activity feed, wired directly to instances)
  → FeaturedQueueManager (promotion queue)
```

**AlignmentRegistryV1** manages alignment targets and ambassadors (curation). **MasterRegistryV1** manages factory/vault/instance registration (phone book). Both are UUPS upgradeable, owned by the DAO via Timelock.

Factories receive `globalMessageRegistry` at construction and pass it to instances — no runtime lookups through MasterRegistry (direct wiring, not service locator).

MasterRegistry holds a reference to AlignmentRegistry for vault registration validation. Factories can register vaults directly (if active), or the DAO can register singleton vaults.

## Revenue Flow

- ERC404: bonding fee (1%) → treasury. Graduation fee (2%) → split protocol + factory creator. Post-graduation V4 hook tax → vault.
- ERC1155: 20% tithe on artist withdrawals → vault.
- Vault LP yield: 5% protocol cut (includes factory creator sub-cut), 95% to benefactors.

## Governance

GrandCentral is a Moloch-pattern DAO. Shares = voting power, loot = economic rights. Proposals execute via Gnosis Safe through a 48h Timelock. Conductor system delegates admin/manager/governor permissions.

## Tech Stack

Solidity 0.8.20, Foundry/Forge, Solady (Ownable, UUPS), Uniswap V4 (hooks, LP), DN404 (ERC404). Run `forge test` for full suite (~1009 tests).

## Build & Test Performance

This repo has many contracts and a full build/test is slow. Always use targeted commands during development:

- **Run specific tests**: `forge test --match-contract MyContractTest` or `--match-path "test/vaults/**"`
- **Build without tests/scripts**: `forge build --skip "test/**" --skip "script/**"`
- **Trust incremental builds**: never use `--no-cache` unless diagnosing a stale artifact issue
- **Per-area profile** (optional): `FOUNDRY_PROFILE=fast forge build` with a profile that scopes `src` to the area you're working in

## File Layout

- `src/dao/` — GrandCentral DAO, conductors (StipendConductor, ShareOffering, RevenueConductor)
- `src/master/` — MasterRegistryV1 (UUPS), AlignmentRegistryV1 (UUPS), FeaturedQueueManager
- `src/factories/` — ERC404 (factory, instance, staking module, launch manager, curve computer, liquidity deployer), ERC1155, ERC721
- `src/vaults/` — UltraAlignmentVault
- `src/registry/` — VaultRegistry, GlobalMessageRegistry
- `src/treasury/` — ProtocolTreasuryV1
- `docs/ARCHITECTURE.md` — Full system architecture
- `docs/plans/` — Implementation plans (historical)
