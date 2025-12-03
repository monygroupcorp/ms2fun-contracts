# Treasury and Epoch Architecture

## Overview

The UltraAlignmentVault implements a sophisticated three-pool treasury system combined with async epoch finalization to enable perpetual, scalable operation without gas spikes or forced blocking behavior.

## Three-Pool Treasury Design

### Core Concept

All vault ETH is segregated into three independent pools, each with a distinct purpose:

```
                    Treasury
                       |
        _______________|_______________
        |               |               |
   Conversion      Fee Claim       Operator
    Pool            Pool          Incentive Pool
        |               |               |
    ETH for ETH→    ETH for benefactor  Rewards for
    token→LP ops    fee claim payouts   epoch keepers
```

### Pool Definitions

1. **Conversion Pool** (`conversionPool`)
   - Reserved for ETH → target token → LP position operations
   - Funded by: All inbound ETH via `receive()` function
   - Allocated by: Conversions that consume ETH
   - Use case: Core operational capital for protocol

2. **Fee Claim Pool** (`feeClaimPool`)
   - Reserved for paying benefactors their fee claim rewards
   - Funded by: Owner reallocation from conversion pool
   - Allocated by: Benefactor claims (`claimBenefactorFees()`)
   - Use case: Ensures fee payouts don't drain conversion capital

3. **Operator Incentive Pool** (`operatorIncentivePool`)
   - Reserved for rewarding epoch keepers and converters
   - Funded by: Owner reallocation from conversion pool
   - Allocated by: Epoch finalization (`finalizeEpochAndStartNew()`)
   - Use case: Incentivizes decentralized epoch maintenance

### ETH Flow

```
Inbound ETH (hooks, tithes, direct)
    ↓
receive() function
    ↓
[+] conversionPool (auto-allocated)
    ↓
[Available for:]
- convertAndAddLiquidityV4() operations
- Owner rebalancing to fee pool
- Owner rebalancing to operator pool
```

### Owner-Controlled Rebalancing

Owners can move ETH between pools as needs shift:

```solidity
// Move 10 ETH from conversion pool to fee claim pool
vault.reallocateTreasuryForFeeClaims(10 ether);

// Move 5 ETH from conversion pool to operator incentive pool
vault.reallocateTreasuryForOperators(5 ether);
```

**Key Properties:**
- Only owner can rebalance
- Can only take from conversion pool (prevents pool depletion)
- Maintains clear audit trail via events
- No enforcement - owner fully controls allocation strategy

## Async Epoch Finalization

### The Problem with Auto-Finalization

Previous designs considered auto-triggering epoch finalization when:
- Conversion count exceeded threshold
- Time elapsed since last finalization
- Other automatic conditions

**Issue**: This adds unexpected gas costs to conversion transactions, especially problematic for:
- Hook-initiated conversions (users paying gas through hook)
- Predictable gas cost expectations

### The Solution: Optional, Async Finalization

Epoch finalization is **completely decoupled** from conversions:

```solidity
// Finalization is optional, called by keepers or anyone when ready
// Does NOT block conversions
vault.finalizeEpochAndStartNew();

// Conversions always proceed, regardless of epoch state
vault.convertAndAddLiquidityV4(...); // Always succeeds (if ETH available)
```

**Benefits:**
- **Predictable gas**: Conversions have consistent gas cost
- **No blocking**: Conversions never fail due to epoch logic
- **Incentivized maintenance**: Keepers get rewards for finalization
- **Flexible timing**: Anyone can finalize when it makes sense

### Epoch Finalization Mechanics

When `finalizeEpochAndStartNew()` is called:

```
1. Validate current epoch has ETH (require epoch.totalETHInEpoch > 0)
2. Increment currentEpochId (start new epoch)
3. Check if compression needed (currentEpochId - minEpochIdInWindow > 3)
4. If needed: compress oldest epoch (_compressOldestEpoch())
5. Calculate keeper reward from operatorIncentivePool
6. Pay caller their reward
7. Emit EpochFinalized event
```

**Keeper Reward Calculation:**
```solidity
uint256 rewardBps = epochKeeperRewardBps;           // 5 bps default (0.05%)
uint256 callerReward = (epoch.totalETHInEpoch * rewardBps) / 10000;
```

### Advisory Epoch Boundaries

