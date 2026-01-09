# V4 Testing: What Needs to be PROVEN

**Status**: Hypothesis stage - NO empirical validation yet
**Date**: December 10, 2025

---

## Current Situation

### What We THINK We Know (Unproven)
Based on reading ERC404BondingInstance.sol and v4-core library code:

1. V4 uses singleton PoolManager at `0x000000000004444c5dc75cB358380D2e3dE08A90`
2. Pools are identified by PoolKey → PoolId (keccak256)
3. StateLibrary provides `getSlot0()` for querying
4. V4 uses native ETH (address(0)), not WETH
5. Unlock callback pattern for all interactions

**PROBLEM**: This is all based on READING CODE, not RUNNING TESTS.

### What We DON'T Know (Must Discover)
- ✅ Does V4 PoolManager actually exist on mainnet?
- ❌ **Can we query V4 pools using StateLibrary.getSlot0()?**
- ❌ **Do ETH/USDC or ETH/USDT V4 pools exist?**
- ❌ **What does sqrtPriceX96 actually look like for a real V4 pool?**
- ❌ **How do we execute a V4 swap in a test?**
- ❌ **Does hook taxation work as we think it does?**
- ❌ **Can we create V4 positions via modifyLiquidity()?**

---

## Test Implementation Status

### Phase 1: V4 Pool Discovery (CRITICAL)

**Test**: `test_queryV4PoolManager_deployed()` in V4SwapRouting.t.sol
**Status**: ✅ REAL test (checks code exists at address)
**What it proves**: V4 PoolManager is deployed on mainnet
**Result**: PASSED (code size: 24,009 bytes)

**Test**: `test_queryWETHUSDCV4Pool_existence()` in V4SwapRouting.t.sol
**Status**: ⚠️ HYPOTHESIS (uses StateLibrary but not tested on fork yet)
**What it should prove**:
- Can we call `poolManager.getSlot0(poolId)` successfully?
- Do V4 pools for ETH/USDC exist?
- What fee tiers are available (500, 3000, 10000)?
- What are the actual pool prices?

**Implementation**:
```solidity
function _tryQueryPool(address token, uint24 fee) internal returns (bool found) {
    address nativeETH = address(0);

    PoolKey memory key = PoolKey({
        currency0: Currency.wrap(nativeETH < token ? nativeETH : token),
        currency1: Currency.wrap(nativeETH < token ? token : nativeETH),
        fee: fee,
        tickSpacing: _getTickSpacing(fee),
        hooks: IHooks(address(0))
    });

    PoolId poolId = key.toId();

    // HYPOTHESIS: This should work based on StateLibrary code
    (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) =
        poolManager.getSlot0(poolId);

    // HYPOTHESIS: sqrtPriceX96 == 0 means pool doesn't exist
    if (sqrtPriceX96 > 0) {
        emit log_named_address("Token", token);
        emit log_named_uint("Fee", fee);
        emit log_named_uint("sqrtPriceX96", sqrtPriceX96);
        emit log_named_int("tick", tick);
        return true;
    }

    return false;
}
```

**What could go wrong**:
- getSlot0() might revert instead of returning 0 for non-existent pools
- StateLibrary might use wrong storage slot calculation
- PoolKey encoding might be incorrect (currency order, hooks field)
- tickSpacing calculation might be wrong for given fee tier
- V4 might use different fee tiers than V3

**Next action**: RUN THIS TEST and see what happens!

---

### Phase 2: V4 Swap Execution (TODO - All Stubs)

**Tests needed**:
1. `test_swapExactInputSingle_success()` - Execute 1 ETH → USDC swap via V4
2. `test_swapExactOutputSingle_success()` - Specify output amount
3. `test_swapWithHookTaxation_reducesOutput()` - Measure hook tax impact
4. `test_compareV4SwapToV2V3_success()` - Price comparison

**What we need to prove**:
- Unlock callback pattern actually works
- How to wrap/unwrap ETH for V4 (or use native?)
- How to calculate amountSpecified parameter
- How sqrtPriceLimitX96 works for slippage protection
- What hook taxation looks like empirically

**Current status**: All TODO stubs that just emit log messages

---

### Phase 3: V4 Position Creation (TODO - All Stubs)

**Tests needed** (5 tests in V4PositionCreation.t.sol):
1. `test_addLiquidity_success()` - Create basic position
2. `test_addLiquidityFullRange_success()` - Full range position
3. `test_addLiquidityConcentrated_success()` - Narrow range

**What we need to prove**:
- How to calculate liquidityDelta from token amounts
- What tick ranges are valid
- How unlock callback works for modifyLiquidity
- How to settle/take currencies correctly

**Current status**: All TODO stubs

---

### Phase 4: V4 Fee Collection (TODO - All Stubs)

**Tests needed** (5 tests in V4FeeCollection.t.sol):
1. `test_collectFees_afterSwaps_success()`
2. `test_feeAccumulation_proportionalToLiquidity()`

**What we need to prove**:
- How fees accumulate in V4 positions
- How to collect fees (another unlock callback?)
- Fee growth tracking per position
- Whether fees are in native ETH or wrapped

**Current status**: All TODO stubs

---

### Phase 5: Hook Taxation Impact (TODO - All Stubs)

