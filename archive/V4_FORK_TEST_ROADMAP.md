# V4 Fork Test Implementation Roadmap

**Last Updated**: December 12, 2025
**Status**: 11/48 V4 tests complete (22.9%)

---

## Overview

This document tracks which V4 fork tests are **real implementations** vs **TODO stubs**.

### Current Totals

| Category | Real Tests | Stub Tests | Total | % Complete |
|----------|-----------|------------|-------|-----------|
| V2 Tests | 15 | 0 | 15 | 100% ✅ |
| V3 Tests | 16 | 0 | 16 | 100% ✅ |
| **V4 Tests** | **11** | **37** | **48** | **22.9%** |
| Integration (V2/V3) | 6 | 0 | 6 | 100% ✅ |
| **TOTAL** | **48** | **37** | **85** | **56.5%** |

---

## V4 Test Files - Detailed Breakdown

### 1. V4SwapRouting.t.sol ✅ 78.6% Complete (11/14 tests)

**Purpose**: Test V4 swap execution via unlock callback pattern

**Real Tests (11)** ✅
- `test_queryV4PoolManager_deployed` - Verify PoolManager deployment
- `test_queryV4_WETH_USDC_allFees` - Query WETH/USDC pools across fee tiers
- `test_queryV4_WETH_USDT_allFees` - Query WETH/USDT pools
- `test_queryV4_WETH_DAI_allFees` - Query WETH/DAI pools
- `test_queryV4_USDC_USDT_allFees` - Query USDC/USDT pools
- `test_queryV4_NativeETH_USDC_allFees` - Query Native ETH/USDC pools
- `test_queryV4_NativeETH_USDT_allFees` - Query Native ETH/USDT pools
- `test_queryV4_NativeETH_DAI_allFees` - Query Native ETH/DAI pools
- `test_swapExactInputSingle_success` - Exact input swap (negative amountSpecified)
- `test_swapExactOutputSingle_success` - Exact output swap (positive amountSpecified)
- `test_swapWithSqrtPriceLimitX96_success` - Price limit protection

**Stub Tests (3)** ❌
- `test_compareV4SwapToV2V3_success` - Compare V4 pricing to V2/V3
- `test_swapThroughMultipleV4Pools_success` - Multi-hop routing
- `test_swapWithHookTaxation_reducesOutput` - Hook taxation impact

**Priority**: 🔴 **HIGH** - Comparison test is critical for routing decisions

---

### 2. V4PoolInitialization.t.sol ✅ 100% Complete (15/15 tests)

**Status**: ALL REAL TESTS - NO STUBS! ✅

This file is complete! All 15 tests query V4 pool state using StateLibrary.

---

### 3. V4PositionCreation.t.sol ❌ 0% Complete (0/5 tests)

**Purpose**: Test adding liquidity to V4 pools via PositionManager

**All Stub Tests (5)** ❌
- `test_addLiquidity_success` - Add liquidity to existing pool
- `test_addLiquidityFullRange_success` - Add full-range liquidity
- `test_addLiquidityConcentrated_success` - Add concentrated liquidity
- `test_addLiquidityWithInvalidTicks_reverts` - Error handling for invalid ticks
- `test_addLiquidityWithoutApproval_reverts` - Error handling for missing approval

**Complexity**: 🟡 **MEDIUM** - Requires understanding V4 PositionManager mint() flow

**Blockers**:
- V4 PositionManager interface not yet implemented
- Need to understand V4 liquidity provision via unlock callback
- Must handle ETH wrapping for Native currency

**Estimated Effort**: 3-4 hours

---

### 4. V4PositionQuery.t.sol ❌ 0% Complete (0/5 tests)

**Purpose**: Query position state and value

**All Stub Tests (5)** ❌
- `test_queryPositionLiquidity_success` - Get liquidity amount for position
- `test_queryPositionFeeGrowth_success` - Get accumulated fees
- `test_queryMultiplePositionsSameOwner_success` - Query multiple positions
- `test_queryPositionAfterRemovingLiquidity_success` - Query after partial removal
- `test_calculatePositionValue` - Calculate USD value of position

**Complexity**: 🟡 **MEDIUM** - Depends on PositionCreation tests working first

**Blockers**:
- Must implement position creation tests first
- Need to understand V4 position tokenId encoding
- Requires fee growth calculation logic

**Estimated Effort**: 2-3 hours (after position creation works)

---

### 5. V4FeeCollection.t.sol ❌ 0% Complete (0/5 tests)

**Purpose**: Test fee collection from V4 positions

**All Stub Tests (5)** ❌
- `test_collectFees_afterSwaps_success` - Collect fees after swaps generate fees
- `test_collectFees_beforeSwaps_receivesZero` - No fees before swaps
- `test_collectFees_multipleCollections_success` - Multiple collections over time
- `test_collectFees_onlyOwnerCanCollect` - Access control
- `test_feeAccumulation_proportionalToLiquidity` - Verify fee math

**Complexity**: 🔴 **HIGH** - Requires both swaps and positions working

**Blockers**:
- Depends on PositionCreation + PositionQuery
- Must generate fees via swaps first
- Need to understand V4 fee collection via decrease/burn

**Estimated Effort**: 3-4 hours (after positions and swaps work)

---

### 6. V4HookTaxation.t.sol ❌ 0% Complete (0/6 tests)

**Purpose**: Test UltraAlignmentV4Hook taxation behavior

**All Stub Tests (6)** ❌
- `test_hookTaxesSwaps_success` - Verify hook takes % of swap
- `test_hookTaxRate_configurable` - Check tax rate configuration
- `test_hookDoubleTaxation_onVaultPosition` - Vault gets taxed twice?
- `test_hookOnlyAcceptsETH_reverts` - Hook rejects non-ETH swaps
- `test_hookEmitsSwapTaxedEvent` - Event emission
- `test_zeroTaxWhenRateIsZero` - Edge case: 0% tax rate

