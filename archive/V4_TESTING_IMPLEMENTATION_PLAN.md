# V4 Testing Suite Implementation Plan

**Date**: December 11, 2025
**Status**: Design Phase Complete - Ready for Implementation
**Goal**: Transform 51 stub tests into real empirical validation of V4 integration

---

## Executive Summary

We have **37 real fork tests** (89.2% passing) for V2/V3, but **51 V4 stub tests** that just emit TODO logs. This plan outlines how to implement real V4 tests that prove our integration works before deploying to production.

### Current State
- ✅ **V2**: 15 tests, 14 passing (93.3%)
- ✅ **V3**: 16 tests, 13 passing (81.3%)
- ⚠️ **V4 Discovery**: 7 pool query tests exist but return `sqrtPriceX96 = 0`
- ❌ **V4 Interactions**: 36 stub tests (swaps, positions, fees, hooks)
- ❌ **Integration**: 15 stub tests (vault workflows)

### Critical Discoveries
1. **V4 PoolManager exists** at `0x000000000004444c5dc75cB358380D2e3dE08A90` (24KB bytecode)
2. **Pool queries work** via StateLibrary.getSlot0() - no reverts
3. **No pools found yet** - all queries return sqrtPriceX96 = 0
4. **Gas efficient** - query method doesn't hit gas limits

### Philosophy: Test-Driven V4 Integration

> "Reading code gives us hypotheses. Testing gives us truth."

We will NOT assume ERC404BondingInstance.sol is correct. Every V4 interaction pattern will be proven empirically on mainnet fork before integration.

---

## Phase 1: Pool Discovery Resolution (CRITICAL PATH)

**Status**: Blocked on finding real V4 pools
**Blocker**: All 28 pool combinations return sqrtPriceX96 = 0

### Problem Analysis

We've tested:
- Native ETH (address(0)) × USDC/USDT/DAI × 100/500/3000/10000 bps
- WETH × USDC/USDT/DAI × 100/500/3000/10000 bps
- USDC × USDT × 100/500/3000/10000 bps

