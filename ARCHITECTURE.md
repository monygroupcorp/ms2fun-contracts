# ms2.fun Protocol Architecture

**Last Updated:** 2026-03-12

---

## 1. Protocol Overview

ms2.fun is a curated launchpad for derivative art and tokens aligned to established crypto communities. Artists create projects (ERC404 bonding curves, ERC1155 editions, ERC721 auctions) that are structurally bound to alignment vaults. These vaults accumulate fees from all project activity, convert them to the target community's token, and deposit full-range Uniswap V4 LP positions — creating permanent buying pressure and liquidity for the aligned asset.

The protocol curates which communities receive vaults through DAO governance. At launch, the team selects initial alignment targets (e.g., Remilia/CULT, Pudgy Penguins). Over time, DAO shareholders propose and vote on new targets. Projects that don't merit alignment don't get vault space.

A single fee rule applies across all product types: **1% → protocol treasury, 19% → alignment vault, 80% → artist**. This is applied at every settlement event. No creation fees. The 20% alignment contribution is the protocol's cultural and economic contract with artists — tithing toward the community they're aligned with.

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

## 2.5. Protocol Layers

The protocol organises into five layers by trust level, risk surface, and who controls each tier. Higher layers = closer to capital and governance. Lower layers = closer to end users.

```
┌─────────────────────────────────────────────────────────────────────┐
│  L0 · C-SUITE / SHAREHOLDERS                                        │
│                                                                     │
│  GrandCentral (DAO)  ·  Gnosis Safe  ·  ShareOffering              │
│  StipendConductor    ·  Ragequit Pool                               │
│                                                                     │
│  Who: shareholders, multisig signers, protocol contributors         │
│  Controls: votes, share issuance, stipends, Safe execution          │
└───────────────────────────┬─────────────────────────────────────────┘
                            │ proposals pass through Timelock (48h)
┌───────────────────────────▼─────────────────────────────────────────┐
│  L1 · DAO OPERATIONS / TREASURY                                     │
│                                                                     │
│  Timelock              ·  ProtocolTreasuryV1                        │
│  AlignmentRegistryV1   ·  RevenueConductor                          │
│  FeaturedQueueManager                                               │
│                                                                     │
│  Who: Timelock (executor), DAO governance                           │
│  Controls: curation (targets, ambassadors), treasury disbursements, │
│            protocol revenue collection, homepage promotion rules    │
└───────────────────────────┬─────────────────────────────────────────┘
                            │ registrations enforced at this layer
┌───────────────────────────▼─────────────────────────────────────────┐
│  L2 · PROTOCOL INFRASTRUCTURE + TVL                                 │
│                                                                     │
│  MasterRegistryV1    ·  ComponentRegistry   ·  VaultRegistry        │
│  GlobalMessageRegistry · FrontendRegistry  ·  QueryAggregator       │
│                                                                     │
│  UniAlignmentVault   ·  ZAMMAlignmentVault  ·  CypherAlignmentVault │
│                                                                     │
│  Who: DAO-approved; vaults submitted by devs but DAO-registered     │
│  Controls: all registration enforcement, activity feed, TVL custody │
│                                                                     │
│  Vaults rank here (not with factories) because they hold alignment  │
│  capital. A buggy vault destroys TVL permanently; a buggy factory   │
│  only affects new instance creation.                                │
└───────────────────────────┬─────────────────────────────────────────┘
                            │ factories + components submitted here
┌───────────────────────────▼─────────────────────────────────────────┐
│  L3 · DEVELOPER SUBMISSIONS (code, not capital)                     │
│                                                                     │
│  ERC404Factory  ·  ERC1155Factory  ·  ERC721AuctionFactory          │
│  Vault factory deployers  ·  LaunchManager (graduation presets)     │
│  ERC404StakingModule  ·  Gating modules  ·  Liquidity deployers     │
│  CurveParamsComputer  ·  other ICurveComputer implementations       │
│                                                                     │
│  Who: protocol team and external developers                         │
│  Controls: project creation logic, component slots, bonding params  │
│  All must be approved by DAO (ComponentRegistry / MasterRegistry)   │
└───────────────────────────┬─────────────────────────────────────────┘
                            │ createInstance() produces instances
┌───────────────────────────▼─────────────────────────────────────────┐
│  L4 · ARTISTS & COLLECTORS                                          │
│                                                                     │
│  ERC404BondingInstance  ·  ERC1155Instance  ·  ERC721AuctionInstance│
│                                                                     │
│  Artists:     withdraw(), settleAuction(), claimAllFees(),          │
│               activateStaking(), claimAlignmentYield()              │
│  Collectors:  buy/mint, stake(), unstake(), claimStakingRewards(),  │
│               bid on auctions                                       │
│                                                                     │
│  Who: end users interacting directly with deployed instances        │
└─────────────────────────────────────────────────────────────────────┘
```

