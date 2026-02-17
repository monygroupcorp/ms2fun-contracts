# ms2.fun Protocol Architecture

**Last Updated:** 2026-02-16

---

## 1. Protocol Overview

ms2.fun is a curated launchpad for derivative art and tokens aligned to established crypto communities. Artists create projects (ERC404 bonding curves, ERC1155 editions, ERC721 auctions) that are structurally bound to alignment vaults. These vaults accumulate fees from all project activity, convert them to the target community's token, and deposit full-range Uniswap V4 LP positions — creating permanent buying pressure and liquidity for the aligned asset.

The protocol curates which communities receive vaults through DAO governance. At launch, the team selects initial alignment targets (e.g., Remilia/CULT, Pudgy Penguins). Over time, DAO shareholders propose and vote on new targets. Projects that don't merit alignment don't get vault space.

Every participant in the system earns from the value they contribute: vault factory creators earn yield cuts for building infrastructure, artists earn from their project sales and vault fee shares, and the protocol treasury captures fees at every layer.

---

## 2. System Map

```
DAO (GrandCentral + Gnosis Safe)
│
├── Proposes operations ─────────────► Timelock (48h min delay)
│                                       │ (anyone executes after delay)
│                                       ▼
├── Approves Alignment Targets ──────► MasterRegistry
│     (Remilia, Pudgy, etc.)            │
│                                       ├── AlignmentTargets[]
├── Approves Vault Factories            │     ├── title, description, metadataURI
│     (UltraAlignmentVault, etc.)       │     ├── assets[] (tokens + metadata)
│                                       │     └── ambassadors[] (project wallets)
├── Approves Project Factories          │
│     (ERC404, ERC1155, ERC721)         ├── VaultInstances[]
│                                       │     └── linked to targetId
├── Manages Ambassadors                 │
│                                       ├── ProjectFactories[]
└── Manages Protocol Parameters         │
                                        └── ProjectInstances[]
                                              └── linked to vault

Vault Factories                    Project Factories
(code templates)                   (code templates)
      │                                  │
      ▼                                  ▼
Vault Instances ◄──── fees ──── Project Instances
(per target)          flow       (per artist)
      │                                  │
      ▼                                  ▼
Alignment Token                    Users (buyers)
LP Positions
```

### Hierarchy

- **DAO** governs the protocol through proposals and votes
- **Timelock** enforces a 48-hour delay between proposal and execution — gives users an exit window before critical changes take effect
- **MasterRegistry** enforces all rules (target approval, vault/factory registration, instance binding)
- **Alignment Targets** are curated community profiles (Remilia, Pudgy, etc.)
- **Vault Factories** are code templates for different vault strategies
- **Vault Instances** are deployed vaults, each bound to an approved alignment target
- **Project Factories** are code templates for different project types (ERC404, ERC1155, ERC721)
- **Project Instances** are deployed projects (artist collections), each bound to a vault

---

## 3. Alignment Targets & Curation

Alignment Targets are the protocol's curation mechanism. Each target represents an established community whose token the protocol aligns with.

### Data Structure

```solidity
struct AlignmentTarget {
    uint256 id;
    string title;           // "Remilia"
    string description;     // "Cyber yakuza accelerationist cult"
    string metadataURI;     // Frontend-hosted (icons, banners, CSS, links)
    uint256 approvedAt;
    bool active;
}

struct AlignmentAsset {
    address token;          // CULT token address
    string symbol;          // "CULT"
    string info;            // "Majority LP in Uniswap V3 pool"
    string metadataURI;
}
```

### Lifecycle

1. **DAO shareholder proposes** a new alignment target (community + token)
2. **DAO votes** on the proposal via GrandCentral
3. **On approval**, target is registered in MasterRegistry — vault instances can now be deployed against it
4. **Vault instances** deployed by anyone, but MasterRegistry enforces the vault's alignment token matches an approved target asset
5. **Project connects**: when the target project (e.g., Remilia) reaches out, DAO votes to add their multisig as an **ambassador**
6. **Ambassador powers** are vault-type-dependent — UltraAlignmentVault has no management functions, but future vault types may grant ambassadors operational control

### Ambassador System

Ambassadors are wallets officially provided by the target project. All ambassador changes go through DAO votes. Their powers depend on the vault type:

- **UltraAlignmentVault**: No management functions. Vault activity (buying + LP-ing the target token) IS the upside.
- **Future vault types**: May expose management functions gated by `isAmbassador(targetId, address)`.

### Enforcement