**Result**: All return sqrtPriceX96 = 0 (pool doesn't exist or wrong PoolKey)

### Possible Causes

1. **Hooks Required**: Maybe all mainnet V4 pools have hooks attached
   - We're querying with `hooks: address(0)`
   - Need to try querying with real hook addresses

2. **Different Pool Parameters**:
   - Non-standard fee tiers
   - Wrong tick spacing calculation
   - Different currency ordering

3. **Block Height Issue**:
   - Testing at block 23,724,000 (Dec 2024)
   - V4 pools may not exist at this block
   - May need more recent block number

4. **PoolId Calculation Wrong**:
   - PoolKey encoding might differ
   - Field ordering or packing issue

### Resolution Strategies

#### Strategy A: Find Known Pool (RECOMMENDED)
**Action**: Ask user for specific V4 pool configuration
```
"Can you provide a specific V4 pool that exists on mainnet?
- PoolId or full PoolKey (currencies, fee, tickSpacing, hooks)
- This will validate our query method works"
```

**If successful**: Proves query works, gives us reference pool for testing

#### Strategy B: Create Pool in Test
**Action**: Deploy and initialize V4 pool in setUp()
```solidity
function setUp() public {
    // Fork mainnet
    // Deploy minimal pool
    // Initialize with known parameters
    // Test queries against our pool
}
```

**Pros**: Full control, proves query mechanism
**Cons**: Doesn't validate mainnet pool discovery

#### Strategy C: Skip Discovery, Focus on Interactions
**Action**: Use mock/created pools for swap/position tests
```
Rationale:
- Vault creates its own V4 pools (ERC404BondingInstance)
- Pool discovery is validation, not critical path
- Can validate swaps/positions without discovering pools
```

**Pros**: Unblocks testing
**Cons**: Doesn't prove mainnet integration

### Decision Point: Which Strategy?

**Recommendation**: Start with Strategy A (ask user), fall back to Strategy C if needed.

Pool discovery is valuable but not critical - the vault creates its own pools anyway. What's CRITICAL is proving the unlock callback pattern, swap execution, and position management work correctly.

---

## Phase 2: V4 Swap Execution (6 tests)

**Location**: `test/fork/v4/V4SwapRouting.t.sol`
**Dependency**: Pool discovery OR created pool
**Priority**: HIGH - needed for vault swap functionality

### Tests to Implement

#### 2.1: `test_swapExactInputSingle_success()`
**Goal**: Execute 1 ETH → USDC swap via V4

**Implementation Pattern**:
```solidity
contract V4SwapRoutingTest is ForkTestBase, IUnlockCallback {
    struct SwapCallbackData {
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified;
        address recipient;
    }

    function test_swapExactInputSingle_success() public {
        // 1. Get/create pool
        PoolKey memory key = _getOrCreatePool(WETH, USDC, 3000);

        // 2. Wrap ETH to WETH
        deal(address(this), 1 ether);
        IWETH(WETH).deposit{value: 1 ether}();

        // 3. Approve PoolManager
        IERC20(WETH).approve(address(poolManager), 1 ether);

        // 4. Execute swap via unlock
        SwapCallbackData memory data = SwapCallbackData({
            key: key,
            zeroForOne: true, // WETH -> USDC
            amountSpecified: 1 ether,
            recipient: address(this)
        });

        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        poolManager.unlock(abi.encode(data));
        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));

        // 5. Verify output
        uint256 usdcOut = usdcAfter - usdcBefore;
        assertGt(usdcOut, 0, "Should receive USDC");

        emit log_named_uint("USDC output", usdcOut);

        // 6. Compare to V2/V3 pricing
        uint256 v2Output = _getV2Quote(1 ether);
        uint256 v3Output = _getV3Quote(1 ether);

        emit log_named_uint("V2 quote", v2Output);
        emit log_named_uint("V3 quote", v3Output);
        emit log_named_uint("V4 actual", usdcOut);
    }

    function unlockCallback(bytes calldata rawData)
        external
        override
        returns (bytes memory)
    {
        SwapCallbackData memory data = abi.decode(rawData, (SwapCallbackData));

        // Execute swap
        BalanceDelta delta = poolManager.swap(
            data.key,
            IPoolManager.SwapParams({
                zeroForOne: data.zeroForOne,
                amountSpecified: data.amountSpecified,
                sqrtPriceLimitX96: data.zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        // Settle input currency (WETH)
        if (delta.amount0() > 0) {
            Currency.wrap(WETH).settle(poolManager, address(this), uint256(uint128(delta.amount0())), false);
        }

        // Take output currency (USDC)
        if (delta.amount1() < 0) {
            Currency.wrap(USDC).take(poolManager, data.recipient, uint256(uint128(-delta.amount1())), false);
        }

        return "";
    }
}
```

**What This Proves**:
- Unlock callback pattern works
- Can execute swaps via V4
- Actual V4 pricing vs V2/V3
- Native ETH vs WETH handling

#### 2.2: `test_swapExactOutputSingle_success()`
**Goal**: Specify output amount (e.g., "I want exactly 1000 USDC")

**Key Difference**:
```solidity
amountSpecified: -1000e6, // Negative = exact output
```

**What This Proves**:
- Exact output works (useful for vault buying exact token amounts)
- Can calculate required input from desired output

#### 2.3: `test_swapWithSlippageProtection_reverts()`
**Goal**: Verify sqrtPriceLimitX96 provides slippage protection

**Implementation**:
```solidity
function test_swapWithSlippageProtection_reverts() public {
    // Get current pool price
    (uint160 sqrtPriceX96,,) = poolManager.getSlot0(poolId);

    // Set limit 0.1% worse than current price
    uint160 limit = uint160(uint256(sqrtPriceX96) * 999 / 1000);

    // Try swap with tight limit
    vm.expectRevert(); // Should revert if price moves too much
    _swapWithLimit(1 ether, limit);
}
```

**What This Proves**:
- Slippage protection works
- Can set price limits for vault swaps

#### 2.4: `test_compareV4SwapToV2V3_success()`
**Goal**: Empirical price comparison across all DEX versions

**Implementation**:
```solidity
function test_compareV4SwapToV2V3_success() public {
    uint256 amountIn = 1 ether;

    // Execute swaps on all three DEXes
    uint256 v2Out = _executeV2Swap(amountIn);
    uint256 v3Out = _executeV3Swap(amountIn);
    uint256 v4Out = _executeV4Swap(amountIn);

    emit log_named_uint("V2 output", v2Out);
    emit log_named_uint("V3 output", v3Out);
    emit log_named_uint("V4 output", v4Out);

    // Calculate effective fees
    uint256 v2Fee = ((amountIn * 3504) - v2Out) * 10000 / (amountIn * 3504); // bps
    uint256 v3Fee = ((amountIn * 3504) - v3Out) * 10000 / (amountIn * 3504);
    uint256 v4Fee = ((amountIn * 3504) - v4Out) * 10000 / (amountIn * 3504);

    emit log_named_uint("V2 effective fee (bps)", v2Fee);
    emit log_named_uint("V3 effective fee (bps)", v3Fee);
    emit log_named_uint("V4 effective fee (bps)", v4Fee);

    // Document winner
    uint256 best = v2Out > v3Out ? (v2Out > v4Out ? v2Out : v4Out) : (v3Out > v4Out ? v3Out : v4Out);

    if (best == v4Out) {
        emit log_string("WINNER: V4 has best output!");
    }
}
```

**What This Proves**:
- Whether V4 should be primary routing target
- Actual fee impact across all versions
- Routing algorithm priority

#### 2.5: `test_swapMultiHop_success()`
**Goal**: Test WETH → USDC → DAI multi-hop swap

**Implementation**:
```solidity
function test_swapMultiHop_success() public {
    // Path: WETH → USDC → DAI
    PoolKey[] memory path = new PoolKey[](2);
    path[0] = _getPoolKey(WETH, USDC, 3000);
    path[1] = _getPoolKey(USDC, DAI, 500);

    uint256 amountIn = 1 ether;
    uint256 daiOut = _executeMultiHopSwap(path, amountIn);

    emit log_named_uint("DAI output", daiOut);

    // Compare to single-hop WETH → DAI
    uint256 directOut = _executeSingleSwap(WETH, DAI, amountIn);

    emit log_named_uint("Direct output", directOut);
    emit log_named_uint("Multi-hop cost", directOut - daiOut);
}
```

**What This Proves**:
- Multi-hop routing works
- Cost of multi-hop vs direct
- Whether vault should use multi-hop

#### 2.6: `test_swapWithDeadline_reverts()`
**Goal**: Verify deadline protection

**Implementation**:
```solidity
function test_swapWithDeadline_reverts() public {
    // Set deadline in past
    vm.warp(block.timestamp + 1000);

    // Test contract should check deadline before unlock
    vm.expectRevert("Transaction too old");
    _swapWithDeadline(1 ether, block.timestamp - 1);
}
```

**What This Proves**:
- Deadline protection exists
- Vault swaps can't be delayed by miners

### Implementation Order

1. Start with `test_swapExactInputSingle_success()` - proves basic pattern
2. Add `test_compareV4SwapToV2V3_success()` - critical for routing decisions
3. Implement remaining tests once basic pattern works

### Success Criteria

✅ All 6 tests pass
✅ V4 swap output documented vs V2/V3
✅ Unlock callback pattern proven
✅ Slippage protection validated

---

## Phase 3: V4 Position Creation (5 tests)

**Location**: `test/fork/v4/V4PositionCreation.t.sol`
**Dependency**: Swap tests (proves unlock pattern)
**Priority**: HIGH - needed for vault LP functionality

### Critical Questions

1. How to calculate `liquidityDelta` from token amounts?
2. What tick ranges are valid for different fee tiers?
3. How to settle/take currencies in modifyLiquidity callback?
4. Are positions tracked by owner or need separate accounting?

### Tests to Implement

#### 3.1: `test_addLiquidity_success()`
**Goal**: Create basic LP position in V4 pool

**Implementation Pattern**:
```solidity
struct ModifyLiquidityCallbackData {
    PoolKey key;
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    address owner;
}

function test_addLiquidity_success() public {
    // 1. Get/create pool
    PoolKey memory key = _getOrCreatePool(WETH, USDC, 3000);

    // 2. Get current tick
    (uint160 sqrtPriceX96, int24 currentTick,) = poolManager.getSlot0(poolId);

    // 3. Calculate tick range (+/- 10% from current)
    int24 tickSpacing = 60; // For 0.3% fee
    int24 tickLower = ((currentTick - 2000) / tickSpacing) * tickSpacing;
    int24 tickUpper = ((currentTick + 2000) / tickSpacing) * tickSpacing;

    // 4. Calculate liquidity from token amounts
    uint256 amount0 = 1 ether; // WETH
    uint256 amount1 = 3500e6;  // USDC (based on ~$3500/ETH)

    uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
        sqrtPriceX96,
        TickMath.getSqrtPriceAtTick(tickLower),
        TickMath.getSqrtPriceAtTick(tickUpper),
        amount0,
        amount1
    );

    // 5. Prepare tokens
    deal(address(this), 2 ether);
    IWETH(WETH).deposit{value: 1 ether}();
    deal(USDC, address(this), 3500e6);

    IERC20(WETH).approve(address(poolManager), 1 ether);
    IERC20(USDC).approve(address(poolManager), 3500e6);

    // 6. Add liquidity via unlock
    ModifyLiquidityCallbackData memory data = ModifyLiquidityCallbackData({
        key: key,
        tickLower: tickLower,
        tickUpper: tickUpper,
        liquidityDelta: int256(uint256(liquidity)),
        owner: address(this)
    });

    poolManager.unlock(abi.encode(data));

    // 7. Verify position created
    emit log_named_int("Tick lower", tickLower);
    emit log_named_int("Tick upper", tickUpper);
    emit log_named_uint("Liquidity", liquidity);
    emit log_string("Position created successfully!");
}

function unlockCallback(bytes calldata rawData)
    external
    override
    returns (bytes memory)
{
    ModifyLiquidityCallbackData memory data = abi.decode(rawData, (ModifyLiquidityCallbackData));

    // Modify liquidity
    (BalanceDelta delta,) = poolManager.modifyLiquidity(
        data.key,
        IPoolManager.ModifyLiquidityParams({
            tickLower: data.tickLower,
            tickUpper: data.tickUpper,
            liquidityDelta: data.liquidityDelta,
            salt: bytes32(0)
        }),
        ""
    );

    // Settle currencies (pay into pool)
    if (delta.amount0() > 0) {
        Currency.wrap(WETH).settle(poolManager, data.owner, uint256(uint128(delta.amount0())), false);
    }
    if (delta.amount1() > 0) {
        Currency.wrap(USDC).settle(poolManager, data.owner, uint256(uint128(delta.amount1())), false);
    }

    return "";
}
```

**What This Proves**:
- Can create V4 positions
- Liquidity calculation works
- Tick range selection correct
- Settle pattern for adding liquidity

#### 3.2: `test_addLiquidityFullRange_success()`
**Goal**: Test full-range position (like V2)

**Key Difference**:
```solidity
int24 tickLower = TickMath.MIN_TICK;
int24 tickUpper = TickMath.MAX_TICK;
```

**What This Proves**:
- Full-range positions work
- Vault can deploy to full range if desired

#### 3.3: `test_addLiquidityConcentrated_success()`
**Goal**: Test narrow concentrated position

**Key Difference**:
```solidity
// +/- 1% from current price
int24 tickLower = ((currentTick - 100) / tickSpacing) * tickSpacing;
int24 tickUpper = ((currentTick + 100) / tickSpacing) * tickSpacing;
```

**What This Proves**:
- Concentrated liquidity works
- Can capture more fees with tight range

#### 3.4: `test_addLiquidityWithInvalidTicks_reverts()`
**Goal**: Verify tick validation

**Implementation**:
```solidity
function test_addLiquidityWithInvalidTicks_reverts() public {
    PoolKey memory key = _getOrCreatePool(WETH, USDC, 3000);

    // tickLower >= tickUpper should revert
    int24 tickLower = 1000;
    int24 tickUpper = 999;

    vm.expectRevert();
    _addLiquidity(key, tickLower, tickUpper, 1e18);
}
```

**What This Proves**:
- Input validation works
- Can't create invalid positions

#### 3.5: `test_addLiquidityWithoutApproval_reverts()`
**Goal**: Verify approval required

**Implementation**:
```solidity
function test_addLiquidityWithoutApproval_reverts() public {
    PoolKey memory key = _getOrCreatePool(WETH, USDC, 3000);

    // Don't approve PoolManager
    // IERC20(WETH).approve(address(poolManager), 0);

    vm.expectRevert(); // Should fail during settle
    _addLiquidity(key, -1000, 1000, 1e18);
}
```

**What This Proves**:
- Approval requirement enforced
- Settle fails without approval

### Implementation Order

1. Start with `test_addLiquidity_success()` - proves basic pattern
2. Add `test_addLiquidityFullRange_success()` - vault likely uses full-range
3. Implement remaining tests for validation

### Success Criteria

✅ All 5 tests pass
✅ Position creation pattern proven
✅ Liquidity calculations validated
✅ Full-range and concentrated positions work

---

## Phase 4: V4 Fee Collection (5 tests)

**Location**: `test/fork/v4/V4FeeCollection.t.sol`
**Dependency**: Position creation + swaps
**Priority**: MEDIUM - needed for vault fee harvesting

### Critical Questions

1. How do fees accumulate in V4 positions?
2. How to collect fees (another unlock callback)?
3. Is fee growth tracked per position?
4. Are fees in native ETH or wrapped?

### Tests to Implement

#### 4.1: `test_collectFees_afterSwaps_success()`
**Goal**: Verify fees accumulate and can be collected

**Implementation Pattern**:
```solidity
function test_collectFees_afterSwaps_success() public {
    // 1. Create position
    PoolKey memory key = _getOrCreatePool(WETH, USDC, 3000);
    (int24 tickLower, int24 tickUpper) = _getFullRangeTicks();
    _addLiquidity(key, tickLower, tickUpper, 10e18);

    // 2. Execute swaps to generate fees
    for (uint i = 0; i < 10; i++) {
        _executeSwap(key, 1 ether);
    }

    // 3. Check position for accrued fees
    // TODO: How to query position fee growth?

    // 4. Collect fees
    (uint256 amount0, uint256 amount1) = _collectFees(key, tickLower, tickUpper);

    emit log_named_uint("WETH fees collected", amount0);
    emit log_named_uint("USDC fees collected", amount1);

    assertGt(amount0 + amount1, 0, "Should collect fees");
}
```

**What This Proves**:
- Fees accumulate from swaps
- Can collect fees successfully
- Fee amounts are reasonable

#### 4.2: `test_feeAccumulation_proportionalToLiquidity()`
**Goal**: Verify larger positions earn more fees

**Implementation**:
```solidity
function test_feeAccumulation_proportionalToLiquidity() public {
    PoolKey memory key = _getOrCreatePool(WETH, USDC, 3000);

    // Create two positions with different sizes
    address small = makeAddr("small");
    address large = makeAddr("large");

    vm.prank(small);
    _addLiquidity(key, -1000, 1000, 1e18); // 1 ETH liquidity

    vm.prank(large);
    _addLiquidity(key, -1000, 1000, 10e18); // 10 ETH liquidity

    // Execute swaps
    for (uint i = 0; i < 10; i++) {
        _executeSwap(key, 1 ether);
    }

    // Collect fees for both
    vm.prank(small);
    (uint256 small0, uint256 small1) = _collectFees(key, -1000, 1000);

    vm.prank(large);
    (uint256 large0, uint256 large1) = _collectFees(key, -1000, 1000);

    emit log_named_uint("Small position fees", small0 + small1);
    emit log_named_uint("Large position fees", large0 + large1);

    // Large should earn ~10x fees
    assertApproxEqRel(large0 + large1, (small0 + small1) * 10, 0.1e18); // Within 10%
}
```

**What This Proves**:
- Fee distribution is proportional
- Multiple positions work correctly

#### 4.3: `test_feesInCorrectCurrency()`
**Goal**: Verify fees are in expected currencies

**Implementation**:
```solidity
function test_feesInCorrectCurrency() public {
    PoolKey memory key = _getOrCreatePool(WETH, USDC, 3000);
    _addLiquidity(key, -1000, 1000, 10e18);

    // Execute swaps
    for (uint i = 0; i < 10; i++) {
        _executeSwap(key, 1 ether);
    }

    // Collect
    uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
    uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

    _collectFees(key, -1000, 1000);

    uint256 wethAfter = IERC20(WETH).balanceOf(address(this));
    uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));

    emit log_named_uint("WETH received", wethAfter - wethBefore);
    emit log_named_uint("USDC received", usdcAfter - usdcBefore);

    assertGt(wethAfter - wethBefore, 0, "Should receive WETH fees");
    assertGt(usdcAfter - usdcBefore, 0, "Should receive USDC fees");
}
```

**What This Proves**:
- Fees come in correct currencies
- No native ETH vs WETH confusion

#### 4.4: `test_collectFees_multipleTimesCompound()`
**Goal**: Verify fees can be collected incrementally

**Implementation**:
```solidity
function test_collectFees_multipleTimesCompound() public {
    PoolKey memory key = _getOrCreatePool(WETH, USDC, 3000);
    _addLiquidity(key, -1000, 1000, 10e18);

    uint256 totalFees0 = 0;
    uint256 totalFees1 = 0;

    for (uint i = 0; i < 3; i++) {
        // Generate fees
        for (uint j = 0; j < 5; j++) {
            _executeSwap(key, 1 ether);
        }

        // Collect
        (uint256 amount0, uint256 amount1) = _collectFees(key, -1000, 1000);
        totalFees0 += amount0;
        totalFees1 += amount1;

        emit log_named_uint("Collection round", i + 1);
        emit log_named_uint("Fees collected", amount0 + amount1);
    }

    emit log_named_uint("Total fees collected", totalFees0 + totalFees1);
    assertGt(totalFees0 + totalFees1, 0, "Should collect fees each time");
}
```

**What This Proves**:
- Can collect fees multiple times
- Fees don't get stuck
- Vault can harvest periodically

#### 4.5: `test_removeLiquidity_collectsRemainingFees()`
**Goal**: Verify removing liquidity also collects fees

**Implementation**:
```solidity
function test_removeLiquidity_collectsRemainingFees() public {
    PoolKey memory key = _getOrCreatePool(WETH, USDC, 3000);
    _addLiquidity(key, -1000, 1000, 10e18);

    // Generate fees
    for (uint i = 0; i < 10; i++) {
        _executeSwap(key, 1 ether);
    }

    // Remove liquidity (should auto-collect fees)
    uint256 balanceBefore = IERC20(WETH).balanceOf(address(this)) + IERC20(USDC).balanceOf(address(this));

    _removeLiquidity(key, -1000, 1000, -10e18); // Negative = remove

    uint256 balanceAfter = IERC20(WETH).balanceOf(address(this)) + IERC20(USDC).balanceOf(address(this));

    uint256 received = balanceAfter - balanceBefore;

    // Should receive principal + fees
    emit log_named_uint("Total received", received);
    assertGt(received, 10e18, "Should receive more than principal");
}
```

**What This Proves**:
- Removing liquidity collects fees
- No fees left behind
- Vault can exit cleanly

### Implementation Order

1. Start with `test_collectFees_afterSwaps_success()` - proves basic pattern
2. Add `test_feeAccumulation_proportionalToLiquidity()` - validates distribution
3. Implement remaining tests for completeness

### Success Criteria

✅ All 5 tests pass
✅ Fee collection pattern proven
✅ Fee distribution validated
✅ Can collect fees multiple times

---

## Phase 5: V4 Hook Taxation (6 tests)

**Location**: `test/fork/v4/V4HookTaxation.t.sol`
**Dependency**: Swaps + positions
**Priority**: CRITICAL - determines if vault should use V4 for swaps

### Critical Questions

1. Does UltraAlignmentV4Hook actually tax swaps?
2. What is the actual tax rate?
3. How does hook taxation affect pool pricing?
4. Can vault's own LP position be double-taxed?
5. Is hook tax paid in ETH or token?

### Tests to Implement

#### 5.1: `test_hookTaxesSwaps_success()`
**Goal**: Measure actual hook tax amount

**Implementation Pattern**:
```solidity
function test_hookTaxesSwaps_success() public {
    // 1. Create pool WITH hook
    PoolKey memory keyWithHook = _createPoolWithHook(WETH, USDC, 3000, ultraAlignmentHook);

    // 2. Create pool WITHOUT hook (for comparison)
    PoolKey memory keyNoHook = _createPoolWithHook(WETH, USDC, 3000, IHooks(address(0)));

    // 3. Execute same swap on both
    uint256 amountIn = 1 ether;
    uint256 outputWithHook = _executeSwap(keyWithHook, amountIn);
    uint256 outputNoHook = _executeSwap(keyNoHook, amountIn);

    // 4. Calculate tax
    uint256 tax = outputNoHook - outputWithHook;
    uint256 taxRate = (tax * 10000) / outputNoHook; // bps

    emit log_named_uint("Output with hook", outputWithHook);
    emit log_named_uint("Output without hook", outputNoHook);
    emit log_named_uint("Tax amount", tax);
    emit log_named_uint("Tax rate (bps)", taxRate);

    // 5. Verify tax is reasonable (should be ~1% = 100 bps)
    assertApproxEqAbs(taxRate, 100, 10, "Tax should be ~1%");
}
```

**What This Proves**:
- Hook actually taxes swaps
- Tax rate is as expected
- Tax amount is measurable

#### 5.2: `test_hookDoubleTaxation_onVaultPosition()`
**Goal**: CRITICAL - verify vault LP position isn't double-taxed

**Implementation**:
```solidity
function test_hookDoubleTaxation_onVaultPosition() public {
    // This is the CRITICAL test for vault V4 integration
    // Scenario: Vault creates LP position in V4 pool with hook
    // Question: When someone swaps against vault's position, does hook tax the vault's LP?

    PoolKey memory key = _createPoolWithHook(WETH, USDC, 3000, ultraAlignmentHook);

    // 1. Vault creates position
    address vault = makeAddr("vault");
    vm.startPrank(vault);
    _addLiquidity(key, -1000, 1000, 10e18);
    vm.stopPrank();

    // 2. User swaps (generates fees for vault)
    address user = makeAddr("user");
    vm.startPrank(user);
    deal(user, 1 ether);
    uint256 outputUser = _executeSwap(key, 1 ether);
    vm.stopPrank();

    // 3. Vault collects fees
    vm.startPrank(vault);
    (uint256 fees0, uint256 fees1) = _collectFees(key, -1000, 1000);
    vm.stopPrank();

    // 4. Check if fees were taxed
    uint256 expectedFees = (1 ether * 30) / 10000; // 0.3% fee tier
    uint256 actualFees = fees0 + fees1;

    emit log_named_uint("Expected fees (no tax)", expectedFees);
    emit log_named_uint("Actual fees collected", actualFees);

    // If actualFees < expectedFees, vault is being taxed
    if (actualFees < expectedFees * 99 / 100) {
        emit log_string("WARNING: Vault position is being taxed by hook!");
        emit log_string("DO NOT use V4 for vault LP positions");
    } else {
        emit log_string("SUCCESS: Vault fees not taxed");
        emit log_string("Safe to use V4 for vault LP positions");
    }

    // Assert fees are close to expected (allowing for price impact)
    assertApproxEqRel(actualFees, expectedFees, 0.1e18, "Fees should not be taxed");
}
```

**What This Proves**:
- Whether vault can safely use V4 for LP
- If hook taxes LP providers
- Critical go/no-go decision for V4 integration

#### 5.3: `test_hookTaxDestination()`
**Goal**: Verify where hook tax goes

**Implementation**:
```solidity
function test_hookTaxDestination() public {
    PoolKey memory key = _createPoolWithHook(WETH, USDC, 3000, ultraAlignmentHook);

    // Get hook's vault address (where tax should go)
    address vaultAddress = UltraAlignmentV4Hook(address(ultraAlignmentHook)).vault();

    uint256 vaultBalanceBefore = IERC20(USDC).balanceOf(vaultAddress);

    // Execute swap
    _executeSwap(key, 1 ether);

    uint256 vaultBalanceAfter = IERC20(USDC).balanceOf(vaultAddress);
    uint256 taxReceived = vaultBalanceAfter - vaultBalanceBefore;

    emit log_named_address("Tax destination", vaultAddress);
    emit log_named_uint("Tax received", taxReceived);

    assertGt(taxReceived, 0, "Vault should receive tax");
}
```

**What This Proves**:
- Tax goes to correct destination
- Vault receives hook taxation
- Tax accounting is correct

#### 5.4: `test_hookTaxRate_configurable()`
**Goal**: Verify tax rate can be adjusted

**Implementation**:
```solidity
function test_hookTaxRate_configurable() public {
    // Test different tax rates (if configurable)
    uint24[] memory rates = new uint24[](3);
    rates[0] = 100;  // 1%
    rates[1] = 50;   // 0.5%
    rates[2] = 200;  // 2%

    for (uint i = 0; i < rates.length; i++) {
        // Set tax rate (if configurable)
        // _setHookTaxRate(rates[i]);

        PoolKey memory key = _createPoolWithHook(WETH, USDC, 3000, ultraAlignmentHook);
        uint256 output = _executeSwap(key, 1 ether);

        emit log_named_uint("Tax rate (bps)", rates[i]);
        emit log_named_uint("Output", output);
    }
}
```

**What This Proves**:
- Tax rate is configurable (if supported)
- Different tax rates work correctly

#### 5.5: `test_compareHookedVsUnhookedPools()`
**Goal**: Price impact of using hooked pool

**Implementation**:
```solidity
function test_compareHookedVsUnhookedPools() public {
    PoolKey memory hooked = _createPoolWithHook(WETH, USDC, 3000, ultraAlignmentHook);
    PoolKey memory unhooked = _createPoolWithHook(WETH, USDC, 3000, IHooks(address(0)));

    uint256 outputHooked = _executeSwap(hooked, 1 ether);
    uint256 outputUnhooked = _executeSwap(unhooked, 1 ether);

    uint256 costOfHook = outputUnhooked - outputHooked;
    uint256 costBps = (costOfHook * 10000) / outputUnhooked;

    emit log_named_uint("Hooked output", outputHooked);
    emit log_named_uint("Unhooked output", outputUnhooked);
    emit log_named_uint("Cost of hook (bps)", costBps);

    // Routing decision: is hook cost worth it?
    if (costBps > 100) {
        emit log_string("RECOMMENDATION: Avoid hooked pools for swaps");
    } else {
        emit log_string("RECOMMENDATION: Hook cost acceptable");
    }
}
```

**What This Proves**:
- Cost/benefit of using hooked pools
- Routing algorithm decision

#### 5.6: `test_hookTaxOnLargeTrades()`
**Goal**: Verify tax scales correctly with trade size

**Implementation**:
```solidity
function test_hookTaxOnLargeTrades() public {
    PoolKey memory key = _createPoolWithHook(WETH, USDC, 3000, ultraAlignmentHook);

    uint256[] memory sizes = new uint256[](4);
    sizes[0] = 0.1 ether;
    sizes[1] = 1 ether;
    sizes[2] = 10 ether;
    sizes[3] = 100 ether;

    for (uint i = 0; i < sizes.length; i++) {
        uint256 output = _executeSwap(key, sizes[i]);
        uint256 effectiveRate = (sizes[i] * 3500 - output) * 10000 / (sizes[i] * 3500);

        emit log_named_uint("Trade size (ETH)", sizes[i] / 1e18);
        emit log_named_uint("Effective rate (bps)", effectiveRate);
    }
}
```

**What This Proves**:
- Tax scales properly
- Large trades don't get excessive tax

### Implementation Order

1. **CRITICAL FIRST**: `test_hookDoubleTaxation_onVaultPosition()` - go/no-go decision
2. If passes: Implement `test_hookTaxesSwaps_success()` for measurement
3. Add remaining tests for completeness

### Success Criteria

✅ All 6 tests pass
✅ **CRITICAL**: Vault LP positions are NOT double-taxed
✅ Hook tax rate documented
✅ Tax destination verified
✅ Routing decision made (use hooked pools or not)

---

## Phase 6: Integration Tests (15 tests)

**Location**: `test/fork/integration/`
**Dependency**: All V4 component tests
**Priority**: MEDIUM - validates end-to-end workflows

### Test Suites

#### 6.1: VaultSwapToV4Position.t.sol (6 tests)
**Goal**: Vault deposits → swap → V4 LP position

**Tests**:
1. Full workflow: deposit → optimal swap → add liquidity
2. Position rebalancing after price movement
3. Multi-deposit scenario (multiple users)
4. Fee collection and reinvestment
5. Emergency liquidity removal
6. Vault position accounting accuracy

#### 6.2: VaultFullCycle.t.sol (5 tests)
**Goal**: Complete vault lifecycle

**Tests**:
1. Deposit → LP → fees → withdraw
2. Multiple epochs with fee compounding
3. Early withdrawal penalty calculation
4. Late withdrawal bonus distribution
5. Vault utilization vs pricing validation

#### 6.3: VaultMultiDeposit.t.sol (4 tests)
**Goal**: Multiple users interacting

**Tests**:
1. Sequential deposits with different sizes
2. Concurrent swaps during same epoch
3. Pro-rata fee distribution
4. Late depositor doesn't dilute early depositors

### Implementation Approach

These tests combine multiple components:
- Vault contract logic
- V4 swaps (from Phase 2)
- V4 positions (from Phase 3)
- Fee collection (from Phase 4)

Start implementation after all component tests pass.

---

## Phase 7: Pool Initialization Tests (7 tests)

**Location**: `test/fork/v4/V4PoolInitialization.t.sol`
**Dependency**: Basic V4 interaction proven
**Priority**: LOW - nice to have, not critical path

### Tests to Implement

These tests validate pool creation patterns used by ERC404BondingInstance:

1. `test_initializePool_success()` - Basic pool creation
2. `test_initializePool_withHook_success()` - Pool with hook attached
3. `test_initializePool_duplicateReverts()` - Can't initialize twice
4. `test_poolInitialPrice_matchesExpectation()` - sqrtPriceX96 calculation
5. `test_initializePoolWithInvalidFee_reverts()` - Fee validation
6. `test_queryPoolAfterInitialization_success()` - State query works
7. `test_swapAfterInitialization_success()` - Can swap immediately

These tests are less critical because ERC404BondingInstance already has pool initialization code. These tests would validate that code works correctly.

---

## Implementation Strategy

### Recommended Sequence

1. **Phase 1**: Resolve pool discovery (ask user for known pool)
2. **Phase 2**: Implement V4 swap tests (proves unlock pattern)
3. **Phase 3**: Implement position creation tests (proves LP pattern)
4. **Phase 5**: **CRITICAL** - Hook taxation tests (go/no-go decision)
5. **Phase 4**: Fee collection tests (completes V4 component testing)
6. **Phase 6**: Integration tests (validates end-to-end)
7. **Phase 7**: Pool initialization tests (optional)

### Parallel Work Opportunities

Once unlock callback pattern is proven in Phase 2, can work on:
- Phase 3 (positions) and Phase 4 (fees) in parallel
- Phase 5 (hooks) depends on Phase 2+3

### Test Development Pattern

For each test:
1. Read equivalent V2/V3 test for pattern reference
2. Review ERC404BondingInstance.sol for V4 usage patterns
3. Implement test with extensive logging
4. Run on fork, document actual behavior
5. Compare to hypothesis
6. Iterate until passing

### Documentation Requirements

For each implemented test:
1. Log all inputs and outputs
2. Document unexpected behavior
3. Compare to V2/V3 equivalents
4. Update empirical findings document
5. Note any deviations from ERC404BondingInstance patterns

---

## Success Metrics

### Test Coverage
- ✅ 37 real V2/V3 tests (already passing)
- 🎯 6 V4 swap tests implemented and passing
- 🎯 5 V4 position tests implemented and passing
- 🎯 5 V4 fee collection tests implemented and passing
- 🎯 6 V4 hook taxation tests implemented and passing
- 🎯 15 integration tests implemented and passing

**Target**: 74 real fork tests (51 new V4 tests + 37 existing V2/V3 tests)

### Critical Validations
- ✅ Unlock callback pattern works
- ✅ Can execute swaps via V4
- ✅ Can create LP positions
- ✅ Can collect fees
- ✅ **Vault LP positions NOT double-taxed by hook**
- ✅ V4 pricing competitive with V2/V3

### Routing Decisions
Based on test results, document:
- When to route swaps through V4 vs V2/V3
- Whether to use hooked pools for swaps
- Whether to use V4 for vault LP positions
- Optimal fee tiers for V4 pools

### Integration Confidence
- ✅ All V4 patterns validated empirically
- ✅ No assumptions based on reading code
- ✅ Every integration point tested on mainnet fork
- ✅ Ready for production deployment

---

## Risk Mitigation

### Testing Risks

**Risk**: Can't find existing V4 pools
**Mitigation**: Create pools in tests, validate patterns work

**Risk**: Hook taxation blocks V4 LP integration
**Mitigation**: Early testing of hook double-taxation (Phase 5.2)

**Risk**: Gas limits prevent fork testing
**Mitigation**: Keep tests isolated, use --gas-limit flag

**Risk**: Unlock callback complexity introduces bugs
**Mitigation**: Extensive logging, compare to V2/V3 patterns

### Integration Risks

**Risk**: V4 patterns in ERC404BondingInstance are incorrect
**Mitigation**: Don't trust production code, test everything

**Risk**: V4 pricing worse than V2/V3
**Mitigation**: Comparative testing, routing flexibility

**Risk**: V4 pool discovery fails in production
**Mitigation**: Vault creates own pools anyway

**Risk**: Hook taxation changes after deployment
**Mitigation**: Make hook tax rate configurable, test multiple rates

---

## Resource Requirements

### RPC Usage
- Anvil fork needs stable mainnet RPC
- Each test file needs fresh fork instance
- Estimated: ~100 RPC calls per test file

### Development Time
- Phase 2 (swaps): 2-3 implementation sessions
- Phase 3 (positions): 2-3 implementation sessions
- Phase 4 (fees): 1-2 implementation sessions
- Phase 5 (hooks): 2-3 implementation sessions (critical)
- Phase 6 (integration): 3-4 implementation sessions

**Total estimated**: 10-15 focused implementation sessions

### Testing Infrastructure
- Anvil mainnet fork (already working)
- Foundry test framework (already set up)
- Helper contracts for unlock callbacks
- Mock contracts for isolated testing

---

## Decision Points

### Critical Go/No-Go Decisions

1. **After Phase 2**: Can we execute V4 swaps reliably?
   - If NO: Stick to V2/V3 for swaps
   - If YES: Proceed to position creation

2. **After Phase 5.2**: Are vault LP positions double-taxed?
   - If YES: DO NOT use V4 for vault LP
   - If NO: Safe to proceed with V4 LP integration

3. **After Phase 2.4**: Is V4 pricing competitive?
   - If NO: Deprioritize V4 in routing
   - If YES: Make V4 primary routing target

### Routing Algorithm Inputs

Based on test results, routing algorithm will use:
- V4 output vs V2/V3 output (from Phase 2.4)
- Hook tax cost (from Phase 5.1)
- Slippage tolerance (from Phase 2.3)
- Gas costs (to be measured)
- Liquidity depth (from pool queries)

---

## Appendix: Helper Contracts Needed

### UnlockCallbackHelper.sol
```solidity
// Helper contract for implementing IUnlockCallback in tests
abstract contract UnlockCallbackHelper is IUnlockCallback {
    enum CallbackType { SWAP, MODIFY_LIQUIDITY, COLLECT_FEES }

    function unlockCallback(bytes calldata data)
        external
        override
        returns (bytes memory);

    // Helper functions for encoding callback data
    function _encodeSwapData(...) internal pure returns (bytes memory);
    function _encodeModifyLiquidityData(...) internal pure returns (bytes memory);
    function _encodeCollectFeesData(...) internal pure returns (bytes memory);
}
```

### V4TestHelpers.sol
```solidity
// Common helper functions for V4 tests
library V4TestHelpers {
    function getFullRangeTicks() internal pure returns (int24, int24);
    function getTightRangeTicks(int24 current) internal pure returns (int24, int24);
    function calculateLiquidity(...) internal pure returns (uint128);
    function createPoolKey(...) internal pure returns (PoolKey memory);
}
```

### V4PoolFactory.sol
```solidity
// Helper for creating test pools
contract V4PoolFactory {
    function createTestPool(
        address token0,
        address token1,
        uint24 fee,
        IHooks hook
    ) external returns (PoolKey memory);

    function initializePool(
        PoolKey memory key,
        uint160 sqrtPriceX96
    ) external;
}
```

---

## Conclusion

This plan transforms **51 stub tests** into **51 real empirical tests** that prove V4 integration works correctly before production deployment.

### Key Principles

1. **No assumptions** - test everything empirically
2. **Document everything** - log all inputs/outputs
3. **Compare to baseline** - always reference V2/V3
4. **Fail fast** - critical tests early in sequence
5. **Honest assessment** - don't hide failures

### Next Immediate Actions

1. **Resolve pool discovery** - ask user for known V4 pool config
2. **Implement first swap test** - proves unlock callback pattern
3. **Run on fork** - document actual behavior
4. **Iterate** - fix issues, prove pattern works
5. **Proceed to next phase** - build on proven foundation

### Expected Outcomes

After completing this plan:
- ✅ 88+ real fork tests (37 V2/V3 + 51 V4)
- ✅ All V4 integration patterns validated
- ✅ Routing algorithm inputs documented
- ✅ Go/no-go decisions made on V4 usage
- ✅ Production-ready with empirical confidence

**This plan provides the foundation for safe V4 integration.** Every number, every decision, backed by real mainnet data.