### Key Cross-Layer Interactions

| From | To | Mechanism |
|------|----|-----------|
| L0 Safe | L1 Timelock | `propose()` → 48h delay → `execute()` |
| L1 Timelock | L2 MasterRegistry | `registerFactory()`, `registerVault()` |
| L1 Timelock | L2 ComponentRegistry | `approveComponent()` |
| L1 Timelock | L1 AlignmentRegistry | `registerAlignmentTarget()` |
| L3 Factory | L2 MasterRegistry | `registerInstance()` during `createInstance()` |
| L3 Factory | L1 AlignmentRegistry | read-only target validation via MasterRegistry |
| L4 Instance | L2 Vault | `receiveContribution()` (fees), `claimFees()` (yield) |
| L4 Instance | L2 GlobalMessageRegistry | `postMessage()` (immutable wiring, no lookup) |
| L4 Collector | L3 Factory | `createInstance()` only — then interacts with instance directly |

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
6. **Ambassador powers** are vault-type-dependent — UniAlignmentVault has no management functions, but future vault types may grant ambassadors operational control

### Ambassador System

Ambassadors are wallets officially provided by the target project. All ambassador changes go through DAO votes. Their powers depend on the vault type:

- **UniAlignmentVault**: No management functions. Vault activity (buying + LP-ing the target token) IS the upside.
- **Future vault types**: May expose management functions gated by `isAmbassador(targetId, address)`.

### Enforcement

MasterRegistry calls AlignmentRegistry at `registerVault()`:
- Target must exist and be active (`alignmentRegistry.isAlignmentTargetActive(targetId)`)
- Vault's `alignmentToken()` must match a token in the target's asset list (`alignmentRegistry.isTokenInTarget(targetId, token)`)
- Multiple vault instances per target are allowed (different strategies, different factories)

---

## 4. Vault System

Vaults are the economic engine of the protocol. They collect fees from all project activity, convert them to the target community's token, and deposit LP positions. Three vault strategies exist — each targeting a different DEX.

### Terminology

| Term | Definition |
|------|-----------|
| **Vault Factory** | Code template for a vault strategy |
| **Vault Instance** | Deployed vault configured for a specific alignment target |
| **Benefactor** | A project instance that contributes fees to the vault |

### Vault Strategies

| Vault | Location | DEX | Status |
|-------|----------|-----|--------|
| **UniAlignmentVault** | `src/vaults/uni/` | Uniswap V4 | Primary |
| **ZAMMAlignmentVault** | `src/vaults/zamm/` | ZAMM | Alternative |
| **CypherAlignmentVault** | `src/vaults/cypher/` | Algebra V2 | Cypher chain |

### UniAlignmentVault (`src/vaults/uni/`)