**Complexity**: 🔴 **VERY HIGH** - Requires hook deployment and configuration

**Blockers**:
- UltraAlignmentV4Hook not deployed on mainnet yet
- Would need to deploy mock hook for testing
- Complex hook interaction patterns

**Priority**: 🟡 **DEFERRED** - Can test hook logic in unit tests instead

**Estimated Effort**: 6-8 hours (includes mock hook deployment)

---

## Integration Test Files

### 7. SwapRoutingComparison.t.sol ✅ 100% Complete (6/6 tests)

**Status**: ALL REAL TESTS ✅

Already implemented! Compares V2/V3 swap pricing.

---

### 8. VaultSwapToV4Position.t.sol ❌ 0% Complete (0/6 tests)

**Purpose**: Test vault swapping ETH and adding to V4 position

**All Stub Tests (6)** ❌
- End-to-end flow: deposit → swap → addLiquidity

**Complexity**: 🔴 **VERY HIGH** - Requires vault + V4 positions working

**Blockers**: All V4 position tests must work first

**Estimated Effort**: 4-5 hours

---

### 9. VaultFullCycle.t.sol ❌ 0% Complete (0/5 tests)

**Purpose**: Test complete vault lifecycle

**All Stub Tests (5)** ❌
- Multi-user deposit → swap → position → fee collection → withdrawal

**Complexity**: 🔴 **VERY HIGH** - Most complex integration test

**Estimated Effort**: 5-6 hours

---

### 10. VaultMultiDeposit.t.sol ❌ 0% Complete (0/4 tests)

**Purpose**: Test multiple users depositing simultaneously

**All Stub Tests (4)** ❌
- Pro-rata share calculations
- Queue fairness

**Complexity**: 🟡 **MEDIUM-HIGH**

**Estimated Effort**: 3-4 hours

---

## Implementation Strategy

### Phase 1: Complete V4 Swap Tests (Current) ✅ IN PROGRESS
**Effort**: 2-3 hours
**Status**: 78.6% complete (11/14 tests)

Remaining:
1. ✅ ~~Exact input swap~~ (DONE)
2. ✅ ~~Exact output swap~~ (DONE)
3. ✅ ~~Price limit test~~ (DONE)
4. ❌ Compare V4 to V2/V3 pricing
5. ⏸️ Multi-hop routing (DEFER - complex)
6. ⏸️ Hook taxation (DEFER - requires mock hook)

---

### Phase 2: V4 Position Creation (NEXT PRIORITY) 🎯
**Effort**: 3-4 hours
**Status**: 0% complete (0/5 tests)

**Why Next?**: Unlocks position query, fee collection, and integration tests

**Approach**:
1. Study V4 PositionManager interface
2. Implement unlock callback for mint()
3. Handle Native ETH wrapping
4. Test full-range and concentrated liquidity
5. Error handling tests

**Key Challenge**: Understanding V4's PositionManager.mint() parameters

---

### Phase 3: V4 Position Query
**Effort**: 2-3 hours
**Depends On**: Phase 2 complete

---

### Phase 4: V4 Fee Collection
**Effort**: 3-4 hours
**Depends On**: Phase 2 & 3 complete

---

### Phase 5: Integration Tests
**Effort**: 12-15 hours
**Depends On**: All V4 primitive tests complete

---

### Phase 6: Hook Taxation (OPTIONAL)
**Effort**: 6-8 hours
**Note**: Can be tested via unit tests instead of fork tests

---

## Summary

### What's Working ✅
- V2 tests: 100% (15/15)
- V3 tests: 100% (16/16)
- V4 pool queries: 100% (15/15)
- V4 swap basics: 100% (3/3)
- **V4 Swap Routing: 78.6%** (11/14)

### What's Missing ❌
- V4 swap comparison to V2/V3 (1 test)
- V4 position management (10 tests)
- V4 fee collection (5 tests)
- V4 hook taxation (6 tests)
- V4 integration flows (15 tests)

### Critical Path to Production
1. ✅ V4 swap execution - **DONE**
2. ❌ V4 vs V2/V3 comparison - **NEXT** (needed for routing logic)
3. ❌ V4 position creation - **NEEDED** (core vault functionality)
4. ❌ V4 position query - **NEEDED** (for vault accounting)
5. ❌ V4 fee collection - **NEEDED** (for vault revenue)

### Estimated Total Remaining Effort
- **Critical path (phases 2-4)**: 8-10 hours
- **Full completion (all phases)**: 26-34 hours

---

## Key Learnings

### V4 Delta Sign Convention (VERIFIED)
- **Negative delta** = we owe pool (must settle)
- **Positive delta** = pool owes us (we take)
- Source: v4-core/src/test/PoolSwapTest.sol:102-113

### V4 Amount Sign Convention (VERIFIED)
- **Negative amountSpecified** = exact input
- **Positive amountSpecified** = exact output
- Different from V3!

### V4 Unlock Callback Pattern (WORKING)
```solidity
function unlockCallback(bytes calldata data) external returns (bytes memory) {
    // 1. Decode callback data
    // 2. Execute operation (swap, mint, burn)
    // 3. Handle deltas (settle negative, take positive)
    // 4. Return result
}
```

### V4 Pool Querying (WORKING)
- Use `StateLibrary.getSlot0(poolManager, poolId)` for price
- Use `StateLibrary.getLiquidity(poolManager, poolId)` for liquidity
- Works perfectly on mainnet fork!

---

**Next Action**: Implement `test_compareV4SwapToV2V3_success` to validate routing decisions
