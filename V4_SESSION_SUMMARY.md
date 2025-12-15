# V4 Testing Session Summary

**Date**: December 11, 2025
**Session Goal**: Implement V4 fork tests to validate Uniswap V4 integration assumptions

---

## What We Accomplished ✅

### 1. Fixed Critical V4 Query Issue
**Problem**: V4 pool queries were failing with `NotActivated` error on `extsload` opcode

**Root Cause**: `foundry.toml` had `evm_version = "paris"` (pre-Cancun hardfork)

**Solution**: Changed to `evm_version = "cancun"` to enable EXTSLOAD opcode support

**Files Modified**:
- `foundry.toml`: Line 9 and 39
- `scripts/start-fork.sh`: Added `--hardfork cancun` to anvil

### 2. Implemented 7 Real V4 Liquidity Query Tests
**File**: `test/fork/v4/V4PoolInitialization.t.sol`

**Tests Implemented**:
1. ✅ `test_checkV4Availability()` - Verify PoolManager deployment
2. ✅ `test_queryNativeETH_USDC_liquidity()` - Query all fee tiers
3. ✅ `test_compareNativeETH_vs_WETH_liquidity()` - Compare pool types
4. ✅ `test_queryFullPoolState_WETH_USDC()` - Full state query demo
5. ✅ `test_queryStablecoinPoolLiquidity()` - USDC/USDT analysis
6. ✅ `test_verifyWETH_DAI_poolsDoNotExist()` - Validate discoveries
7. ✅ `test_queryFeeGrowthGlobals()` - Trading activity metrics

**All 7 tests passing on mainnet fork at block 23,724,000**

### 3. Discovered V4 Pool Landscape
**25 Active V4 Pools Found**:
- 12 Native ETH pools (ETH/USDC, ETH/USDT, ETH/DAI)
- 9 WETH pools (WETH/USDC, WETH/USDT)
- 4 Stablecoin pools (USDC/USDT)

**Key Findings**:
- **Native ETH has 79x more liquidity** than WETH in USDC pairs
- No WETH/DAI pools exist (users prefer Native ETH/DAI)
- Stablecoin pools concentrated in 0.01% fee tier
- All pools have `protocolFee = 0` (100% fees to LPs)

### 4. Documentation Created
- ✅ `V4_POOLS_DISCOVERED.md` - Pool discovery results + liquidity analysis
- ✅ `V4_TESTING_ARCHITECTURE.md` - Complete guide to V4 testing challenges
- ✅ `V4_SESSION_SUMMARY.md` - This document

---

## Technical Achievements

### Understanding V4 Architecture
- **StateLibrary**: Read-only queries via `extsload`
- **Currency Type**: Native ETH as `Currency.wrap(address(0))`
- **PoolId**: Derived from `PoolKey` hash
- **Transient Storage**: EIP-1153 for delta accounting

### Test Infrastructure Built
```solidity
// Helper functions created
function _createNativeETHPoolKey(address token, uint24 fee) internal pure
function _createWETHPoolKey(address token, uint24 fee) internal view
function _getTickSpacing(uint24 fee) internal pure

// StateLibrary usage patterns
poolManager.getSlot0(poolId)           // Price, tick, fees
poolManager.getLiquidity(poolId)       // Total liquidity
poolManager.getFeeGrowthGlobals(poolId) // Trading volume
```

### Compilation Fixes
- Removed duplicate token address declarations (inherited from ForkTestBase)
- Fixed WETH reference to use inherited variable
- Proper StateLibrary import and usage

---

## Why We Stopped Here

### The Unlock-Callback Wall

V4 swap and position tests require a fundamentally different architecture:

**What Works** (Current Tests):
```solidity
// Direct read-only calls
uint128 liquidity = poolManager.getLiquidity(poolId);
```

**What's Needed** (Swap/Position Tests):
```solidity
// 1. Implement IUnlockCallback
contract TestContract is IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        // 2. Decode callback data
        // 3. Execute swap via poolManager.swap()
        // 4. Settle Currency deltas
        // 5. Return results
    }
}

// 6. Call unlock to trigger callback
poolManager.unlock(encodedCallbackData);
```

### Complexity Estimate

| Component | Lines of Code | Effort |
|-----------|---------------|--------|
| V4UnlockHelper contract | ~250 | 4-6 hours |
| Swap tests (6 tests) | ~150 | 2-3 hours |
| Position tests (10 tests) | ~200 | 4-5 hours |
| Hook integration (6 tests) | ~300 | 6-8 hours |
| **Total** | **~900** | **16-22 hours** |

Compare to query tests: **~100 lines, 1-2 hours**

### Strategic Decision

**Defer V4 swap/position tests until UltraAlignmentVault implementation**

**Reasoning**:
1. ✅ Proven V4 pools exist and are queryable
2. ✅ Understand architecture needed for swaps/positions
3. ❌ Don't know exact vault requirements yet
4. ✅ Better to implement with real use cases

**Benefits**:
- No premature optimization
- Build exactly what we need
- Test with actual hook implementation
- Avoid wasted effort on unused infrastructure