MasterRegistry enforces at `registerVault()`:
- Target must exist and be active
- Vault's `alignmentToken()` must match a token in the target's asset list
- Multiple vault instances per target are allowed (different strategies, different factories)

---

## 4. Vault System

Vaults are the economic engine of the protocol. They collect fees from all project activity, convert them to the target community's token, and deposit Uniswap V4 LP positions.

### Terminology

| Term | Definition |
|------|-----------|
| **Vault Factory** | Code template for a vault strategy (e.g., UltraAlignmentVault) |
| **Vault Factory Creator** | Developer who wrote the vault factory. Permanently in fee structure |
| **Vault Instance** | Deployed vault configured for a specific alignment target |
| **Benefactor** | A project instance that contributes fees to the vault |

### UltraAlignmentVault

The primary vault implementation. Share-based fee distribution with O(1) claims.

**How it works:**
1. Project instances send ETH to the vault via `receiveInstance()`
2. ETH accumulates in a "dragnet" (pending pool) attributed to each benefactor
3. Anyone can trigger `convertAndAddLiquidity()` (incentivized with ~0.0012 ETH reward)
4. Vault swaps ETH → alignment token via V3/V2, mints full-range V4 LP position
5. Shares issued to benefactors proportional to their contribution
6. LP fees accumulate over time, claimable by benefactors via `claimFees()`

**Share accounting:**
```
sharesIssued = (benefactorPending / totalPending) × liquidityUnitsAdded
claimableAmount = (accumulatedFees × benefactorShares / totalShares) - previouslyClaimed
```

**Fee splits on LP yield:**
```
protocolYieldCutBps (default 500 = 5%)
  ├── factoryCreator yield cut (≤ protocolYieldCutBps)
  └── remaining → protocol treasury
benefactors get the rest (95%)
```

**Factory Creator Transfer:** The `factoryCreator` address is transferable via a two-step pattern (`transferFactoryCreator` → `acceptFactoryCreator`) for wallet management.

### Benefactor Delegation

Benefactors (project instances) can delegate fee claims to another address:
- `delegateBenefactor(delegate)` — route claims to a different address
- `claimFeesAsDelegate(benefactors[])` — batch claim for multiple benefactors

### V4 Integration

The vault implements `IUnlockCallback` for V4 LP operations:
- All `modifyLiquidity` calls occur within `unlockCallback`
- Full-range positions (min/max usable ticks)
- Currency settlement via `CurrencySettler` library

---

## 5. Factory System

Factories create project instances. Each factory type serves a different use case.

### ERC404 Bonding Factory

Creates hybrid ERC20/ERC721 tokens with bonding curves.

**Instance lifecycle:**
1. Artist deploys instance via factory with vault binding
2. Users buy tokens on the bonding curve (`buyBonding()`)
3. Bonding fees (default 1%) go to protocol treasury
4. At maturity, anyone triggers `deployLiquidity()` (graduation)
5. Graduation fee (default 2%) split between protocol and factory creator
6. Remaining ETH swaps to alignment token, mints V4 LP position
7. Post-graduation: tokens trade on V4 pool with hook-based swap tax

**Key features:**
- Tier system: password-protected or time-gated access
- Staking: holders can stake tokens to receive proportional vault fee distribution
- Free mint: first purchaser gets 1M tokens if supply allows
- Reroll: NFT reshuffling mechanism
- V4 Hook: `afterSwap()` tax routed to vault with project attribution

**Fee parameters (immutable per instance):**
- `bondingFeeBps` — fee on bonding purchases (default 100 = 1%)
- `graduationFeeBps` — fee on liquidity deployment (default 200 = 2%)
- `creatorGraduationFeeBps` — factory creator's share of graduation fee
- `polBps` — protocol-owned liquidity percentage (default 100 = 1%)

### ERC1155 Edition Factory

Creates open-edition or limited-edition NFTs for artists.

**Instance lifecycle:**
1. Artist deploys edition with pricing model and vault binding
2. Users mint editions at configured price
3. Artist withdraws proceeds — 20% tithe automatically sent to vault
4. Artist can claim proportional vault fees via `claimVaultFees()`

**Pricing models:**
- `UNLIMITED` — fixed price, infinite supply
- `LIMITED_FIXED` — fixed price, capped supply
- `LIMITED_DYNAMIC` — exponential price increase: `price = basePrice × (1 + rate)^mintedCount`

### ERC721 Auction Factory

Creates auction-based NFT drops.

### Instance-Vault Binding

All instances have an **immutable** vault reference set at construction:
```solidity
address public immutable vault;
```