The primary vault implementation. Uniswap V4 full-range LP with share-based fee distribution and O(1) claims. Implements `IUnlockCallback` for V4 LP operations. Hook integration via `UniAlignmentV4Hook` — post-graduation swap tax flows from the hook directly to the vault.

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
protocolYieldCutBps (default 100 = 1%) → protocol treasury
benefactors get the rest (99%)
```

**V4 Integration:** All `modifyLiquidity` calls occur within `unlockCallback`. Full-range positions (min/max usable ticks). Currency settlement via `CurrencySettler` library.

### ZAMMAlignmentVault (`src/vaults/zamm/`)

ZAMM-based LP vault. Simplified dragnet conversion — same benefactor share accounting model as UniAlignmentVault, but targets ZAMM pools instead of Uniswap V4. Deployed via `ZAMMAlignmentVaultFactory`.

### CypherAlignmentVault (`src/vaults/cypher/`)

Algebra V2 LP vault for the Cypher chain. Same benefactor share model; targets Algebra V2 pools. Deployed via `CypherAlignmentVaultFactory`, which is used by `ERC404CypherFactory`.

### Benefactor Delegation

Benefactors (project instances) can delegate fee claims to another address:
- `delegateBenefactor(delegate)` — route claims to a different address
- `claimFeesAsDelegate(benefactors[])` — batch claim for multiple benefactors

### Multi-Vault Instance Support

Multiple vault instances per alignment target are supported. A single target (e.g., Remilia) can have multiple vaults deploying to different DEXes simultaneously. MasterRegistry tracks all instances linked to each target.

---

## 5. Factory System

Factories create project instances. Three factory types serve different use cases. All three follow the same structural doctrine.

### Factory Doctrine

Every factory follows the same pattern:

**Single entry point.** One `createInstance(...)` function. No overloads, no tier variants.

**Factory-local `CreateParams` struct.** Each factory defines its own `CreateParams` — not in a shared interface — because the fields are project-specific.

**Component-validated inputs.** User-supplied module addresses (gating module, liquidity deployer, staking module) are validated against `ComponentRegistry.isApprovedComponent()` at call time. Only DAO-approved components are accepted. The check is tag-agnostic — any approved address passes, regardless of which component tag it was approved under.

**Fees forwarded directly to treasury.** Any `msg.value` sent to a factory is forwarded immediately to `protocolTreasury` before any other work. Factories hold no ETH.

**Agents call instances directly.** Factory relay functions do not exist. When a caller is not the declared owner, the factory checks `masterRegistry.isAgent(msg.sender)`. If the check passes, agent delegation is enabled on the deployed instance via `setAgentDelegationFromFactory()`.

**Promotion is external.** FeaturedQueueManager and PromotionBadges are not wired to factories in any way.

**Factory registers the instance.** After deploying via CreateX CREATE3, the factory calls `masterRegistry.registerInstance()`. That is the factory's final act.

**Direct wiring.** All factories receive `masterRegistry` and `globalMessageRegistry` at construction. These are passed through to instances — no runtime lookup through MasterRegistry. This eliminates the service locator anti-pattern.

### Component System

`ComponentRegistry` (UUPS upgradeable, owned by DAO via Timelock) is the DAO-governed approval list for pluggable factory components.

**Component tags** (defined as constants in `FeatureUtils`):

| Constant | Tag hash |
|----------|---------|
| `GATING` | `keccak256("gating")` |
| `LIQUIDITY_DEPLOYER` | `keccak256("liquidity")` |
| `STAKING` | `keccak256("staking")` |
| `DYNAMIC_PRICING` | `keccak256("dynamic_pricing")` |
| *(also)* | `keccak256("curve")` |

Each factory advertises which component slots it supports via `features()` and which are required via `requiredFeatures()`. Callers can query these to know which slots must be filled and which are optional.

### ERC404 Bonding Factory (`src/factories/erc404/ERC404Factory.sol`)

Creates hybrid ERC20/ERC721 tokens with bonding curves. A single `ERC404Factory` works with any DAO-approved liquidity deployer — artists choose their deployer at instance creation time.

**Signature:**
```solidity
function createInstance(
    CreateParams calldata params,
    string calldata metadataURI,
    address liquidityDeployer,
    address gatingModule,
    FreeMintParams calldata freeMint
) external payable returns (address instance)
```

**`CreateParams`:**
```solidity
struct CreateParams {
    bytes32 salt;
    string name;
    string symbol;
    string styleUri;
    address owner;
    address vault;
    uint256 nftCount;
    uint8 presetId;
    address stakingModule; // address(0) = staking not available for this instance
}
```

**`features()`:** `[GATING, LIQUIDITY_DEPLOYER, STAKING]`
**`requiredFeatures()`:** `[LIQUIDITY_DEPLOYER]`

**Component slots:**
- `liquidityDeployer` — required. Validated against ComponentRegistry. Handles LP deployment at graduation. Implements `ILiquidityDeployerModule`.
- `gatingModule` — optional. `address(0)` = open access. Controls who can participate (paid minting, free minting, or both), gated by a DAO-approved `IGatingModule`.
- `stakingModule` — optional. `address(0)` = staking unavailable for this instance.

**`FreeMintParams`** (shared struct in `IFactoryTypes.sol`, used by ERC404 and ERC1155):
```solidity
struct FreeMintParams {
    uint256 allocation; // NFT count reserved for zero-cost claims (0 = disabled)
    GatingScope scope;  // BOTH | FREE_MINT_ONLY | PAID_ONLY
}
```
`scope` controls which entry points the gating module guards. `allocation` NFTs are reserved for zero-cost claims; these are excluded from the bonding curve supply when computing curve parameters.

**Bonding curve preset:**
Curve shape is determined by a `LaunchManager` preset identified by `params.presetId`. The preset holds `targetETH`, `unitPerNFT`, `liquidityReserveBps`, and the address of a `ICurveComputer` implementation. The factory calls the computer once at creation to derive `BondingCurveMath.Params`; thereafter the instance uses `BondingCurveMath` directly — no stored curve computer reference on the instance. The preset's curve computer is also validated against ComponentRegistry.

**Instance lifecycle:**
1. Artist calls `createInstance()`, selecting a vault, preset, liquidity deployer, and optional gating/staking modules
2. Factory validates all component addresses, forwards any `msg.value` to treasury, deploys instance via CREATE3, calls `masterRegistry.registerInstance()`
3. If `stakingModule != address(0)`, factory calls `instance.initializeStaking(stakingModule)` after registration (module's `enableStaking` checks `isRegisteredInstance`, so it must run post-registration)
4. Instance is live: users buy tokens on the bonding curve (`buyBonding()`); bonding fees (default 1%) accumulate in the reserve
5. At graduation threshold, anyone triggers `deployLiquidity()` — the chosen deployer handles LP setup: 1% of raise → protocol treasury, 19% → vault via `receiveContribution`, 80% → LP pool

**Staking lifecycle:**
The staking module (`ERC404StakingModule`) is a singleton accounting backend. It holds no ETH or tokens. All state is keyed by instance address.

- **`initializeStaking(module)`** — called by factory post-registration. Wires the module address into the instance.
- **`activateStaking()`** — called by the instance owner post-deploy. Irreversible. Calls `stakingModule.enableStaking()`, which requires the instance to already be registered.
- Once active: users stake ERC20 tokens in the instance. The module tracks balances using a Synthetix `rewardPerToken` model (`rewardPerTokenStored` accumulates ETH-per-staked-token scaled 1e18; `rewardPerTokenPaid` is a per-user checkpoint).
- **Fee flow**: vault LP yield accrues → instance owner calls `claimAllFees()` → ETH lands in instance → instance calls `stakingModule.recordFeesReceived(delta)` → stakers claim via `claimStakingRewards()`.

**VaultCapabilityWarning:** The factory emits `VaultCapabilityWarning(vault, keccak256("YIELD_GENERATION"))` if the vault does not report `YIELD_GENERATION` support. This is a soft check — it emits and continues, does not revert.

**Factory family components:**
- `LaunchManager` — holds presets only. No tier perks. Preset gives `targetETH`, `unitPerNFT`, `liquidityReserveBps`, `curveComputer`.
- `CurveParamsComputer` — default `ICurveComputer` implementation. Computes bonding curve parameters (coefficients, normalization) from preset configuration.
- `ComponentRegistry` — DAO-governed approval list consulted at creation time.

### ERC1155 Edition Factory (`src/factories/erc1155/ERC1155Factory.sol`)

Creates open-edition or limited-edition NFTs for artists.

**Signature:**
```solidity
function createInstance(
    bytes32 salt,
    CreateParams calldata params
) external payable returns (address instance)
```

**`CreateParams`:**
```solidity
struct CreateParams {
    string name;
    string metadataURI;
    address creator;
    address vault;
    string styleUri;
    address gatingModule;    // address(0) = open
    FreeMintParams freeMint;
}
```

**`features()`:** `[GATING]` (also includes `DYNAMIC_PRICING` lazily when a dynamic pricing module is set on the factory)
**`requiredFeatures()`:** `[]`

**Component slots:**
- `gatingModule` — optional, validated against ComponentRegistry if non-zero.

**Pricing models** — plugged in post-deploy by the creator on the instance:
- `UNLIMITED` — fixed price, infinite supply
- `LIMITED_FIXED` — fixed price, capped supply
- `LIMITED_DYNAMIC` — dynamic pricing via `DynamicPricingModule` (a DAO-approved component set on the factory, wired to instances at construction)

**Instance lifecycle:**
1. Creator calls `createInstance()`, selecting a vault and optional gating module
2. Factory validates, deploys via CREATE3, registers
3. Creator configures pricing model on the instance
4. Users mint; on withdrawal: 1% → protocol treasury, 19% → vault, 80% → artist

### ERC721 Auction Factory (`src/factories/erc721/ERC721AuctionFactory.sol`)

Creates multi-line auction-based NFT drops.

**Signature:**
```solidity
function createInstance(
    bytes32 salt,
    CreateParams calldata params
) external payable returns (address instance)
```

**`CreateParams`:**
```solidity
struct CreateParams {
    string name;
    string metadataURI;
    address creator;
    address vault;
    string symbol;
    uint8 lines;          // number of parallel auction lines
    uint40 baseDuration;
    uint40 timeBuffer;
    uint256 bidIncrement;
}
```

**`features()`:** `[]`
**`requiredFeatures()`:** `[]`

No pluggable component slots. The `lines` parameter determines how many parallel auction lines run simultaneously. On settlement: 1% of winning bid → protocol treasury, 19% → vault, 80% → artist, plus creator deposit refunded.

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

A single rule governs all revenue: **1% protocol treasury, 19% alignment vault, 80% artist**, applied at every settlement event. The cultural precedent is tithing — artists contribute 20% of proceeds toward the community they're aligned with. The 1/19 split ensures protocol sustainability without obscuring the alignment story.

### Fee Flow Diagram

```
User Activity
│
├── ERC404 Bonding Purchase
│     ├── bondingFeeBps (1%) ──────────────► Instance reserve (not extracted)
│     └── remainder ──────────────────────► Instance reserve
│
├── ERC404 Graduation (liquidity deployment)
│     ├── 1% of raise ────────────────────► Protocol Treasury
│     ├── 19% of raise ───────────────────► Vault (receiveContribution)
│     └── 80% of raise ───────────────────► LP pool
│
├── ERC404 Post-Graduation Swaps
│     └── Hook Tax ───────────────────────► Vault (accumulates; no extraction)
│
├── ERC1155 Withdrawal
│     ├── 1% ─────────────────────────────► Protocol Treasury
│     ├── 19% ────────────────────────────► Vault (receiveContribution)
│     └── 80% ────────────────────────────► Artist
│
├── ERC721 Auction Settlement
│     ├── 1% of winning bid ──────────────► Protocol Treasury
│     ├── 19% of winning bid ─────────────► Vault (receiveContribution)
│     └── 80% of winning bid ─────────────► Artist
│           + creator deposit refunded
│
└── Vault LP Yield
      ├── protocolYieldCutBps (1%) ───────► Protocol Treasury
      └── benefactor share (99%) ─────────► Project Instances (proportional)