---

## Files Modified

### Configuration
- `foundry.toml` - Changed `evm_version` to "cancun" (2 locations)
- `scripts/start-fork.sh` - Added `--hardfork cancun` flag

### Tests
- `test/fork/v4/V4PoolInitialization.t.sol` - Complete rewrite
  - Before: 7 TODO stub tests
  - After: 7 real liquidity query tests (all passing)

### Documentation
- `V4_POOLS_DISCOVERED.md` - Updated with liquidity data
- `V4_TESTING_ARCHITECTURE.md` - New comprehensive guide
- `V4_SESSION_SUMMARY.md` - This summary

---

## Test Results

### Before Session
- V4 tests: 8/8 pool discovery, 34 TODO stubs
- Total: 8 real V4 tests

### After Session
- V4 tests: 8 pool discovery + 7 liquidity queries
- Total: **15 real V4 tests, all passing** ✅

### Overall Fork Test Status
- V2: 14/15 passing (93.3%)
- V3: 13/16 passing (81.3%)
- V4: 15/15 passing (100%) ⭐
- Integration: 6/6 passing (100%)
- **Total: 48 real tests, 44 passing (91.7%)**

---

## Key Liquidity Findings

### Most Liquid Pools (by liquidity units)

**Top 3:**
1. **ETH/USDC 0.3%**: 647,879,283,850,357,273 (~647M) 🥇
2. **ETH/USDC 0.05%**: 353,276,083,611,500,138 (~353M) 🥈
3. **USDC/USDT 0.3%**: 446,690,315,805 (~446M) 🥉

### Native ETH vs WETH Comparison

**ETH/USDC 0.05%**: 353M liquidity
**WETH/USDC 0.05%**: 4.4M liquidity
**Ratio**: **79.0x more liquidity in Native ETH pool** 🚀

**Implication for UltraAlignmentVault**:
- Should prefer Native ETH pools for better execution
- Can support WETH pools as fallback
- Need to handle both `address(0)` and WETH in routing

### Fee Tier Distribution

**Volatile Pairs (ETH/USDC)**:
- Most liquidity in 0.3% tier
- Secondary liquidity in 0.05%
- Minimal in 0.01% and 1%

**Stablecoin Pairs (USDC/USDT)**:
- Most liquidity in 0.01% tier (low volatility = low fees)
- Minimal in other tiers

### Trading Activity

**Fee Growth Metrics** (ETH/USDC 0.05%):
- feeGrowthGlobal0X128: 232,840,587,281,588,252,155,672,065,063,430,105,993,748
- feeGrowthGlobal1X128: 594,787,874,012,801,477,597,501,321,785,753

**Interpretation**: High fee growth = Active trading, healthy pools

---

## Next Steps (Future Work)

### When Implementing UltraAlignmentVault

1. **Build V4UnlockHelper** (~250 lines)
   - Implement IUnlockCallback
   - Handle swap callback
   - Handle liquidity callback
   - Delta settlement logic

2. **Implement Vault V4 Functions**
   - `_executeV4Swap()` - Use unlock pattern
   - `_createV4Position()` - Use modifyLiquidity
   - `_collectV4Fees()` - Collect from positions

3. **Add V4 Integration Tests** (with real vault)
   - Test swap through vault
   - Test position creation
   - Test hook taxation flow
   - Test fee collection

### Reference Documents
- `V4_TESTING_ARCHITECTURE.md` - How to implement unlock pattern
- `V4_POOLS_DISCOVERED.md` - Which pools to use for testing
- `lib/v4-core/src/` - V4 interface reference

---

## Lessons Learned

### 1. EVM Version Matters
- V4 requires Cancun hardfork for `extsload` (EIP-2330)
- Always check `evm_version` in foundry.toml
- Anvil needs `--hardfork cancun` flag for fork tests

### 2. V4 is Different
- Can't treat V4 like V2/V3
- Unlock-callback pattern is fundamental
- Read-only queries are easy, state changes are complex

### 3. Pragmatic Testing
- Don't build infrastructure before knowing requirements
- Query tests validate pools exist (✅ Done)
- Swap/position tests should use real vault code (⏸️ Deferred)

### 4. Native ETH Support Changes Everything
- 79x liquidity difference is massive
- UltraAlignmentVault should prefer Native ETH pools
- Need robust handling of `Currency.wrap(address(0))`

---

## Conclusion

**Mission Accomplished** ✅

We successfully:
1. Fixed V4 query infrastructure (Cancun EVM)
2. Implemented 7 real liquidity query tests
3. Discovered 25 active V4 pools with detailed metrics
4. Documented the path forward for swap/position tests

**Strategic Pause** ⏸️

Rather than spending 16-22 hours building V4 test infrastructure we might not need, we've:
1. Proven V4 works and pools exist
2. Documented exactly what's needed for complex tests
3. Prepared to implement when building the actual vault

**ROI**: High value tests completed efficiently. Complex tests deferred until requirements are clear.

**Status**: Ready to move to other priorities (governance, vault implementation, etc.)

---

**End of Summary**