MasterRegistry enforces at registration:
- Instance's `vault()` must match the declared vault
- Instance must have a `protocolTreasury()` set
- Instance's vault must be a deployed contract

This binding is permanent — instances cannot migrate between vaults.

---

## 6. Revenue Architecture

Revenue flows through multiple layers, each with its own fee structure.

### Fee Flow Diagram

```
User Activity
│
├── ERC404 Bonding Purchase
│     ├── bondingFeeBps (1%) ──────────────► Protocol Treasury
│     └── remainder ──────────────────────► Instance reserve
│
├── ERC404 Graduation (liquidity deployment)
│     ├── graduationFeeBps (2%)
│     │     ├── creatorGraduationFeeBps ──► Factory Creator
│     │     └── remainder ────────────────► Protocol Treasury
│     ├── polBps (1%) ────────────────────► Protocol-Owned Liquidity
│     └── remainder ──────────────────────► V4 LP position
│
├── ERC404 Post-Graduation Swaps
│     └── V4 Hook Tax ────────────────────► Vault (via receiveInstance)
│
├── ERC1155 Mint
│     └── proceeds ───────────────────────► Instance balance
│           └── on withdraw: 20% tithe ──► Vault (via receiveInstance)
│
└── Vault LP Yield
      ├── protocolYieldCutBps (5%)
      │     ├── factoryCreator cut ───────► Vault Factory Creator
      │     └── remainder ────────────────► Protocol Treasury
      └── benefactor share (95%) ─────────► Project Instances (proportional)
```

### Who Gets Paid

| Participant | Revenue Source | Mechanism |
|-------------|--------------|-----------|
| **Protocol Treasury** | Bonding fees, graduation fees, LP yield cut | Direct transfers, accumulated fees |
| **Vault Factory Creator** | LP yield sub-cut | `withdrawCreatorFees()` on vault |
| **Project Factory Creator** | Graduation fee share | `creatorGraduationFeeBps` |
| **Artist (instance creator)** | ERC1155: 80% of mint proceeds. ERC404: graduation fee share, vault fee claims via staking | Instance-level extraction |
| **Alignment Target** | No direct fee. Vault buying pressure on their token IS the upside | Structural benefit |

### Protocol Treasury

`ProtocolTreasuryV1` holds protocol funds. Receives fees from multiple sources across the system.

---

## 7. Governance (GrandCentral)

GrandCentral is a Moloch-pattern DAO that governs the protocol through a Gnosis Safe.

### Structure

- **Shares**: Voting power, earnable through contributions
- **Loot**: Non-voting economic rights (claimable rewards)
- **Proposals**: On-chain votes that execute transactions via Safe
- **Ragequit**: Members can burn shares/loot for proportional payout from ragequit pool

### Proposal Lifecycle

```
Submitted → [Sponsored] → Voting → Grace → Ready → Processed
                            │                         │
                        Cancelled                  Defeated
                        (terminal)                (terminal)
```

1. Shareholder submits proposal (self-sponsors if shares >= threshold)
2. Voting period: shareholders vote yes/no using historical share balances
3. Grace period: ragequit window for dissenting members
4. Processing: if quorum met and yes > no, transactions execute via Safe

### Conductor System

Delegated permissions via bitmask: `admin(1) | manager(2) | governor(4)`

| Role | Permissions |
|------|------------|
| **Admin** | Full DAO governance control |
| **Manager** | Mint/burn shares and loot, manage stipends |
| **Governor** | Governance configuration, fund claims pool |

Conductor roles can be individually locked (irreversible) by the DAO.

### StipendConductor

Autonomous recurring payment system. DAO configures a beneficiary, amount, and interval. Anyone can trigger `execute()` after the interval passes — no governance proposal needed per payment.

### Timelock

A Solady `Timelock` sits between the DAO/Safe and all protocol contracts. Every owner-gated operation (upgrades, registrations, parameter changes) must pass through the timelock's delay before execution.

**Ownership chain:**
```
GrandCentral proposal passes
  → Safe calls Timelock.propose(mode, executionData, delay)
  → 48h minimum delay (visible on-chain)
  → Anyone calls Timelock.execute(mode, executionData)
  → Timelock (as owner) calls target contract
```

**Roles:**
| Role | Holder | Purpose |
|------|--------|---------|
| **Admin** | Safe | Can manage roles |
| **Proposer** | Safe | Can schedule operations |
| **Executor** | Open (anyone) | Can trigger execution after delay — prevents griefing |
| **Canceller** | Safe | Can abort pending operations during delay |

The timelock is deployed directly (not behind a proxy) — timelocks should be immutable. Uses ERC7821 batched execution for multi-call proposals.