**Tests needed** (6 tests in V4HookTaxation.t.sol):
1. `test_hookTaxesSwaps_success()` - Measure actual tax amount
2. `test_hookDoubleTaxation_onVaultPosition()` - CRITICAL for vault

**What we need to prove**:
- Does UltraAlignmentV4Hook actually tax swaps?
- What is the actual tax rate (is it really 1%)?
- How does hook taxation affect pool pricing?
- Can vault's own LP position be double-taxed?
- Is hook tax paid in ETH or token?

**Current status**: All TODO stubs

---

## Critical Questions for Fork Testing

### Q1: Pool Discovery
**Question**: Can we query V4 pools using `poolManager.getSlot0(poolId)`?
**Test**: V4SwapRouting.t.sol::test_queryWETHUSDCV4Pool_existence
**Status**: NOT RUN - needs RPC access
**Importance**: CRITICAL - everything else depends on this

### Q2: V4 vs V2/V3 Pricing
**Question**: Is V4 cheaper/more expensive than V2/V3 for same swap?
**Test**: V4SwapRouting.t.sol::test_compareV4SwapToV2V3_success
**Status**: TODO stub
**Importance**: CRITICAL - determines routing algorithm

### Q3: Hook Taxation
**Question**: How much does hook taxation affect swap output?
**Test**: V4HookTaxation.t.sol::test_hookTaxesSwaps_success
**Status**: TODO stub
**Importance**: CRITICAL - affects whether to use V4 for swaps

### Q4: Unlock Callback Pattern
**Question**: How do we implement unlock callback in test contract?
**Test**: V4PositionCreation.t.sol::test_addLiquidity_success
**Status**: TODO stub
**Importance**: HIGH - needed for all V4 interactions

### Q5: Native ETH Handling
**Question**: Do we use address(0) or WETH for V4 pools?
**Test**: V4SwapRouting.t.sol::test_swapExactInputSingle_success
**Status**: TODO stub
**Importance**: HIGH - wrong currency breaks everything

---

## Action Plan

### Step 1: Validate Pool Querying (NOW)
1. Run `test_queryWETHUSDCV4Pool_existence` on mainnet fork
2. **IF IT FAILS**: Adjust PoolKey construction until it works
3. **IF IT SUCCEEDS**: Document actual pools found (fee tiers, prices)
4. Commit empirical results to a test report

### Step 2: Implement First Swap Test
1. Pick one V4 pool discovered in Step 1
2. Implement unlock callback in test contract
3. Execute a simple swap (1 ETH → USDC)
4. Compare output to V2/V3 swap of same size
5. Document actual behavior vs hypothesis

### Step 3: Measure Hook Taxation
1. Find a V4 pool WITH a hook
2. Execute swap, measure output
3. Find same pool WITHOUT hook (or compare to V2/V3)
4. Calculate empirical tax rate
5. Compare to UltraAlignmentV4Hook.sol code

### Step 4: Iterate Based on Findings
- If V4 is cheaper than V2/V3: Prioritize V4 in routing
- If V4 is more expensive: Only use for vault's own token
- If hook tax is high: Skip hooked pools for swaps
- If hook tax is low: Include hooked pools in routing

---

## Honest Status Report

### Real Tests (Empirically Validated)
- ✅ V2: 15 tests (14 passing) - PROVEN behavior
- ✅ V3: 16 tests (13 passing) - PROVEN behavior
- ✅ Integration: 6 tests (6 passing) - PROVEN V2 vs V3 comparison
- ✅ V4: 1 test (1 passing) - PROVEN PoolManager exists

**Total empirical tests**: 38 (35 passing, 92.1%)

### Hypotheses (Not Yet Tested)
- ⚠️ V4: 1 test - Pool querying via StateLibrary
- ❌ V4: 35 tests - All TODO stubs

**Total unproven tests**: 36

### What This Means
We have **NO empirical data on V4 swaps, positions, or fees**.
Everything about V4 is based on READING CODE, not RUNNING TESTS.
This violates the core purpose of fork testing: **PROVE assumptions before integrating**.

---

## Next Immediate Action

**RUN THE POOL QUERY TEST**:
```bash
forge test --mp test/fork/v4/V4SwapRouting.t.sol::test_queryWETHUSDCV4Pool_existence \
    --fork-url $ETH_RPC_URL -vvv
```

**Expected outcomes**:
1. **SUCCESS**: Finds pools, returns valid sqrtPriceX96 → proceed to swap tests
2. **REVERT**: getSlot0() fails → investigate why, fix PoolKey construction
3. **ZERO POOLS**: No V4 ETH/stable pools exist → need different token pairs
4. **GAS LIMIT**: Still hitting gas issues → need different query approach

**Only after this succeeds can we move forward with confidence.**

---

## Philosophical Note

The user is absolutely right:
> "we can't necessarily treat erc404bondinginstance as law. its not production code at all really."

**ERC404BondingInstance is just another hypothesis that needs testing.**

The whole point of this fork testing suite is:
1. Make NO assumptions about how UniSwap works
2. Test EVERYTHING empirically on mainnet fork
3. Document ACTUAL behavior, not theoretical
4. Only integrate what we've PROVEN works

Reading code gives us hypotheses. Testing gives us truth.

**Current state**: We have V4 hypotheses. We need V4 truth.