```

### Who Gets Paid

| Participant | Revenue Source | Mechanism |
|-------------|--------------|-----------|
| **Protocol Treasury** | 1% of every settlement, 1% of vault LP yield | Direct transfers |
| **Alignment Vault** | 19% of every settlement | `receiveContribution()`, earns LP yield |
| **Artist** | 80% of every settlement + vault fee claims proportional to contributions | Instance-level extraction |
| **Alignment Target** | No direct fee. Vault buying pressure on their token IS the upside | Structural benefit |

### Serial Creator Yield Model

Artists tithe 19% of proceeds from each project to the vault. The vault deploys contributions as LP for the alignment target's token. Artists earn back 99% of vault LP yield proportional to their benefactor shares. At 10–20% APY across 12+ projects, this becomes a genuine passive income stream — the tithing model rewards prolific creators who build a body of aligned work.

### Protocol Treasury

`ProtocolTreasuryV1` holds protocol funds. Receives fees from multiple sources across the system.

---

## 7. Governance (GrandCentral)

GrandCentral is a Mol***-pattern DAO that governs the protocol through a Gnosis Safe.

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
- Factories: must implement `IFactory` with `protocol()`
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

Competitive rental queue for homepage visibility. Instances rent featured positions by paying ETH with rank-based ordering. Higher ETH commitment = higher rank. Supports rank boosting and duration renewal. All ETH from `rentFeatured`, `boostRank`, and `renewDuration` is forwarded directly to `protocolTreasury` — the contract holds no funds.

### GlobalMessageRegistry

Protocol-wide activity feed. Instances post structured messages (buys, sells, mints, etc.) with encoded metadata. Enables trending detection and social discovery with single RPC calls.

Auto-authorized: instances from registered factories are automatically authorized to post messages (checked via `MasterRegistry.isRegisteredInstance()`).

### VaultRegistry

Standalone registry for vault and hook metadata. Handles registration fees (0.05 ETH vaults, 0.02 ETH hooks) and basic metadata tracking. Separate from MasterRegistry's alignment enforcement.

---

## 8.5. Frontend Registry

`FrontendRegistry` (`src/registry/FrontendRegistry.sol`) is an ENS controller for decentralized frontend versioning. UUPS upgradeable, owned by the DAO via Timelock. All mutations require `onlyOwner` (Timelock).

### How It Works

- **Append-only release log**: Each `publishRelease()` call stores a `Release` record (release type, IPFS content hash, version string, notes, and optional contract addresses that shipped with the release).
- **Release types**: `SITE_ONLY` for frontend-only changes; `ECOSYSTEM` when new contracts ship alongside the frontend update.
- **ENS node management**: The registry manages a list of ENS nodes (e.g., `ms2.fun`, `app.ms2.fun`). Each node can independently be pointed at any release via `pointNodeToRelease()`.
- **Atomic publish**: `publishRelease()` accepts a list of nodes to update immediately — stores the release and updates ENS content hashes atomically.
- **Managed node set**: `addEnsName()` / `removeEnsName()` maintain the controlled ENS namespace. Only managed nodes can be steered.

### Key Properties

- Release IDs are 1-indexed uint32 values; 0 means no release assigned to a node.
- Content hashes are IPFS hashes encoded per ENS contenthash spec.
- Historical releases are permanent and queryable — the full deploy history is on-chain.
- No contract address validation on `contracts[]` in a release — this is metadata only.

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
8. **FrontendRegistry** — Deploy implementation, then proxy with `initialize(daoOwner, ensResolver)`
9. **ComponentRegistry** — Deploy implementation, then proxy with `initialize(daoOwner)`. Approve DAO-vetted deployers and gating modules.
10. **Alignment Targets** — Register via AlignmentRegistry (DAO or owner during bootstrap)
11. **Project Factories** — Deploy with masterRegistry + globalMessageRegistry + componentRegistry, register in MasterRegistry
12. **Vault Instances** — Deploy for approved targets, register via MasterRegistry
13. **Timelock** — Deploy and initialize with Safe as admin/proposer/canceller, open executor, 48h delay
14. **Migrate ownership** — Transfer MasterRegistry, AlignmentRegistry, ComponentRegistry, FrontendRegistry, and all protocol contracts to Timelock

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
| **FrontendRegistry** | Timelock | ENS name management, release publishing, node steering |
| **UniAlignmentVault** | Timelock (new instances) | Pool config, fee params, treasury address |
| **ZAMMAlignmentVault** | Timelock (new instances) | Pool config, fee params, treasury address |
| **ComponentRegistry** | Timelock | Component approval/revocation for pluggable factory slots |
| **GrandCentral** | Self-governing (daoOnly) | Shares, loot, governance params, conductors |
| **Project Factories** | Protocol + Creator | Instance deployment, fee withdrawal |
| **Project Instances** | Instance creator (artist) | Withdrawals, configuration |

### Immutability Guarantees

- Instance → Vault binding is **immutable** (set at construction)
- Instance → GlobalMessageRegistry reference is **immutable** (set at construction via factory)
- External protocol references in vaults (WETH, PoolManager, routers) are **immutable**

### What's Upgradeable vs Permanent

| Upgradeable | Permanent |
|------------|-----------|
| MasterRegistryV1 (UUPS) | UniAlignmentVault (no proxy) |
| AlignmentRegistryV1 (UUPS) | ZAMMAlignmentVault (no proxy) |
| FrontendRegistry (UUPS) | GrandCentral (no proxy) |
| ComponentRegistry (UUPS) | All factory/instance contracts |
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
│   ├── GrandCentral.sol                    # Mol***-pattern DAO
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
│       └── FeatureUtils.sol
│
├── factories/
│   ├── erc404/
│   │   ├── ERC404Factory.sol               # Bonding curve factory (AMM-agnostic)
│   │   ├── ERC404BondingInstance.sol        # Bonding curve instance
│   │   ├── LaunchManager.sol               # Graduation preset management
│   │   ├── CurveParamsComputer.sol          # Default ICurveComputer implementation
│   │   ├── hooks/
│   │   │   ├── UniAlignmentV4Hook.sol
│   │   │   └── UniAlignmentHookFactory.sol
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
│   ├── uni/
│   │   ├── UniAlignmentVault.sol           # Uniswap V4 full-range LP vault
│   │   └── UniAlignmentVaultFactory.sol    # Factory for Uni V4 vaults
│   ├── zamm/
│   │   ├── ZAMMAlignmentVault.sol          # ZAMM LP vault
│   │   └── ZAMMAlignmentVaultFactory.sol   # Factory for ZAMM vaults
│   └── cypher/
│       ├── CypherAlignmentVault.sol        # Algebra V2 LP vault (Cypher chain)
│       └── CypherAlignmentVaultFactory.sol # Factory for Cypher vaults
│
├── registry/
│   ├── FrontendRegistry.sol                # ENS controller for frontend versioning (UUPS)
│   ├── VaultRegistry.sol                   # Vault/hook metadata
│   ├── GlobalMessageRegistry.sol           # Activity feed
│   └── interfaces/
│       ├── IFrontendRegistry.sol           # Frontend registry interface
│       ├── IENSResolver.sol                # ENS resolver interface
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
│   ├── IFactory.sol                        # Factory template interface (includes features())
│   ├── IFactoryInstance.sol                # Instance interface
│   ├── IInstance.sol
│   ├── IInstanceLifecycle.sol              # Instance lifecycle hooks
│   ├── ICurveComputer.sol                  # Pluggable bonding curve parameter computer
│   ├── ILiquidityDeployerModule.sol        # Pluggable graduation liquidity deployer
│   ├── IERC404StakingModule.sol            # ERC404 staking module interface
│   └── IFactoryTypes.sol                  # Shared structs (IdentityParams, FreeMintParams)
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

---

## Appendix: Rounding Direction Reference

All integer division in this codebase rounds **down** (Solidity default floor division). Every division site is annotated inline with `// round down: <rationale>`. The table below provides a consolidated reference for auditors.

