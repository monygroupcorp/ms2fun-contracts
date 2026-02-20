# ms2.fun Protocol Architecture

**Last Updated:** 2026-02-20

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
├── Approves Alignment Targets ──────► AlignmentRegistry
│     (Remilia, Pudgy, etc.)            │
│                                       ├── AlignmentTargets[]
├── Manages Ambassadors                 │     ├── title, description, metadataURI
│                                       │     ├── assets[] (tokens + metadata)
│                                       │     └── ambassadors[] (project wallets)
│                                       │
├── Registers Factories ─────────────► MasterRegistry
│     (ERC404, ERC1155, ERC721)         │
│                                       ├── ProjectFactories[]
├── Deactivates Factories               │     └── active status, IFactory enforced
│                                       │
├── Registers Vaults (or factories do)  ├── VaultInstances[]
│                                       │     └── linked to AlignmentRegistry targetId
│                                       │
└── Manages Protocol Parameters         └── ProjectInstances[]
                                              └── linked to vault, name uniqueness

Project Factories                   Vault Instances
(code templates)                    (per target)
      │                                  ▲
      ▼                                  │ fees
Project Instances ──── fees ────────────►│
(per artist)                             │
      │                                  ▼
      ▼                            Alignment Token
Users (buyers)                     LP Positions
```

### Hierarchy

- **DAO** governs the protocol through proposals and votes
- **Timelock** enforces a 48-hour delay between proposal and execution — gives users an exit window before critical changes take effect
- **AlignmentRegistry** manages alignment targets (community profiles) and ambassadors — DAO curates which communities the protocol supports
- **MasterRegistry** enforces factory/vault/instance registration rules (factory approval, vault binding, name uniqueness)
- **Vault Instances** are deployed vaults, each bound to an approved alignment target
- **Project Factories** are code templates for different project types (ERC404, ERC1155, ERC721)
- **Project Instances** are deployed projects (artist collections), each bound to a vault

### Separation of Concerns

| Contract | Responsibility |
|----------|---------------|
| **AlignmentRegistry** | Curation — which communities the protocol supports (targets + ambassadors) |
| **MasterRegistry** | Registration — phone book for factories, vaults, instances |
| **GlobalMessageRegistry** | Activity feed — protocol-wide event stream |
| **FeaturedQueueManager** | Promotion — competitive rental queue for homepage visibility |

These are independent contracts wired at deployment. MasterRegistry holds a reference to AlignmentRegistry for vault registration validation. Factories receive GlobalMessageRegistry at construction and pass it to instances — no runtime lookups through MasterRegistry.

---

## 3. Alignment Targets & Curation

Alignment Targets are the protocol's curation mechanism. Each target represents an established community whose token the protocol aligns with. Managed by **AlignmentRegistryV1** (UUPS upgradeable, owner is the DAO/Timelock).

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
3. **On approval**, target is registered in AlignmentRegistry — vault instances can now be deployed against it
4. **Vault instances** deployed by anyone (via registered factories) or by the DAO directly. MasterRegistry calls AlignmentRegistry to enforce the vault's alignment token matches an approved target asset
5. **Project connects**: when the target project (e.g., Remilia) reaches out, DAO votes to add their multisig as an **ambassador**
6. **Ambassador powers** are vault-type-dependent — UltraAlignmentVault has no management functions, but future vault types may grant ambassadors operational control

### Ambassador System

Ambassadors are wallets officially provided by the target project. All ambassador changes go through DAO votes. Their powers depend on the vault type:

- **UltraAlignmentVault**: No management functions. Vault activity (buying + LP-ing the target token) IS the upside.
- **Future vault types**: May expose management functions gated by `isAmbassador(targetId, address)`.

### Enforcement

MasterRegistry calls AlignmentRegistry at `registerVault()`:
- Target must exist and be active (`alignmentRegistry.isAlignmentTargetActive(targetId)`)
- Vault's `alignmentToken()` must match a token in the target's asset list (`alignmentRegistry.isTokenInTarget(targetId, token)`)
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

### Direct Wiring Pattern

All factories receive infrastructure addresses at construction (immutable):
- `masterRegistry` — for instance registration and name collision checks
- `globalMessageRegistry` — passed through to instances for activity feed posting

Instances receive `globalMessageRegistry` directly from their factory at construction. There is no runtime lookup through MasterRegistry — this eliminates the service locator anti-pattern and makes dependencies explicit.

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

**Factory family components:**
- `ERC404StakingModule` — factory-scoped singleton accounting backend for vault yield delegation to token stakers. Holds no ETH or tokens — pure accounting keyed by instance address. Authorized via `MasterRegistry.isRegisteredInstance(msg.sender)`, same pattern as `GlobalMessageRegistry`. Deployed once alongside the factory; address passed immutably into every instance at construction. Enabling staking is irreversible — uses `rewardPerTokenStored` accounting (Synthetix model) to correctly handle stakers joining at different times.
- `LiquidityDeployerModule` — V4 liquidity graduation logic. Handles the unlock callback, amount computation, and sqrtPrice calculation for deploying LP positions at graduation.
- `LaunchManager` — Orchestrates instance creation lifecycle including tier perks (promotion badges, featured queue placement). Wired to PromotionBadges and FeaturedQueueManager.
- `CurveParamsComputer` — Computes bonding curve parameters (coefficients, normalization) from graduation profile configuration.

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
| **Project Factory Creator** | Graduation fee share, creation fee share | `creatorGraduationFeeBps`, `creatorFeeBps` |
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

### Conductors

- **StipendConductor** — Autonomous recurring payment system. DAO configures a beneficiary, amount, and interval. Anyone can trigger `execute()` after the interval passes.
- **ShareOffering** — Manages share issuance campaigns for the DAO.
- **RevenueConductor** — Routes protocol revenue to appropriate destinations.

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

- Alignment target approval, deactivation, and updates (via AlignmentRegistry)
- Ambassador management for alignment targets (via AlignmentRegistry)
- Factory registration and deactivation (via MasterRegistry)
- Vault registration (via MasterRegistry, or delegated to active factories)
- Protocol parameter changes
- Treasury disbursements
- UUPS contract upgrades (MasterRegistry, AlignmentRegistry)

Direct DAO actions (no timelock):
- Share and loot distribution
- Conductor role management
- Internal governance parameter changes

---

## 8. Registry & Discovery

### MasterRegistry (UUPS Upgradeable)

The registration layer for the protocol. Owner is the DAO (via Timelock). Holds a reference to AlignmentRegistry for vault validation.

**Manages:**
- Project factories (registration, active/inactive status, deactivation)
- Vault instances (linked to alignment targets via AlignmentRegistry)
- Project instances (linked to vaults, name collision prevention)

**Does NOT manage (moved to separate contracts):**
- Alignment targets and ambassadors → AlignmentRegistry
- Global messaging → GlobalMessageRegistry (wired directly to factories/instances)
- Featured queue → FeaturedQueueManager (standalone)

**Enforcement at registration:**
- Factories: must implement `IFactory` with `creator()` and `protocol()`
- Instances: must have immutable vault matching declaration, must have protocol treasury, factory must be active
- Vaults: must point to approved and active alignment target (checked via AlignmentRegistry) with matching token

**Factory lifecycle:**
- `registerFactory()` — owner-only, requires IFactory compliance
- `deactivateFactory()` — owner-only, prevents new instance/vault registration through that factory
- Once deactivated, existing instances continue to function but no new ones can be created

**Vault registration access control:**
- Registered active factories can call `registerVault()` directly (factory path)
- Owner (DAO/Timelock) can also call `registerVault()` for singleton vaults (owner path)

### AlignmentRegistry (UUPS Upgradeable)

Standalone contract for curation. Owner is the DAO (via Timelock).

**Manages:**
- Alignment targets (register, update, deactivate)
- Alignment assets per target (tokens with metadata)
- Ambassadors per target (add, remove, query)

Queried by MasterRegistry during vault registration to validate target/token alignment.

### FeaturedQueueManager

Competitive rental queue for homepage visibility. Instances rent featured positions by paying ETH with rank-based ordering. Higher ETH commitment = higher rank. Supports rank boosting and duration renewal.

### GlobalMessageRegistry

Protocol-wide activity feed. Instances post structured messages (buys, sells, mints, etc.) with encoded metadata. Enables trending detection and social discovery with single RPC calls.

Auto-authorized: instances from registered factories are automatically authorized to post messages (checked via `MasterRegistry.isRegisteredInstance()`).

### VaultRegistry

Standalone registry for vault and hook metadata. Handles registration fees (0.05 ETH vaults, 0.02 ETH hooks) and basic metadata tracking. Separate from MasterRegistry's alignment enforcement.

---

## 9. Deployment & Upgrade

### Deploy Order

1. **MasterRegistryV1** — Deploy implementation, then proxy with `initialize(daoOwner)`
2. **AlignmentRegistryV1** — Deploy, initialize with daoOwner, wire to MasterRegistry via `setAlignmentRegistry()`
3. **GrandCentral** — Deploy with Safe address, founder shares, governance params
4. **ProtocolTreasuryV1** — Deploy protocol treasury
5. **GlobalMessageRegistry** — Deploy with owner + masterRegistry reference
6. **FeaturedQueueManager** — Deploy, initialize with masterRegistry + owner
7. **VaultRegistry** — Deploy standalone
8. **Alignment Targets** — Register via AlignmentRegistry (DAO or owner during bootstrap)
9. **Project Factories** — Deploy with masterRegistry + globalMessageRegistry, register in MasterRegistry
10. **Vault Instances** — Deploy for approved targets, register via MasterRegistry
11. **Timelock** — Deploy and initialize with Safe as admin/proposer/canceller, open executor, 48h delay
12. **Migrate ownership** — Transfer MasterRegistry, AlignmentRegistry, and all protocol contracts to Timelock

### UUPS Upgrade Pattern

MasterRegistryV1 and AlignmentRegistryV1 use UUPS (Universal Upgradeable Proxy Standard):
- `_authorizeUpgrade()` restricted to owner (Timelock)
- All upgrades go through the 48-hour timelock delay — publicly visible before execution
- Storage layout must be preserved across upgrades — new state variables go at the end
- Proxy delegates all calls to implementation

---

## 10. Security Model

### Timelock Protection

All protocol contracts with `onlyOwner` functions are owned by a Solady Timelock with a 48-hour minimum delay. This prevents instant execution of critical operations — a compromised Safe or malicious proposal cannot upgrade contracts or redirect funds in a single transaction. Users have a credible exit window to observe pending changes and act before they take effect.

### Access Control Summary

| Contract | Owner/Admin | Controls |
|----------|------------|----------|
| **Timelock** | Safe (admin/proposer/canceller) | Schedules all owner-gated operations with enforced delay |
| **AlignmentRegistryV1** | Timelock | Alignment targets, ambassadors, upgrades |
| **MasterRegistryV1** | Timelock | Factory/vault/instance registration, factory deactivation, upgrades |
| **ProtocolTreasuryV1** | Timelock | Fund disbursements |
| **FeaturedQueueManager** | Timelock | Queue configuration |
| **QueryAggregator** | Timelock | Aggregation configuration |
| **UltraAlignmentVault** | Timelock (new instances) | Pool config, fee params, treasury address |
| **GrandCentral** | Self-governing (daoOnly) | Shares, loot, governance params, conductors |
| **Project Factories** | Protocol + Creator | Instance deployment, fee withdrawal |
| **Project Instances** | Instance creator (artist) | Withdrawals, configuration |

### Immutability Guarantees

- Instance → Vault binding is **immutable** (set at construction)
- Instance → GlobalMessageRegistry reference is **immutable** (set at construction via factory)
- Factory creator address in instances is **immutable**
- External protocol references in vaults (WETH, PoolManager, routers) are **immutable**
- Vault factory creator address is **transferable** (two-step)

### What's Upgradeable vs Permanent

| Upgradeable | Permanent |
|------------|-----------|
| MasterRegistryV1 (UUPS) | UltraAlignmentVault (no proxy) |
| AlignmentRegistryV1 (UUPS) | GrandCentral (no proxy) |
| | All factory/instance contracts |
| | V4 hooks |

### Key Security Properties

- **48-hour timelock** on all owner-gated operations — upgrades, registrations, parameter changes are publicly visible before execution
- **Open executor role** — anyone can trigger execution after delay, preventing the Safe from griefing by refusing to execute
- **Cancellation** — Safe can abort pending operations during the delay window
- **Factory deactivation** — DAO can disable compromised or deprecated factories, preventing new instance/vault creation while existing instances continue functioning
- Vault fee claims use delta-based accounting (prevents double-claims)
- Conversion rewards capped with M-04 griefing protection (failed transfers don't block operations)
- Name collision prevention via hash-based uniqueness (case-insensitive, cross-factory)
- Reentrancy guards on all fee-handling functions
- V4 integration uses transient storage pattern (unlock callback)

---

## Contract Directory

```
src/
├── dao/
│   ├── GrandCentral.sol                    # Moloch-pattern DAO
│   ├── conductors/
│   │   ├── StipendConductor.sol            # Recurring payment automation
│   │   ├── ShareOffering.sol               # Share issuance campaigns
│   │   └── RevenueConductor.sol            # Protocol revenue routing
│   └── interfaces/
│       ├── IGrandCentral.sol
│       └── IAvatar.sol                     # Gnosis Safe interface
│
├── master/
│   ├── MasterRegistryV1.sol                # Central registry (UUPS) — factories, vaults, instances
│   ├── MasterRegistry.sol                  # Proxy wrapper
│   ├── AlignmentRegistryV1.sol             # Alignment targets & ambassadors (UUPS)
│   ├── FeaturedQueueManager.sol            # Competitive rental queue
│   ├── interfaces/
│   │   ├── IMasterRegistry.sol
│   │   ├── IAlignmentRegistry.sol          # Alignment target/asset/ambassador interface
│   │   └── IFeatureRegistry.sol
│   └── libraries/
│       ├── FeatureUtils.sol
│       └── PricingMath.sol
│
├── factories/
│   ├── erc404/
│   │   ├── ERC404Factory.sol               # Bonding curve factory
│   │   ├── ERC404BondingInstance.sol        # Bonding curve instance (thin coordinator)
│   │   ├── ERC404StakingModule.sol          # Singleton yield delegation companion
│   │   ├── LaunchManager.sol               # Instance creation lifecycle orchestrator
│   │   ├── CurveParamsComputer.sol          # Bonding curve parameter computation
│   │   ├── LiquidityDeployerModule.sol      # V4 graduation liquidity deployment
│   │   ├── hooks/
│   │   │   ├── UltraAlignmentV4Hook.sol
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
│   ├── GlobalMessageRegistry.sol           # Activity feed
│   └── interfaces/
│       └── IGlobalMessageRegistry.sol      # Message registry interface
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
│   ├── IInstance.sol
│   └── IInstanceLifecycle.sol              # Instance lifecycle hooks
│
├── libraries/
│   ├── MessageTypes.sol                    # Message type constants
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