Unlike automatic triggers, epoch boundaries are **advisory only**:

```solidity
// Set recommended max conversions per epoch
vault.setMaxConversionsPerEpoch(100);

// This is informational - conversions are NOT blocked at threshold
vault.convertAndAddLiquidityV4(...);  // Proceeds even if epoch > 100 conversions
```

**Purpose**: Guides keepers on when to finalize, doesn't enforce limits.

## Perpetual Operation

### Scaling to Unlimited Conversions

Without treasury and epoch systems, vault storage grows unbounded:
- Each conversion adds storage
- Array and mapping lookups become expensive
- Fee claiming becomes O(n) in number of conversions

### Trailing Window Compression

The vault keeps a **rolling window** of active epochs:

```
Active Window (kept in storage):
epoch 5 (oldest active) | epoch 6 | epoch 7 | epoch 8 (current)
                           ↑         ↑        ↑
                    All 3 kept in storage

When epoch 9 created:
epoch 6 (oldest active) | epoch 7 | epoch 8 | epoch 9 (current)
                                               ↑
                           Epoch 5 compressed (marked inactive)
```

**Parameters:**
- `maxEpochWindow = 3` (constant)
- Keep last 3 completed epochs + current epoch (up to 4 total)
- Older epochs compressed and marked "condensed"

**Compression Process** (`_compressOldestEpoch()`):
1. Mark epoch as `isCondensed = true`
2. Record `compressedIntoEpochId` (pointer to newer epoch)
3. Clear benefactor arrays (save storage)
4. Keep mappings (enable historical queries)
5. Advance `minEpochIdInWindow`

### O(1) Fee Claiming

Even with thousands of conversions, fee claims are O(1):

```
Benefactor claim calculation:
benefactorShare = (currentTotalLPValue * lifetimeETH) / totalETHCollected
newClaim = benefactorShare - lastClaimAmount

No loop through conversions needed!
```

## Configuration

### Per-Epoch Configuration

```solidity
// Advisory conversion threshold (doesn't block)
uint256 maxConversionsPerEpoch = 100;

// Keeper reward percentage (5 bps = 0.05% of epoch ETH)
uint256 epochKeeperRewardBps = 5;

// Can be adjusted by owner
vault.setMaxConversionsPerEpoch(50);
vault.setEpochKeeperRewardBps(10);
```

### Conversion Thresholds

```solidity
// Minimum ETH for conversion to proceed
uint256 minConversionThreshold = 0.01 ether;

// Minimum LP value after swap
uint256 minLiquidityThreshold = 0.005 ether;

// Adjustable by owner
vault.setMinConversionThreshold(0.1 ether);
vault.setMinLiquidityThreshold(0.01 ether);
```

## Accounting and Auditing

### Treasury State

Query current pool balances:

```solidity
UltraAlignmentVault.Treasury memory treasury = vault.getTreasuryState();
// Returns: (conversionPool, feeClaimPool, operatorIncentivePool)
```

### Treasury Totals

Track accumulated allocations and withdrawals:

```solidity
(uint256 allocated, uint256 withdrawn) = vault.getTreasuryTotals();
// allocated = sum of all allocations to all pools
// withdrawn = sum of all withdrawals from all pools
```

**Audit Formula:**
```
allocated >= withdrawn (always true)
```

## Design Principles

1. **No Blocking**: Conversions never fail due to epoch logic
2. **Clear Separation**: Each pool has distinct purpose
3. **Owner Control**: Rebalancing is flexible and transparent
4. **Incentivized Maintenance**: Keepers rewarded for async finalization
5. **Perpetual Scalability**: Rolling window compression enables unlimited growth
6. **No Auto-Triggers**: Advisory boundaries guide, don't enforce
7. **Audit Trail**: All treasury operations emit events

## Test Coverage

Treasury and epoch functionality is tested in `test/vaults/UltraAlignmentVault.Treasury.t.sol`:

- ✅ Treasury initialization
- ✅ Pool rebalancing (permission, validation)
- ✅ Epoch configuration (advisory boundaries, keeper rewards)
- ✅ Epoch finalization (empty epoch rejection)
- ✅ Threshold management
- ✅ Configuration independence
- ✅ Treasury query functions
- ✅ Accounting accuracy

All tests pass with 25/25 passing.