### Design Principle

**Floor-rounding always favors the pool/protocol/vault** — never the individual claimant. Rounding dust either stays in the shared pool (preventing over-withdrawal) or is absorbed by the remainder term in subtraction-based splits.

### Revenue Split (RevenueSplitLib)

| Expression | Favors | Dust Absorption |
|---|---|---|
| `amount / 100` (1% protocol) | Artist (remainder) | `remainder = amount - protocol - vault` absorbs all dust |
| `amount * 19 / 100` (19% vault) | Artist (remainder) | Same — subtraction ensures exact conservation |

### MasterChef / RewardPerToken Accumulators

Used in: GrandCentral, ZAMMAlignmentVault, CypherAlignmentVault, ERC404StakingModule

| Expression | Favors | Rationale |
|---|---|---|
| `rewardPerShare += amount * PRECISION / totalWeight` | Pool | Dust stays unclaimed in pool |
| `rewardDebt = weight * rewardPerShare / PRECISION` | Pool | Member can never over-claim |
| `pending = weight * rewardPerShare / PRECISION - rewardDebt` | Pool | Same floor; consistent with debt snapshot |

### Share-Based Distribution (UniAlignmentVault)

| Expression | Favors | Rationale |
|---|---|---|
| `sharePercent = contribution * 1e18 / ethToAdd` | Vault | Dust tracked in `accumulatedDustShares` |
| `sharesToIssue = totalShares * sharePercent / 1e18` | Vault | Dust redistributed to largest contributor |
| `currentShareValue = fees * shares / totalShares` | Vault | Benefactor cannot withdraw more than pool holds |