### What the DAO Controls

All actions below are subject to the 48-hour timelock delay:

- Alignment target approval, deactivation, and updates
- Ambassador management for alignment targets
- Vault factory and project factory registration
- Vault deactivation
- Protocol parameter changes
- Treasury disbursements
- UUPS contract upgrades

Direct DAO actions (no timelock):
- Share and loot distribution
- Conductor role management
- Internal governance parameter changes

---

## 8. Registry & Discovery

### MasterRegistry (UUPS Upgradeable)

The enforcement layer for the entire protocol. Owner is the DAO (GrandCentral via Safe).

**Manages:**
- Alignment targets (targets, assets, ambassadors)
- Vault instances (linked to targets, enforcement on registration)
- Project factories (registration, active status)
- Project instances (linked to vaults, name collision prevention)
- Featured queue manager reference
- Global message registry reference

**Enforcement at registration:**
- Factories: must implement `IFactory` with `creator()` and `protocol()`
- Instances: must have immutable vault matching declaration, must have protocol treasury
- Vaults: must point to approved and active alignment target with matching token

### FeaturedQueueManager

Competitive rental queue for homepage visibility. Instances rent featured positions by paying ETH. Positions shift as new renters enter. Auto-renewal with deposited funds. Cleanup rewards incentivize expiration processing.

### GlobalMessageRegistry

Protocol-wide activity feed. Instances emit structured messages (buys, sells, mints, etc.) with bit-packed metadata. Enables trending detection and social discovery with single RPC calls.

**Message format:** 176-bit packed data
```
[timestamp:32][factoryType:8][actionType:8][contextId:32][amount:96][reserved:80]
```

Auto-authorized: instances from registered factories are automatically authorized to post messages.

### VaultRegistry

Standalone registry for vault and hook metadata. Handles registration fees (0.05 ETH vaults, 0.02 ETH hooks) and basic metadata tracking. Separate from MasterRegistry's alignment target enforcement.

---

## 9. Deployment & Upgrade

### Deploy Order

1. **MasterRegistryV1** — Deploy implementation, then proxy with `initialize(daoOwner)`
2. **GrandCentral** — Deploy with Safe address, founder shares, governance params
3. **ProtocolTreasuryV1** — Deploy protocol treasury
4. **GlobalMessageRegistry** — Deploy, link to MasterRegistry
5. **FeaturedQueueManager** — Deploy, link to MasterRegistry
6. **VaultRegistry** — Deploy standalone
7. **Alignment Targets** — Register via DAO (or owner during bootstrap)
8. **Vault Factories** — Register approved vault code templates
9. **Vault Instances** — Deploy for approved targets
10. **Project Factories** — Register ERC404, ERC1155, ERC721 factories
11. **Timelock** — Deploy and initialize with Safe as admin/proposer/canceller, open executor, 48h delay
12. **Migrate ownership** — Transfer all protocol contracts to Timelock (`script/MigrateOwnership.s.sol`)

### UUPS Upgrade Pattern

MasterRegistryV1 uses UUPS (Universal Upgradeable Proxy Standard):
- `_authorizeUpgrade()` restricted to owner (Timelock)
- All upgrades go through the 48-hour timelock delay — publicly visible before execution
- Storage layout must be preserved across upgrades — new state variables go at the end
- Proxy delegates all calls to implementation

### Storage Layout Safety

MasterRegistryV1 has grown through multiple iterations. New state variables are always appended after existing ones. Removed features keep their storage slots for layout compatibility (e.g., `dictator`, `abdicationInitiatedAt` slots are preserved but unused).

---

## 10. Security Model

### Timelock Protection

All protocol contracts with `onlyOwner` functions are owned by a Solady Timelock with a 48-hour minimum delay. This prevents instant execution of critical operations — a compromised Safe or malicious proposal cannot upgrade contracts or redirect funds in a single transaction. Users have a credible exit window to observe pending changes and act before they take effect.

### Access Control Summary

| Contract | Owner/Admin | Controls |
|----------|------------|----------|
| **Timelock** | Safe (admin/proposer/canceller) | Schedules all owner-gated operations with enforced delay |
| **MasterRegistryV1** | Timelock | All registrations, alignment targets, upgrades |
| **ProtocolTreasuryV1** | Timelock | Fund disbursements |
| **FeaturedQueueManager** | Timelock | Queue configuration |
| **QueryAggregator** | Timelock | Aggregation configuration |
| **UltraAlignmentVault** | Timelock (new instances) | Pool config, fee params, treasury address |
| **GrandCentral** | Self-governing (daoOnly) | Shares, loot, governance params, conductors |
| **Project Factories** | Protocol + Creator | Instance deployment |
| **Project Instances** | Instance creator (artist) | Withdrawals, configuration |

