# ms2.fun Launchpad - System Architecture

**Version:** 1.0.0-audit-ready
**Last Updated:** 2025-12-17
**Status:** Production-Ready

---

## Table of Contents

1. [System Overview](#system-overview)
2. [Contract Interaction Flow](#contract-interaction-flow)
3. [Core Components](#core-components)
4. [Global Messaging System](#global-messaging-system)
5. [Uniswap V4 Integration Patterns](#uniswap-v4-integration-patterns)
6. [Fee Distribution Mechanism](#fee-distribution-mechanism)
7. [Queue Rental System](#queue-rental-system)
8. [ETH and WETH Handling](#eth-and-weth-handling)
9. [Upgrade Procedures](#upgrade-procedures)
10. [Deployment Guide](#deployment-guide)
11. [Security Considerations](#security-considerations)

---

## System Overview

The ms2.fun launchpad is a modular token launchpad ecosystem that enables:
- **Factory-based token deployment** (ERC404, ERC1155)
- **Decentralized governance** via EXEC token voting
- **Ultra-Alignment value capture** through V4 hooks and fee vaults
- **Competitive visibility marketplace** via queue rental system

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                         ms2.fun Ecosystem                            │
└─────────────────────────────────────────────────────────────────────┘
                                    │
        ┌───────────────────────────┼───────────────────────────┐
        │                           │                           │
        ▼                           ▼                           ▼
┌──────────────┐          ┌──────────────┐          ┌──────────────┐
│   Master     │          │  Factory     │          │     EXEC     │
│  Registry    │◄─────────│ Application  │          │  Governance  │
│   (UUPS)     │          │   System     │          │    Voting    │
└──────┬───────┘          └──────────────┘          └──────────────┘
       │                                                     │
       │ registers                                           │ approves
       │                                                     │
       ▼                                                     ▼
┌──────────────┐                                    ┌──────────────┐
│  ERC404      │                                    │  ERC1155     │
│  Factory     │                                    │   Factory    │
└──────┬───────┘                                    └──────┬───────┘
       │                                                   │
       │ creates                                           │ creates
       │                                                   │
       ▼                                                   ▼
┌──────────────┐                                    ┌──────────────┐
│  ERC404      │                                    │  ERC1155     │
│  Instance    │                                    │  Instance    │
└──────┬───────┘                                    └──────────────┘
       │
       │ deploys (optional)
       │
       ▼
┌──────────────┐          ┌──────────────┐          ┌──────────────┐
│  V4 Hook     │─────────►│ Ultra-       │◄─────────│   Fee        │
│ (Tax Logic)  │  taxes   │ Alignment    │ records  │ Collectors   │
│              │          │   Vault      │          │              │
└──────────────┘          └──────┬───────┘          └──────────────┘
                                 │
                                 │ distributes
                                 │
                                 ▼
                          ┌──────────────┐
                          │ Benefactors  │
                          │ (claimFees)  │
                          └──────────────┘
```

---

## Contract Interaction Flow

### 1. Factory Registration Flow

```
User → submitApplicationWithApplicant()
         │
         ├─ FactoryApprovalGovernance: Creates application
         │
         └─ EXEC Holders: voteOnApplication(approve/reject)
                  │
                  └─ [After voting threshold met]
                           │
                           └─ MasterRegistry.registerFactory()
                                    │
                                    ├─ Assign factoryId
                                    ├─ Store FactoryInfo
                                    └─ Emit FactoryRegistered
```

### 2. Instance Creation Flow

```
Factory.createInstance(params)
         │
         ├─ Deploy new token instance
         │
         └─ MasterRegistry.registerInstance()
                  │
                  ├─ Store InstanceInfo
                  ├─ Link to creator
                  └─ Emit InstanceRegistered
```

### 3. Ultra-Alignment Hook + Vault Flow

```
ERC404Instance Token Swap (via V4)
         │
         └─ V4 PoolManager.swap()
                  │
                  └─ UltraAlignmentV4Hook.afterSwap()
                           │
                           ├─ Calculate tax (e.g., 1% of output)
                           │
                           └─ vault.receiveHookTax(currency, amount, benefactor)
                                    │
                                    ├─ Add to pendingETH[benefactor]
                                    └─ Track in dragnet for batch conversion
                                             │
[Anyone triggers conversion]                 │
         │                                   │
         └─ vault.convertAndAddLiquidity() ◄─┘
                  │
                  ├─ Swap ETH → Alignment Token
                  ├─ Add liquidity to V4 pool
                  ├─ Issue shares to all benefactors
                  ├─ Clear dragnet
                  └─ Pay caller reward
```

### 4. Fee Claim Flow

```
Benefactor → vault.claimFees()
                  │
                  ├─ Calculate: (accumulatedFees × shares) / totalShares
                  ├─ Delta: currentValue - shareValueAtLastClaim
                  ├─ Transfer ETH to benefactor
                  └─ Update shareValueAtLastClaim
```

---

## Core Components

### MasterRegistry (UUPS Upgradeable)

**Purpose:** Central registry for factories, instances, vaults, and featured queue management.

**Key Responsibilities:**
- Factory registration and tracking
- Instance registration with creator attribution
- Featured queue rental system (competitive positioning)
- Vault registry
- Upgrade control (owner-only)

**Upgradeability:** Uses UUPS pattern via `_authorizeUpgrade(address)` restricted to owner.

### Factory Contracts

**ERC404Factory:**
- Creates ERC404 token instances with bonding curves
- Supports tier-based minting (password-protected or time-gated)
- Optional V4 hook deployment for tax collection
- Staking system for holder fee distribution

**ERC1155Factory:**
- Creates ERC1155 NFT instances
- Simpler deployment model
- No bonding curve or hooks

### Instance Contracts

**ERC404BondingInstance:**
- Hybrid ERC20/ERC721 token (404 standard)
- Bonding curve pricing for fair minting
- Optional staking for vault fee redistribution
- Tier system with password or time-based access
- Reroll mechanism for NFT randomization

**ERC1155Instance:**
- Standard ERC1155 multi-token
- Owner-controlled minting
- URI management

### Ultra-Alignment System

**UltraAlignmentVault:**
- Collects ETH from hooks, direct contributions
- Batch converts ETH → Alignment Token → V4 LP position
- Issues shares proportional to contributions
- O(1) fee claims via share-based distribution
- Delta tracking for multi-claim support

**UltraAlignmentV4Hook:**
- V4 BaseHook implementation
- Executes in `afterSwap()` lifecycle
- Calculates tax on swap output
- Routes fees to vault with benefactor attribution
- Enforces ETH/WETH-only pools

### Governance

**FactoryApprovalGovernance:**
- EXEC token-weighted voting
- Multi-phase approval (0.1%, 1%, 10% thresholds)
- Time-boxed rounds with decay
- Prevents Sybil attacks via vote cost

---

## Global Messaging System

### Overview

The Global Messaging System provides protocol-wide activity tracking and discovery through a centralized on-chain registry. This enables frontend clients to discover trending projects and recent activity with a single RPC call, eliminating the need for 200+ individual queries.

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                   Global Message Flow                        │
└─────────────────────────────────────────────────────────────┘

User → ERC404Instance.buyBonding("Cool project!")
         │
         └─► GlobalMessageRegistry.addMessage(
                instance: 0x123...,
                sender: user,
                packedData: [timestamp, factoryType, action, contextId, amount],
                message: "Cool project!"
             )
                 │
                 ├─► messages[] (append-only array)
                 ├─► instanceMessageIds[instance] (indexing)
                 └─► emit MessageAdded(...)

Frontend → GlobalMessageRegistry.getRecentMessages(50)
         ← Returns 50 most recent messages across all projects

Frontend → GlobalMessageRegistry.getInstanceMessages(0x123..., 20)
         ← Returns 20 most recent messages for specific project
```

### Core Components

**GlobalMessageRegistry.sol** (`src/registry/GlobalMessageRegistry.sol`)
- Centralized message storage with O(1) appends
- Authorization system (instances auto-authorized by MasterRegistry)
- Efficient querying: protocol-wide, instance-specific, paginated
- Storage: 176-bit packed metadata + string message

**GlobalMessagePacking.sol** (`src/libraries/GlobalMessagePacking.sol`)
- Optimized bit-packing library
- Layout: `[timestamp:32][factoryType:8][actionType:8][contextId:32][amount:96][reserved:80]`
- 176 bits used, 80 bits reserved for future expansion

**GlobalMessageTypes.sol** (`src/libraries/GlobalMessageTypes.sol`)
- Factory types: ERC404 (0), ERC1155 (1)
- Action types: BUY (0), SELL (1), MINT (2), WITHDRAW (3), STAKE (4), UNSTAKE (5), CLAIM_REWARDS (6), DEPLOY_LIQUIDITY (7)

### Data Structures

```solidity
struct GlobalMessage {
    address instance;      // Which project emitted this message
    address sender;        // User who performed the action
    uint256 packedData;    // Packed metadata
    string message;        // User-provided message text
}

// Packed data layout (176 bits used, 80 reserved):
// [0-31]   timestamp (uint32)
// [32-39]  factoryType (uint8)  - ERC404=0, ERC1155=1
// [40-47]  actionType (uint8)   - BUY=0, SELL=1, MINT=2, etc.
// [48-79]  contextId (uint32)   - Edition ID, tier, etc.
// [80-175] amount (uint96)      - Transaction amount in tokens
// [176-255] reserved (80 bits)
```

### Auto-Authorization Flow

```solidity
// MasterRegistry automatically authorizes instances on registration
function registerInstance(address instance, uint256 factoryId, address creator) external {
    // ... registration logic ...

    // Auto-authorize for global messaging
    if (globalMessageRegistry != address(0)) {
        GlobalMessageRegistry(globalMessageRegistry).authorizeInstance(instance);
    }
}
```

### Query Patterns

**Protocol-Wide Discovery:**
```solidity
// Get 50 most recent messages across all projects
GlobalMessage[] memory recent = registry.getRecentMessages(50);
```

**Instance-Specific Activity:**
```solidity
// Get 20 most recent messages for a specific project
GlobalMessage[] memory projectActivity = registry.getInstanceMessages(projectAddress, 20);
```

**Pagination:**
```solidity
// Get messages 100-150 (offset 100, limit 50)
GlobalMessage[] memory page = registry.getRecentMessagesPaginated(100, 50);
```

### Performance Characteristics

- **Write**: O(1) - Append to array, update index
- **Read (recent)**: O(n) - Returns last n messages
- **Read (instance)**: O(n) - Returns last n messages for instance
- **Storage**: ~3-5k gas per message (optimized bit-packing)

### Benefits

1. **Single RPC Discovery**: Reduce from 200+ calls to 1 call for activity queries
2. **Trending Detection**: Frontend can identify hot projects by message volume
3. **User Engagement**: Messages create social proof and community interaction
4. **Gas Efficient**: 176-bit packing minimizes storage costs
5. **Scalable**: Append-only design, paginated queries support unlimited growth

### Integration Example

```solidity
// ERC404BondingInstance.sol
function buyBonding(..., string calldata message) external payable {
    // ... bonding logic ...

    if (bytes(message).length > 0) {
        GlobalMessageRegistry registry = _getGlobalMessageRegistry();
        uint256 packedData = GlobalMessagePacking.pack(
            uint32(block.timestamp),
            GlobalMessageTypes.FACTORY_ERC404,
            GlobalMessageTypes.ACTION_BUY,
            0,  // contextId (not used for buys)
            uint96(amount / 1e18)  // amount in whole tokens
        );
        registry.addMessage(address(this), msg.sender, packedData, message);
    }
}
```

---

## Uniswap V4 Integration Patterns

### Unlock Callback Pattern

V4 uses a **transient storage + callback** pattern for liquidity operations. The vault must implement `IUnlockCallback` to execute operations within the unlocked state.

#### Implementation Example

```solidity
contract UltraAlignmentVault is IUnlockCallback {
    IPoolManager public immutable poolManager;

    function _addToLpPosition(
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper
    ) internal returns (uint128 liquidityUnits) {
        // Encode parameters for callback
        bytes memory data = abi.encode(amount0, amount1, tickLower, tickUpper);

        // Enter unlock context - poolManager calls our unlockCallback()
        bytes memory result = poolManager.unlock(data);

        // Decode and return result
        liquidityUnits = abi.decode(result, (uint128));
    }

    /**
     * @notice Callback executed within V4 unlock context
     * @dev Only callable by PoolManager during unlock
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only PoolManager");

        // Decode parameters
        (uint256 amount0, uint256 amount1, int24 tickLower, int24 tickUpper) =
            abi.decode(data, (uint256, uint256, int24, int24));

        // Execute liquidity operation
        (BalanceDelta delta, ) = poolManager.modifyLiquidity(
            v4PoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: calculateLiquidityDelta(amount0, amount1),
                salt: bytes32(0)
            }),
            ""
        );

        // Settle debts with pool manager
        _settleDelta(delta);

        // Return liquidity added
        uint128 liquidityAdded = uint128(/* extract from delta */);
        return abi.encode(liquidityAdded);
    }

    /**
     * @dev Settle currency deltas by transferring tokens to PoolManager
     */
    function _settleDelta(BalanceDelta delta) internal {
        // If vault owes currency0 to pool
        if (delta.amount0() > 0) {
            _transferCurrency(
                v4PoolKey.currency0,
                address(poolManager),
                uint128(uint256(int256(delta.amount0())))
            );
            poolManager.settle(v4PoolKey.currency0);
        }

        // If vault owes currency1 to pool
        if (delta.amount1() > 0) {
            _transferCurrency(
                v4PoolKey.currency1,
                address(poolManager),
                uint128(uint256(int256(delta.amount1())))
            );
            poolManager.settle(v4PoolKey.currency1);
        }

        // Take any excess back from pool
        if (delta.amount0() < 0) {
            poolManager.take(
                v4PoolKey.currency0,
                address(this),
                uint128(uint256(-int256(delta.amount0())))
            );
        }
        if (delta.amount1() < 0) {
            poolManager.take(
                v4PoolKey.currency1,
                address(this),
                uint128(uint256(-int256(delta.amount1())))
            );
        }
    }
}
```

#### Critical Patterns

1. **Unlock Context Required:** All `modifyLiquidity` calls MUST occur within `unlockCallback`
2. **Settle Immediately:** Debts must be settled before callback returns
3. **Gas Limit Awareness:** Complex operations may hit gas limits in callback
4. **Reentrancy Protection:** V4 uses transient storage, be cautious with external calls

### Hook Lifecycle Integration

```solidity
contract UltraAlignmentV4Hook is BaseHook {
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        // Determine output currency
        bool specifiedTokenIs0 = (params.amountSpecified < 0 == params.zeroForOne);
        Currency taxCurrency = specifiedTokenIs0 ? key.currency1 : key.currency0;
        int128 swapAmount = specifiedTokenIs0 ? delta.amount1() : delta.amount0();

        // Tax calculation
        uint256 taxAmount = (uint128(abs(swapAmount)) * taxRateBips) / 10000;

        if (taxAmount > 0) {
            // Enforce ETH/WETH-only pools
            address token = Currency.unwrap(taxCurrency);
            require(
                token == weth || token == address(0),
                "Hook only accepts ETH/WETH taxes"
            );

            // Take tax from pool manager
            poolManager.take(taxCurrency, address(this), taxAmount);

            // Route to vault with benefactor attribution
            vault.receiveHookTax{value: taxAmount}(taxCurrency, taxAmount, sender);

            // Return positive delta (hook took tokens)
            return (IHooks.afterSwap.selector, taxAmount.toInt128());
        }

        return (IHooks.afterSwap.selector, 0);
    }
}
```

**Key Points:**
- Hook executes AFTER swap completes
- Delta represents the result of the swap
- Hook can claim tokens via `poolManager.take()`
- Must return hookDelta (positive = took tokens, negative = gave tokens)

---

## Fee Distribution Mechanism

### Share-Based Distribution Model

The vault uses a **share-based proportional distribution** system for O(1) fee claims.

#### Core Formula

```solidity
// Total claimable for a benefactor
claimable = (accumulatedFees × benefactorShares[address]) / totalShares

// Delta-based multi-claim support
unclaimed = claimable - shareValueAtLastClaim[address]
```

#### Share Issuance on Conversion

When `convertAndAddLiquidity()` is called, shares are issued proportionally:

```solidity
function convertAndAddLiquidity(
    uint256 minOutTarget,
    int24 tickLower,
    int24 tickUpper
) external nonReentrant returns (uint256 lpPositionValue) {
    uint256 callerReward = (totalPendingETH * conversionRewardBps) / 10000;
    uint256 ethToAdd = totalPendingETH - callerReward;

    // Swap and add liquidity
    uint128 liquidityAdded = /* ... V4 operations ... */;

    // Issue shares to all benefactors
    uint256 totalSharesIssued = liquidityAdded;  // 1:1 with liquidity units

    for (uint i = 0; i < conversionParticipants.length; i++) {
        address benefactor = conversionParticipants[i];
        uint256 contribution = pendingETH[benefactor];

        // Proportional share issuance
        uint256 sharePercent = (contribution * 1e18) / ethToAdd;
        uint256 sharesToIssue = (totalSharesIssued * sharePercent) / 1e18;

        benefactorShares[benefactor] += sharesToIssue;
    }

    totalShares += totalSharesIssued;

    // Clear dragnet for next round
    _clearConversionParticipants();
}
```

#### Example: Multi-Claim Delta Calculation

```
Scenario:
- Alice contributes 3 ETH, gets 60 shares
- Bob contributes 2 ETH, gets 40 shares
- totalShares = 100

Round 1: Vault accumulates 1 ETH in fees
- accumulatedFees = 1 ETH
- Alice claimable = (1 × 60) / 100 = 0.6 ETH
- Alice claims 0.6 ETH
- shareValueAtLastClaim[Alice] = 0.6 ETH

Round 2: Vault accumulates 0.5 ETH more
- accumulatedFees = 1.5 ETH
- Alice new claimable = (1.5 × 60) / 100 = 0.9 ETH
- Alice unclaimed = 0.9 - 0.6 = 0.3 ETH ✓
- Alice claims 0.3 ETH (delta only)
- shareValueAtLastClaim[Alice] = 0.9 ETH

Total claimed by Alice: 0.6 + 0.3 = 0.9 ETH ✓
```

**Critical Properties:**
- O(1) complexity per claim (no loops)
- Supports unlimited claims per benefactor
- Prevents double-claiming via delta tracking
- Shares persist across conversion rounds (accumulate)

---

## Queue Rental System

The MasterRegistry implements a **competitive position-based rental marketplace** for featured project visibility.

### Core Mechanics

#### Pricing Formula

```solidity
function getPositionRentalPrice(uint256 position) public view returns (uint256) {
    // Utilization adjustment
    uint256 queueLength = featuredQueue.length;
    uint256 utilizationBps = (queueLength * 10000) / maxQueueSize;
    uint256 adjustedBase = baseRentalPrice + (baseRentalPrice * utilizationBps) / 10000;

    // Competitive demand multiplier
    if (position <= featuredQueue.length) {
        RentalSlot memory slot = featuredQueue[position - 1];
        if (slot.active && block.timestamp < slot.expiresAt) {
            uint256 competitivePrice = (slot.rentPaid * demandMultiplier) / 100;
            return max(competitivePrice, adjustedBase);
        }
    }

    // Demand tracking (historical activity)
    PositionDemand memory demand = positionDemand[position];
    if (demand.lastRentalTime > 0) {
        uint256 demandPrice = (demand.lastRentalPrice * demandMultiplier) / 100;
        return max(demandPrice, adjustedBase);
    }

    return adjustedBase;
}
```

**Variables:**
- `baseRentalPrice` = 0.001 ETH (starting price)
- `demandMultiplier` = 120 (20% increase per competitive action)
- `utilizationBps` = (queueLength / maxQueueSize) × 10000

#### Position Displacement

When a project rents a position already occupied:

```
Before: [A, B, C]  (A at position 1)
Action: D rents position 1
After:  [D, A, B, C]  (A shifted to position 2)

A's rental continues at position 2 with same expiration time
```

#### Bump Cost with Credit

```solidity
function _calculateBumpCost(address instance, uint256 targetPosition)
    internal view returns (uint256)
{
    RentalSlot memory slot = featuredQueue[instancePosition[instance] - 1];

    // Time-proportional credit
    uint256 timeRemaining = slot.expiresAt > block.timestamp
        ? slot.expiresAt - block.timestamp
        : 0;
    uint256 totalDuration = slot.expiresAt - slot.rentedAt;
    uint256 credit = (slot.rentPaid * timeRemaining) / totalDuration;

    // New position price
    uint256 newPrice = getPositionRentalPrice(targetPosition);

    // Pay delta only
    return newPrice > credit ? newPrice - credit : 0;
}
```

#### Auto-Renewal System

Projects can deposit funds for automatic renewal:

```solidity
function depositForAutoRenewal(address instance) external payable {
    renewalDeposits[instance] += msg.value;
}

function _attemptAutoRenewal(address instance, uint256 position)
    internal returns (bool)
{
    uint256 renewalCost = (getPositionRentalPrice(position) * renewalDiscount) / 100;

    if (renewalDeposits[instance] >= renewalCost) {
        renewalDeposits[instance] -= renewalCost;
        // Extend rental by minRentalDuration
        return true;
    }
    return false;
}
```

**For detailed queue system documentation, see:** `docs/COMPETITIVE_QUEUE_DESIGN.md`

---

## ETH and WETH Handling

The system carefully manages native ETH vs WETH based on context:

### Boundary Rules

| Component | ETH Input | ETH Output | Internal | V4 Pool |
|-----------|-----------|------------|----------|---------|
| **Vault receive()** | ✅ Native ETH | - | Tracks as ETH value | - |
| **Hook tax** | ✅ Native ETH | - | Routes to vault | WETH or native |
| **Conversion swap** | Uses ETH | - | May wrap → WETH | Depends on pool |
| **Add liquidity** | - | - | WETH if pool uses it | WETH or native |
| **Fee claims** | - | ✅ Native ETH | Unwrap if needed | - |

### WETH Wrapping Rules

```solidity
// In convertAndAddLiquidity():

// 1. Reserve caller reward by wrapping temporarily
if (callerReward > 0 && weth.code.length > 0) {
    IWETH9(weth).deposit{value: callerReward}();
}

// 2. After swap, wrap ETH if pool requires WETH
if (weth.code.length > 0) {
    if (!v4PoolKey.currency0.isAddressZero() &&
        Currency.unwrap(v4PoolKey.currency0) == weth) {
        IWETH9(weth).deposit{value: ethRemaining}();
    } else if (!v4PoolKey.currency1.isAddressZero() &&
               Currency.unwrap(v4PoolKey.currency1) == weth) {
        IWETH9(weth).deposit{value: ethRemaining}();
    }
}

// 3. Before paying caller reward, unwrap back to ETH
if (callerReward > 0 && weth.code.length > 0) {
    IWETH9(weth).withdraw(callerReward);
}
```

### Critical Patterns

1. **Always Accept ETH at Boundaries:** Users interact with native ETH
2. **Wrap for V4 Pools:** If pool uses WETH, wrap before `modifyLiquidity`
3. **Unwrap for Payouts:** Fee claims and rewards paid in native ETH
4. **Handle Unwrap in receive():** Allow WETH contract to send ETH back
5. **Check Code Size:** `weth.code.length > 0` prevents revert in tests with mock WETH

### Example: WETH Unwrapping in receive()

```solidity
receive() external payable {
    // Allow WETH unwrapping without tracking as contribution
    if (msg.sender == weth) {
        return;  // Just accept the ETH
    }

    // All other ETH is a contribution
    require(msg.value > 0, "Amount must be positive");
    _trackBenefactorContribution(msg.sender, msg.value);
    emit ContributionReceived(msg.sender, msg.value);
}
```

---

## Upgrade Procedures

### MasterRegistry UUPS Upgrade

The MasterRegistry uses **UUPS (Universal Upgradeable Proxy Standard)** for upgradeability.

#### Upgrade Authorization

```solidity
contract MasterRegistryV1 is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    function _authorizeUpgrade(address newImplementation)
        internal override onlyOwner
    {
        // Owner (governance multisig) must approve upgrades
    }
}
```

#### Upgrade Process

1. **Prepare New Implementation**
   ```bash
   # Deploy new implementation contract
   forge create src/master/MasterRegistryV2.sol:MasterRegistryV2 \
       --rpc-url $RPC_URL \
       --private-key $DEPLOYER_KEY

   # Note the deployed address
   NEW_IMPL=0x...
   ```

2. **Verify Implementation**
   ```bash
   # Run integration tests against fork with new implementation
   forge test --fork-url $RPC_URL --match-contract MasterRegistryUpgradeTest
   ```

3. **Execute Upgrade (via Multisig)**
   ```solidity
   // Call via governance multisig
   ITransparentUpgradeableProxy(PROXY_ADDRESS).upgradeToAndCall(
       NEW_IMPL,
       ""  // No initialization data
   );
   ```

4. **Post-Upgrade Validation**
   ```bash
   # Verify upgrade succeeded
   cast call $PROXY_ADDRESS "implementation()(address)"

   # Verify state preserved
   cast call $PROXY_ADDRESS "getTotalFactories()(uint256)"
   ```

#### Upgrade Safety Checklist

- [ ] New implementation inherits from same base contracts
- [ ] Storage layout unchanged (only append new variables)
- [ ] No `constructor()` code (use `initialize()` pattern)
- [ ] All new functions have proper access control
- [ ] Initialization can't be re-run (use `initializer` modifier)
- [ ] Integration tests pass on mainnet fork
- [ ] Gas costs evaluated for new functions
- [ ] Governance multisig signers ready
- [ ] Rollback plan documented

#### Storage Layout Rules

**❌ NEVER:**
```solidity
// DON'T change order
uint256 public totalFactories;  // Slot 0
uint256 public baseRentalPrice; // Slot 1 → MOVED TO SLOT 2 ❌

// DON'T delete variables
// uint256 public oldVariable; ❌ Leaves gap in storage
```

**✅ ALWAYS:**
```solidity
// DO preserve order and gaps
uint256 public totalFactories;     // Slot 0
uint256 public baseRentalPrice;    // Slot 1
uint256 public newVariable;        // Slot 2 ← Safe to append
```

---

## Deployment Guide

### Prerequisites

- Ethereum mainnet RPC URL
- Deployer private key with sufficient ETH
- Foundry installed (`foundryup`)
- Environment variables configured

### Environment Setup

```bash
# .env file
ETH_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
DEPLOYER_PRIVATE_KEY=0x...
ETHERSCAN_API_KEY=YOUR_KEY

# V4 addresses (mainnet)
UNISWAP_V4_POOL_MANAGER=0x...
WETH=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
```

### Step-by-Step Deployment

#### 1. Deploy Core Contracts

```bash
# Deploy FactoryApprovalGovernance
forge create src/governance/FactoryApprovalGovernance.sol:FactoryApprovalGovernance \
    --rpc-url $ETH_RPC_URL \
    --private-key $DEPLOYER_PRIVATE_KEY \
    --constructor-args $EXEC_TOKEN_ADDRESS \
    --verify

# Deploy MasterRegistryV1 implementation
forge create src/master/MasterRegistryV1.sol:MasterRegistryV1 \
    --rpc-url $ETH_RPC_URL \
    --private-key $DEPLOYER_PRIVATE_KEY \
    --verify

# Deploy UUPS proxy
forge create lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
    --rpc-url $ETH_RPC_URL \
    --private-key $DEPLOYER_PRIVATE_KEY \
    --constructor-args $MASTER_REGISTRY_IMPL $(cast abi-encode "initialize(address,address)" $EXEC_TOKEN $OWNER)
```

#### 2. Deploy Factories

```bash
# Deploy ERC404Factory
forge create src/factories/erc404/ERC404Factory.sol:ERC404Factory \
    --rpc-url $ETH_RPC_URL \
    --private-key $DEPLOYER_PRIVATE_KEY \
    --verify

# Deploy ERC1155Factory
forge create src/factories/erc1155/ERC1155Factory.sol:ERC1155Factory \
    --rpc-url $ETH_RPC_URL \
    --private-key $DEPLOYER_PRIVATE_KEY \
    --verify
```

#### 3. Deploy Ultra-Alignment System

```bash
# Deploy UltraAlignmentVault
forge create src/vaults/UltraAlignmentVault.sol:UltraAlignmentVault \
    --rpc-url $ETH_RPC_URL \
    --private-key $DEPLOYER_PRIVATE_KEY \
    --constructor-args $ALIGNMENT_TOKEN $UNISWAP_V4_POOL_MANAGER $WETH \
    --verify

# Deploy UltraAlignmentV4Hook
forge create src/factories/erc404/hooks/UltraAlignmentV4Hook.sol:UltraAlignmentV4Hook \
    --rpc-url $ETH_RPC_URL \
    --private-key $DEPLOYER_PRIVATE_KEY \
    --constructor-args $UNISWAP_V4_POOL_MANAGER $VAULT_ADDRESS $WETH \
    --verify
```

#### 4. Configure System

```bash
# Register factories with MasterRegistry (via governance)
cast send $MASTER_REGISTRY \
    "registerFactory(address,string,string,string,string,bytes32[])" \
    $ERC404_FACTORY "ERC404" "ERC404 Bonding Curve Factory" "..." "..." [] \
    --rpc-url $ETH_RPC_URL \
    --private-key $OWNER_KEY

# Set vault alignment token and pool
cast send $VAULT \
    "setAlignmentToken(address)" $ALIGNMENT_TOKEN \
    --rpc-url $ETH_RPC_URL \
    --private-key $OWNER_KEY

cast send $VAULT \
    "setV4PoolKey((address,address,uint24,int24,address))" \
    "($WETH,$ALIGNMENT_TOKEN,3000,60,$HOOK_ADDRESS)" \
    --rpc-url $ETH_RPC_URL \
    --private-key $OWNER_KEY
```

### Post-Deployment Checklist

- [ ] All contracts verified on Etherscan
- [ ] Ownership transferred to multisig
- [ ] Initial parameters configured
- [ ] Integration tests pass against deployed contracts
- [ ] Frontend configuration updated
- [ ] Monitoring/alerts configured
- [ ] Documentation updated with addresses

### Deployment for New Chains

When deploying to a new EVM chain:

1. **Verify V4 Availability**
   - Check if Uniswap V4 is deployed
   - Get PoolManager address
   - Verify WETH address

2. **Adjust Parameters**
   ```solidity
   // Update chain-specific values in deployment script
   baseRentalPrice = 0.001 ether;  // May adjust for chain economics
   minRentalDuration = 7 days;     // Consistent across chains
   ```

3. **Test Extensively**
   ```bash
   # Run full test suite on new chain fork
   forge test --fork-url $NEW_CHAIN_RPC
   ```

4. **Verify Oracle Availability**
   - Chainlink price feeds for alignment token
   - Fallback oracle sources

5. **Gas Cost Analysis**
   - Profile gas costs on new chain
   - Adjust caller rewards if needed

---

## Security Considerations

### Access Control

| Function | Access Level | Control Mechanism |
|----------|-------------|-------------------|
| `registerFactory` | Owner only | `onlyOwner` modifier |
| `_authorizeUpgrade` | Owner only | `onlyOwner` modifier |
| `recordAccumulatedFees` | Owner only | `onlyOwner` modifier |
| `setAlignmentToken` | Owner only | `onlyOwner` modifier |
| `convertAndAddLiquidity` | Public | Incentive-based (reward) |
| `claimFees` | Benefactor only | Implicit (no shares = no claim) |
| `unlockCallback` | PoolManager only | `msg.sender` check |

### Reentrancy Protection

All state-changing functions use `nonReentrant` guard:

```solidity
function claimFees() external nonReentrant returns (uint256) {
    // Safe from reentrancy attacks
}
```

### Input Validation

```solidity
// Amount validation
require(msg.value > 0, "Amount must be positive");

// Address validation
require(benefactor != address(0), "Invalid benefactor");

// Range validation
require(tickLower < tickUpper, "Invalid tick range");
require(duration >= minRentalDuration, "Duration too short");
```

### Integer Overflow Protection

Solidity 0.8+ has built-in overflow protection, but critical calculations use explicit checks:

```solidity
// Share calculation with precision
uint256 sharePercent = (contribution * 1e18) / ethToAdd;
uint256 sharesToIssue = (totalSharesIssued * sharePercent) / 1e18;
```

### External Call Safety

```solidity
// Check recipient can receive ETH
(bool success, ) = payable(benefactor).call{value: ethClaimed}("");
require(success, "ETH transfer failed");

// Prevent WETH call failures in tests
if (weth.code.length > 0) {
    IWETH9(weth).withdraw(amount);
}
```

### Known Limitations

1. **V4 Integration:** Requires mainnet fork for realistic testing
2. **Oracle Dependency:** Price protection relies on external oracles
3. **Queue Cleanup:** Requires periodic off-chain monitoring for expired rentals
4. **Gas Costs:** Large dragnet (100+ benefactors) may hit gas limits in conversion
5. **WETH Mock:** Test environments may not have functional WETH contract

### Audit Recommendations

- [ ] Third-party audit of all contracts
- [ ] Formal verification of share distribution math
- [ ] Fuzz testing for queue operations
- [ ] Economic attack vector analysis
- [ ] V4 integration security review
- [ ] Upgrade mechanism testing
- [ ] Multi-chain deployment validation

---

## Additional Resources

- **Vault Architecture:** `docs/VAULT_ARCHITECTURE.md`
- **Ultra-Alignment System:** `docs/ULTRA_ALIGNMENT.md`
- **Queue Design:** `docs/COMPETITIVE_QUEUE_DESIGN.md`
- **V4 Integration Status:** `docs/V4_POOL_DISCOVERY_STATUS.md`
- **Security:** `docs/SECURITY.md`

---

**End of Architecture Documentation**