### Basis-Point Fees

| Expression | Favors | Rationale |
|---|---|---|
| `protocolCut = total * protocolYieldCutBps / 10000` | Benefactors | Protocol takes slightly less; `benefactorAmount = total - protocolCut` absorbs dust |
| `bondingFee = totalCost * bondingFeeBps / 10000` | Buyer | Buyer pays slightly less; fee is additive so no conservation issue |
| `hookFee = ethMoved * hookFeeBips / 10000` | Swapper | Swapper pays slightly less |
| `reserveAmount = available * reserveBps / 10000` | Routable pool | Slightly more goes to dividend/ragequit |

### Time-Based Pricing (FeaturedQueueManager, PromotionBadges)

| Expression | Favors | Rationale |
|---|---|---|
| `cost = dailyRate * duration / 1 days` | Renter/Buyer | Sub-day fractions cost nothing — `msg.value >= cost` check ensures no under-payment |
| `daysPassed = elapsed / 1 days` | Renter | Partial days don't trigger decay |

### Other

| Expression | Location | Note |
|---|---|---|
| `(low + high + 1) / 2` | GrandCentral binary search | Rounds **up** — standard upper-bound binary search to avoid infinite loop |
| `maxTotalShares * minRetentionPercent / 100` | GrandCentral retention check | Rounds down — makes it slightly harder to fail the retention check (conservative) |
| `balance / (1e6 * 1e18)` | QueryAggregator | View-only NFT count conversion; no value transfer |
| `normFactor = maxBondingSupply / 1e18` | CurveParamsComputer | Normalization for safe math; guarded by `!= 0` fallback |
| `deployETH / 2` | ZAMMAlignmentVault init | Extra wei goes to LP side |
| `principalETH * feeLP / lpHeld` | ZAMMAlignmentVault harvest | Slightly over-estimates remaining principal (conservative) |