### Immutability Guarantees

- Instance → Vault binding is **immutable** (set at construction)
- Factory creator address in instances is **immutable**
- External protocol references in vaults (WETH, PoolManager, routers) are **immutable**
- Vault factory creator address is **transferable** (two-step)

### What's Upgradeable vs Permanent

| Upgradeable | Permanent |
|------------|-----------|
| MasterRegistryV1 (UUPS) | UltraAlignmentVault (no proxy) |
| | GrandCentral (no proxy) |
| | All factory/instance contracts |
| | V4 hooks |

### Key Security Properties

- **48-hour timelock** on all owner-gated operations — upgrades, registrations, parameter changes are publicly visible before execution
- **Open executor role** — anyone can trigger execution after delay, preventing the Safe from griefing by refusing to execute
- **Cancellation** — Safe can abort pending operations during the delay window
- Vault fee claims use delta-based accounting (prevents double-claims)
- Conversion rewards capped with M-04 griefing protection (failed transfers don't block operations)
- Name collision prevention via hash-based uniqueness
- Reentrancy guards on all fee-handling functions
- V4 integration uses transient storage pattern (unlock callback)

---

## Contract Directory

```
src/
├── dao/
│   ├── GrandCentral.sol                    # Moloch-pattern DAO
│   ├── conductors/
│   │   └── StipendConductor.sol            # Recurring payment automation
│   └── interfaces/
│       ├── IGrandCentral.sol
│       └── IAvatar.sol                     # Gnosis Safe interface
│
├── master/
│   ├── MasterRegistryV1.sol                # Central registry (UUPS)
│   ├── MasterRegistry.sol                  # Proxy wrapper
│   ├── FeaturedQueueManager.sol            # Competitive rental queue
│   ├── interfaces/
│   │   ├── IMasterRegistry.sol
│   │   └── IFeatureRegistry.sol
│   └── libraries/
│       ├── FeatureUtils.sol
│       └── PricingMath.sol
│
├── factories/
│   ├── erc404/
│   │   ├── ERC404Factory.sol               # Bonding curve factory
│   │   ├── ERC404BondingInstance.sol        # Bonding curve instance
│   │   ├── hooks/
│   │   │   ├── UltraAlignmentV4Hook.sol    # V4 swap tax hook
│   │   │   └── UltraAlignmentHookFactory.sol
│   │   └── libraries/
│   │       └── BondingCurveMath.sol
│   ├── erc1155/
│   │   ├── ERC1155Factory.sol              # Edition factory
│   │   ├── ERC1155Instance.sol             # Edition instance
│   │   └── libraries/
│   │       └── EditionPricing.sol
│   └── erc721/
│       ├── ERC721AuctionFactory.sol        # Auction factory
│       └── ERC721AuctionInstance.sol        # Auction instance
│
├── vaults/
│   └── UltraAlignmentVault.sol             # Share-based fee vault
│
├── registry/
│   ├── VaultRegistry.sol                   # Vault/hook metadata
│   └── GlobalMessageRegistry.sol           # Activity feed
│
├── governance/                             # Legacy (deprecated)
│   ├── FactoryApprovalGovernance.sol
│   ├── VaultApprovalGovernance.sol
│   └── VotingPower.sol
│
├── treasury/
│   └── ProtocolTreasuryV1.sol              # Protocol funds
│
├── promotion/
│   └── PromotionBadges.sol                 # Achievement system
│
├── query/
│   └── QueryAggregator.sol                 # Data aggregation
│
├── interfaces/
│   ├── IAlignmentVault.sol                 # Vault standard interface
│   ├── IFactory.sol                        # Factory template interface
│   ├── IFactoryInstance.sol                # Instance interface
│   └── IInstance.sol
│
├── libraries/
│   ├── GlobalMessagePacking.sol            # Message bit-packing
│   ├── GlobalMessageTypes.sol              # Message type constants
│   └── v4/
│       ├── CurrencySettler.sol             # V4 payment settlement
│       └── LiquidityAmounts.sol            # LP math
│
└── shared/
    ├── libraries/
    │   └── MetadataUtils.sol               # Name/URI validation
    └── interfaces/
        ├── IERC20.sol
        ├── IERC1155.sol
        ├── IERC404.sol
        ├── IHook.sol
        └── ILPConversion.sol
```
