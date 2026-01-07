# V4 Uniswap Integration: Systematic Validation Plan

**Created**: December 11, 2025
**Status**: Planning Phase
**Goal**: Replace all V4 stubs with empirically validated, working implementations

---

## Executive Summary

### Current State
- **V2/V3**: 37 real fork tests, 33 passing (89.2%) - PROVEN behavior
- **V4**: 36 stub tests that emit TODO messages - NO empirical validation
- **Problem**: Cannot integrate V4 into production until we PROVE it works

### Critical Contracts Depending on V4
1. `src/vaults/UltraAlignmentVault.sol` - Needs V4 swap routing & LP position management
2. `src/factories/erc404/hooks/UltraAlignmentV4Hook.sol` - Hook taxation implementation
3. `src/factories/erc404/ERC404BondingInstance.sol` - V4 liquidity deployment

### Why This Matters
Without validated V4 integration:
- Cannot deploy liquidity to V4 pools
- Cannot swap through V4 for alignment token purchases
- Cannot claim fees from V4 LP positions
- Cannot validate hook taxation behavior
- **RISK**: Integration failures in production

---

## Phase 1: Pool Discovery & Querying (CRITICAL)

### Objective
Prove we can find and query V4 pools on mainnet.

### Tests to Implement

#### 1.1 V4 Pool Manager Verification
**File**: `test/fork/v4/V4SwapRouting.t.sol`
**Test**: `test_queryV4PoolManager_deployed()`
**Status**: ✅ COMPLETE (passing)

**Validated**:
- V4 PoolManager exists at `0x000000000004444c5dc75cB358380D2e3dE08A90`
- Contract has code (24,009 bytes)
- Can interact with contract

#### 1.2 Pool State Querying via StateLibrary
**Test**: `test_queryV4_WETH_USDC_allFees()`
**Current Status**: Stub implementation exists, NOT TESTED
**Priority**: CRITICAL - Everything depends on this

**Implementation Strategy**:
```solidity
// Use extsload to query pool state directly
function _queryPoolState(PoolId poolId) internal returns (bool exists) {
    // Query pool slot0 using extsload
    (bool success, bytes memory data) = address(poolManager).staticcall(
        abi.encodeWithSignature("extsload(bytes32)", _getPoolStateSlot(poolId))
    );

    if (success && data.length >= 32) {
        bytes32 slot0Data = abi.decode(data, (bytes32));
        uint160 sqrtPriceX96 = uint160(uint256(slot0Data));

        if (sqrtPriceX96 > 0) {
            // Pool exists! Extract state
            int24 tick = int24(int256(uint256(slot0Data) >> 160));
            uint24 protocolFee = uint24(uint256(slot0Data) >> 184);
            uint24 lpFee = uint24(uint256(slot0Data) >> 208);
            return true;
        }
    }
    return false;
}
```

**What We'll Discover**:
- Do ETH/USDC V4 pools exist? (fees: 100, 500, 3000, 10000)
- Do ETH/USDT V4 pools exist?
- Do ETH/DAI V4 pools exist?
- What are actual pool prices (sqrtPriceX96)?
- Which pools have hooks attached?

**Test Matrix**:
| Pool Pair | Fee Tier | Hook | Expected Result |
|-----------|----------|------|-----------------|
| WETH/USDC | 500 | None | Should exist |
| WETH/USDC | 3000 | None | Should exist |
| WETH/USDT | 500 | None | Should exist |
| WETH/DAI | 3000 | None | Should exist |
| ETH(0)/USDC | 500 | None | Test native ETH |

**Success Criteria**:
- Find at least 1 working V4 pool
- Successfully extract sqrtPriceX96 and tick
- Validate pool state matches expectations
- Document all discovered pools

**Failure Modes to Handle**:
- getSlot0() reverts → Try extsload directly
- sqrtPriceX96 = 0 → Pool doesn't exist, try different pair
- Invalid tick values → PoolKey construction wrong
- Gas limit exceeded → Use cached addresses

**Action Items**:
1. Run `forge test --mp test/fork/v4/V4SwapRouting.t.sol::test_queryV4_WETH_USDC_allFees --fork-url $ETH_RPC_URL -vvv`
2. Document results in `V4_POOL_DISCOVERY.md`
3. If failures: Debug PoolKey construction
4. Once working: Scan all major token pairs

**Deliverable**: List of confirmed V4 pools with state data

---

## Phase 2: V4 Swap Execution (HIGH PRIORITY)

### Objective
Execute real swaps through V4 pools using unlock callback pattern.

### Prerequisites
- Phase 1 complete (found at least 1 V4 pool)
- Working RPC connection
- Test account with ETH balance

### Tests to Implement

#### 2.1 Basic Swap Test (Exact Input)
**Test**: `test_swapExactInputSingle_success()`
**Current Status**: TODO stub

**Implementation Pattern**:
```solidity
contract V4SwapTester is IUnlockCallback {
    IPoolManager poolManager;

    function testSwap() public {
        // Prepare swap params
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)), // ETH
            currency1: Currency.wrap(USDC),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // Encode swap data for unlock callback
        bytes memory swapData = abi.encode(key, true, 1 ether, 0);

        // Execute via unlock
        BalanceDelta delta = abi.decode(
            poolManager.unlock(swapData),
            (BalanceDelta)
        );

        // Validate output
        assertGt(-delta.amount1(), 0, "Should receive USDC");
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) =
            abi.decode(data, (PoolKey, bool, int256, uint160));

        // Execute swap
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            ""
        );

        // Settle input currency
        key.currency0.settle(poolManager, address(this), uint256(amountSpecified), false);

        // Take output currency
        key.currency1.take(poolManager, address(this), uint256(-delta.amount1()), false);

        return abi.encode(delta);
    }
}
```

**What We'll Learn**:
- How to structure unlock callback
- How to settle/take currencies
- Actual swap output vs. V2/V3
- Gas costs for V4 swaps
- Slippage behavior

**Test Cases**:
1. 1 ETH → USDC (exact input)
2. 0.1 ETH → USDC (small amount)
3. 10 ETH → USDC (large amount, test slippage)
4. Swap with sqrtPriceLimitX96 protection
5. Swap that reverts due to price limit

**Success Criteria**:
- Swap executes without reverting
- Receive expected amount of output token
- Output matches V2/V3 pricing (±0.5%)
- Can specify slippage protection

#### 2.2 Exact Output Swap
**Test**: `test_swapExactOutputSingle_success()`

**Key Difference**:
```solidity
// Exact input: amountSpecified > 0 (I want to spend 1 ETH)
// Exact output: amountSpecified < 0 (I want to receive 3000 USDC)
```

**Test Cases**:
1. Receive exactly 1000 USDC
2. Verify input amount is reasonable
3. Compare to V3 exactOutput

#### 2.3 V2/V3/V4 Price Comparison
**Test**: `test_compareV4SwapToV2V3_success()`
**Priority**: CRITICAL for routing algorithm

**Comparison Matrix**:
| Amount | V2 Output | V3 Output | V4 Output | Best Route |
|--------|-----------|-----------|-----------|------------|
| 1 ETH  | 3384 USDC | 3385 USDC | ??? USDC  | TBD |
| 5 ETH  | 16920 USDC| 16925 USDC| ??? USDC  | TBD |
| 10 ETH | 33840 USDC| 33850 USDC| ??? USDC  | TBD |

**Expected Results**:
- **IF** V4 pool has deep liquidity: V4 ≈ V3
- **IF** V4 pool has hook: V4 < V3 (worse due to tax)
- **IF** V4 pool is new: V4 < V2 (lower liquidity)

**Routing Algorithm Decision**:
```
IF alignment_token == vault_owned_token:
    USE V4 (benefits our own pool)
ELSE IF v4_price > v3_price AND no_hook:
    USE V4
ELSE IF v3_price > v2_price:
    USE V3
ELSE:
    USE V2
```

**Deliverable**: Routing decision tree backed by empirical data

---

## Phase 3: V4 Position Creation (MEDIUM PRIORITY)

### Objective
Create LP positions in V4 pools using modifyLiquidity.

### Prerequisites
- Phase 2 complete (can execute V4 transactions)
- Understanding of tick math
- WETH + target token available

### Tests to Implement

#### 3.1 Basic LP Position
**Test**: `test_addLiquidity_success()`
**File**: `test/fork/v4/V4PositionCreation.t.sol`

**Implementation Pattern**:
```solidity
function unlockCallback_addLiquidity(bytes calldata data) external returns (bytes memory) {
    (PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity) =
        abi.decode(data, (PoolKey, int24, int24, uint128));

    // Create position
    (BalanceDelta delta, ) = poolManager.modifyLiquidity(
        key,
        IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(0)
        }),
        ""
    );

    // Settle both currencies
    if (delta.amount0() < 0) {
        key.currency0.settle(poolManager, address(this), uint256(-delta.amount0()), false);
    }
    if (delta.amount1() < 0) {
        key.currency1.settle(poolManager, address(this), uint256(-delta.amount1()), false);
    }

    return abi.encode(delta);
}
```

**Test Cases**:
1. Full range position (min tick → max tick)
2. Concentrated position (±10% from current price)
3. Narrow position (±1% from current price)
4. Position with WETH/USDC
5. Position with native ETH/USDC

**What We'll Discover**:
- How to calculate liquidity from token amounts
- Valid tick ranges for different fee tiers
- How much of each token is actually consumed
- Position ID/key generation
- How to query position state later

#### 3.2 Position Querying
**Test**: `test_queryPosition_afterCreation()`

**Implementation**:
```solidity
function _getPositionKey(address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
    internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(owner, tickLower, tickUpper, salt));
}

function _queryPosition(PoolKey memory poolKey, bytes32 positionKey)
    internal returns (Position.Info memory) {
    // Use StateLibrary to query position
    return poolManager.getPosition(poolKey.toId(), positionKey);
}
```

**Validate**:
- Position exists after creation
- Liquidity matches input
- Tick range is correct
- Fees are initially 0

---

## Phase 4: V4 Fee Collection (MEDIUM PRIORITY)

### Objective
Collect accumulated fees from V4 LP positions.

### Prerequisites
- Phase 3 complete (have LP positions)
- Some time passed with swaps happening
- Fees accumulated in position

### Tests to Implement

#### 4.1 Fee Accumulation Test
**Test**: `test_collectFees_afterSwaps_success()`

**Test Flow**:
1. Create LP position
2. Execute multiple swaps through pool
3. Query position to see fee growth
4. Call modifyLiquidity with liquidityDelta = 0 to collect fees
5. Verify fee amounts received

**Implementation**:
```solidity
function collectFees(PoolKey memory key, int24 tickLower, int24 tickUpper)
    external returns (uint256 fees0, uint256 fees1) {

    bytes memory data = abi.encode(key, tickLower, tickUpper);
    BalanceDelta delta = abi.decode(
        poolManager.unlock(data),
        (BalanceDelta)
    );

    // Positive deltas mean we receive tokens (fees)
    fees0 = delta.amount0() > 0 ? uint256(delta.amount0()) : 0;
    fees1 = delta.amount1() > 0 ? uint256(delta.amount1()) : 0;
}

function unlockCallback(bytes calldata data) external returns (bytes memory) {
    (PoolKey memory key, int24 tickLower, int24 tickUpper) =
        abi.decode(data, (PoolKey, int24, int24));

    // Collect fees by passing liquidityDelta = 0
    (BalanceDelta delta, ) = poolManager.modifyLiquidity(
        key,
        IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: 0, // Zero delta = collect fees only
            salt: bytes32(0)
        }),
        ""
    );

    // Take accumulated fees
    if (delta.amount0() > 0) {
        key.currency0.take(poolManager, address(this), uint256(delta.amount0()), false);
    }
    if (delta.amount1() > 0) {
        key.currency1.take(poolManager, address(this), uint256(delta.amount1()), false);
    }

    return abi.encode(delta);
}
```

#### 4.2 Fee Growth Tracking
**Test**: `test_feeAccumulation_proportionalToLiquidity()`

**Validation**:
- Larger positions earn more fees
- Fees proportional to swap volume
- Fee rate matches pool fee tier
- Both tokens accumulate fees

---

## Phase 5: Hook Taxation Analysis (HIGH PRIORITY)

### Objective
Measure actual impact of UltraAlignmentV4Hook on swap pricing.

### Prerequisites
- Phase 2 complete (can execute swaps)
- Have pools both with and without hooks
- Working hook deployment

### Tests to Implement

#### 5.1 Hook Tax Measurement
**Test**: `test_hookTaxesSwaps_success()`

**Comparison Test**:
```solidity
function test_compareHookedVsUnhookedPool() public {
    // Setup: Create two identical pools, one with hook, one without

    // Pool 1: No hook
    PoolKey memory unhookedKey = PoolKey({
        currency0: Currency.wrap(WETH),
        currency1: Currency.wrap(USDC),
        fee: 3000,
        tickSpacing: 60,
        hooks: IHooks(address(0))
    });

    // Pool 2: With UltraAlignmentV4Hook
    PoolKey memory hookedKey = PoolKey({
        currency0: Currency.wrap(WETH),
        currency1: Currency.wrap(USDC),
        fee: 3000,
        tickSpacing: 60,
        hooks: IHooks(ultraAlignmentHook)
    });

    // Execute same swap on both
    uint256 outputUnhooked = executeSwap(unhookedKey, 1 ether);
    uint256 outputHooked = executeSwap(hookedKey, 1 ether);

    // Calculate tax
    uint256 taxAmount = outputUnhooked - outputHooked;
    uint256 taxBps = (taxAmount * 10000) / outputUnhooked;

    emit log_named_uint("Unhooked output", outputUnhooked);
    emit log_named_uint("Hooked output", outputHooked);
    emit log_named_uint("Tax amount", taxAmount);
    emit log_named_uint("Tax rate (bps)", taxBps);

    // Validate matches UltraAlignmentV4Hook.taxRateBips
    assertEq(taxBps, 100, "Hook tax should be 1%");
}
```

**Key Questions**:
1. What is actual tax rate? (Expected: 1% = 100 bps)
2. Is tax taken from input or output?
3. Does tax go to vault correctly?
4. Can we verify vault received the tax?

#### 5.2 Double Taxation Risk
**Test**: `test_vaultPositionNotDoubleTaxed()`

**Critical Scenario**:
```
User swaps through V4 pool with vault's hook
→ Hook taxes 1% to vault
→ Swap happens in pool where vault is LP
→ Does vault pay tax to itself?
```

**Test**:
1. Vault creates LP position in pool with its own hook
2. External user swaps through pool
3. Measure: Does vault receive 100% of LP fees + hook tax?
4. Or: Does hook tax reduce vault's LP fees?

**Expected**: Vault should receive both (no double tax)

---

## Phase 6: UltraAlignmentVault Integration

### Objective
Replace vault stub functions with working V4 implementations.

### Functions to Implement

#### 6.1 `_swapETHForTarget()` in UltraAlignmentVault.sol
**Current**: Returns hardcoded stub value
**Required**: Execute actual V4 swap

**Implementation**:
```solidity
function _swapETHForTarget(uint256 ethAmount, uint256 minOutTarget)
    internal
    returns (uint256 tokenReceived)
{
    // Query V4 pool for alignment token
    PoolKey memory v4Key = PoolKey({
        currency0: Currency.wrap(address(0)), // ETH
        currency1: Currency.wrap(alignmentToken),
        fee: 3000,
        tickSpacing: 60,
        hooks: v4Hook // Use vault's own hooked pool
    });

    // Encode swap params for unlock callback
    bytes memory swapData = abi.encode(
        v4Key,
        true, // zeroForOne (ETH → Token)
        int256(ethAmount), // exact input
        0 // no price limit (use minOutTarget in callback)
    );

    // Execute swap via unlock
    BalanceDelta delta = abi.decode(
        v4PoolManager.unlock(swapData),
        (BalanceDelta)
    );

    tokenReceived = uint256(-delta.amount1());
    require(tokenReceived >= minOutTarget, "Slippage too high");

    return tokenReceived;
}

function unlockCallback(bytes calldata data) external returns (bytes memory) {
    require(msg.sender == address(v4PoolManager), "Only PoolManager");

    (PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) =
        abi.decode(data, (PoolKey, bool, int256, uint160));

    // Execute swap
    BalanceDelta delta = v4PoolManager.swap(
        key,
        IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        }),
        ""
    );

    // Settle ETH input
    key.currency0.settle(v4PoolManager, address(this), uint256(amountSpecified), false);

    // Take token output
    key.currency1.take(v4PoolManager, address(this), uint256(-delta.amount1()), false);

    return abi.encode(delta);
}
```

#### 6.2 `_addToLpPosition()` in UltraAlignmentVault.sol
**Current**: Returns stub liquidity units
**Required**: Create actual V4 position

**Implementation**:
```solidity
function _addToLpPosition(
    uint256 amount0,
    uint256 amount1,
    int24 tickLower,
    int24 tickUpper
) internal returns (uint128 liquidityUnits) {
    // Calculate liquidity from amounts
    (uint160 sqrtPriceX96, , , ) = v4PoolManager.getSlot0(v4PoolId);
    uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
    uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);

    liquidityUnits = LiquidityAmounts.getLiquidityForAmounts(
        sqrtPriceX96,
        sqrtPriceAX96,
        sqrtPriceBX96,
        amount0,
        amount1
    );

    // Encode modifyLiquidity params
    bytes memory liquidityData = abi.encode(
        v4PoolKey,
        tickLower,
        tickUpper,
        liquidityUnits
    );

    // Execute via unlock
    v4PoolManager.unlock(liquidityData);

    return liquidityUnits;
}
```

#### 6.3 Vault Fee Claiming
**New Function**: `_claimV4PositionFees()`

**Implementation**:
```solidity
function _claimV4PositionFees() internal returns (uint256 ethFees, uint256 tokenFees) {
    // Collect fees by modifying position with liquidityDelta = 0
    bytes memory collectData = abi.encode(
        v4PoolKey,
        vaultTickLower,
        vaultTickUpper,
        0 // liquidityDelta = 0 means collect fees only
    );

    BalanceDelta delta = abi.decode(
        v4PoolManager.unlock(collectData),
        (BalanceDelta)
    );

    ethFees = delta.amount0() > 0 ? uint256(delta.amount0()) : 0;
    tokenFees = delta.amount1() > 0 ? uint256(delta.amount1()) : 0;

    // Convert token fees to ETH via V4 swap
    if (tokenFees > 0) {
        ethFees += _swapTargetForETH(tokenFees, 0);
    }

    return (ethFees, 0);
}
```

---

## Phase 7: ERC404BondingInstance Integration

### Objective
Replace deployLiquidity stub with working V4 implementation.

### Function to Implement

#### 7.1 `deployLiquidity()` in ERC404BondingInstance.sol
**Status**: Currently uses unlock callback pattern but NOT tested

**Validation Checklist**:
- [ ] Pool initialization works with sqrtPriceX96
- [ ] Hook is correctly attached to pool
- [ ] Liquidity is added successfully
- [ ] Token approvals are correct
- [ ] Native ETH vs WETH handling works
- [ ] Position is queryable after deployment
- [ ] liquidityPool address is set correctly

**Test**:
```solidity
function test_deployLiquidity_E2E() public {
    // Setup bonding instance
    ERC404BondingInstance instance = createInstance();

    // Buy some tokens
    instance.buyBonding(1000000 ether, 1 ether, true, bytes32(0), "");

    // Deploy liquidity to V4 (ENFORCES FULL-RANGE)
    // Note: tickLower/tickUpper are automatically set to min/max usable ticks
    uint128 liquidity = instance.deployLiquidity(
        3000, // fee
        60,   // tickSpacing (determines full range: -887220 to 887220)
        500000 ether, // amountToken
        5 ether,      // amountETH
        sqrtPriceX96  // initial price
    );

    // Validate
    assertGt(liquidity, 0, "Should have created position");
    assertEq(instance.liquidityPool(), address(v4PoolManager), "Pool set");

    // Verify position exists in V4 (full-range ticks)
    int24 tickLower = TickMath.minUsableTick(60);
    int24 tickUpper = TickMath.maxUsableTick(60);
    bytes32 positionKey = _getPositionKey(
        address(instance),
        tickLower,
        tickUpper,
        bytes32(0)
    );

    Position.Info memory position = poolManager.getPosition(
        v4PoolId,
        positionKey
    );

    assertEq(position.liquidity, liquidity, "Position liquidity matches");
}
```

---

## Phase 8: Comprehensive Integration Tests

### Objective
Full end-to-end workflows using all V4 components.

### Test Scenarios

#### 8.1 Vault Full Lifecycle
**Test**: `test_vaultLifecycle_depositSwapCollectClaim()`

**Flow**:
1. User sends ETH to vault (via receive())
2. Vault accumulates pending ETH
3. Caller triggers convertAndAddLiquidity()
   - Swaps 50% ETH for alignment token (V4)
   - Creates V4 LP position with ETH + token
   - Issues shares to depositors
4. Time passes, swaps happen through pool
5. Vault calls _claimV4PositionFees()
6. Fees are converted to ETH (V4 swap)
7. Benefactors claim their share of fees

**Validation**:
- Each step executes without reverting
- Share accounting is correct
- Fee distribution is proportional
- No tokens are lost

#### 8.2 Bonding → Liquidity → Trading
**Test**: `test_bondingToLiquidityToTrading_E2E()`

**Flow**:
1. Deploy ERC404BondingInstance with V4 hook
2. Users buy tokens via bonding curve
3. Owner deploys liquidity to V4
4. External traders swap through V4 pool
5. Hook taxes swaps, sends to vault
6. Bonding participants claim vault fees

**Validation**:
- Bonding curve works correctly
- Liquidity deployment succeeds
- Swaps execute at correct prices
- Hook tax is collected by vault
- Original buyers earn fees from trading

---

## Implementation Schedule

### Week 1: Foundation
**Days 1-2**: Phase 1 (Pool Discovery)
- Run all pool query tests
- Document discovered pools
- Fix any PoolKey construction issues

**Days 3-4**: Phase 2 Part 1 (Basic Swaps)
- Implement unlock callback pattern
- Execute first successful V4 swap
- Test exact input vs exact output

**Day 5**: Phase 2 Part 2 (Price Comparison)
- Compare V4 to V2/V3 pricing
- Make routing algorithm decision

### Week 2: Core Features
**Days 1-2**: Phase 3 (Position Creation)
- Create LP positions
- Test different tick ranges
- Validate position querying

**Days 3-4**: Phase 4 (Fee Collection)
- Collect fees from positions
- Validate fee calculations
- Test fee growth tracking

**Day 5**: Phase 5 (Hook Taxation)
- Measure hook tax impact
- Test vault as LP with own hook
- Validate no double taxation

### Week 3: Integration
**Days 1-2**: Phase 6 (Vault Integration)
- Replace vault stubs with real V4
- Test _swapETHForTarget()
- Test _addToLpPosition()

**Days 3-4**: Phase 7 (Bonding Integration)
- Test deployLiquidity() E2E
- Validate hook attachment
- Test position creation

**Day 5**: Phase 8 (E2E Tests)
- Full vault lifecycle test
- Full bonding lifecycle test
- Performance benchmarking

### Week 4: Validation & Documentation
**Days 1-2**: Bug fixes and edge cases
**Days 3-4**: Documentation and code review
**Day 5**: Final validation and deployment prep

---

## Success Criteria

### Phase 1 Success
- [ ] Discovered at least 3 V4 pools on mainnet
- [ ] Successfully queried pool state (sqrtPriceX96, tick)
- [ ] Documented pool addresses and parameters

### Phase 2 Success
- [ ] Executed successful V4 swap
- [ ] Measured actual swap output
- [ ] Compared V4 to V2/V3 pricing
- [ ] Made data-driven routing decision

### Phase 3 Success
- [ ] Created LP position in V4
- [ ] Queried position successfully
- [ ] Validated liquidity calculation

### Phase 4 Success
- [ ] Collected fees from position
- [ ] Verified fee amounts
- [ ] Confirmed proportional distribution

### Phase 5 Success
- [ ] Measured hook tax rate empirically
- [ ] Confirmed vault receives hook taxes
- [ ] Validated no double taxation

### Phase 6 Success
- [ ] Vault can swap via V4
- [ ] Vault can create V4 positions
- [ ] Vault can collect V4 fees
- [ ] All share accounting is correct

### Phase 7 Success
- [ ] Bonding instance can deploy to V4
- [ ] Hook is properly attached
- [ ] Liquidity is added correctly
- [ ] Position is queryable

### Phase 8 Success
- [ ] Full vault lifecycle works E2E
- [ ] Full bonding lifecycle works E2E
- [ ] No funds lost in any scenario
- [ ] Gas costs are reasonable

---

## Risk Mitigation

### Technical Risks

#### Risk: V4 pools don't exist on mainnet
**Mitigation**: Test on other networks (Base, Arbitrum) where V4 may have more adoption
**Fallback**: Create own V4 pools in tests using PoolManager.initialize()

#### Risk: Hook taxation breaks swap routing
**Mitigation**: Make hook tax configurable (0% for testing)
**Fallback**: Use hookless pools for swaps, hooked pools only for vault's own token

#### Risk: Unlock callback pattern is too complex
**Mitigation**: Extract callback logic to separate library
**Fallback**: Use V4 router contracts if available

#### Risk: Native ETH handling causes issues
**Mitigation**: Thoroughly test WETH vs native ETH in all scenarios
**Fallback**: Always use WETH if native ETH is problematic

### Integration Risks

#### Risk: Vault share accounting breaks with V4
**Mitigation**: Add comprehensive share accounting tests
**Fallback**: Keep V2/V3 support as primary, V4 as optional

#### Risk: Gas costs too high for V4
**Mitigation**: Benchmark gas costs vs. V2/V3
**Fallback**: Only use V4 for large transactions where gas is amortized

#### Risk: V4 is too new, bugs in protocol
**Mitigation**: Start with small amounts in tests
**Fallback**: Wait for V4 to mature, use V3 in production

---

## Testing Strategy

### Test Pyramid

**Level 1: Unit Tests (Fast)**
- Mock PoolManager responses
- Test unlock callback logic
- Test PoolKey construction
- Test liquidity math

**Level 2: Fork Tests (Medium)**
← **THIS IS WHERE WE ARE**
- Query real V4 pools
- Execute real swaps
- Create real positions
- Collect real fees

**Level 3: Integration Tests (Slow)**
- Full vault workflows
- Full bonding workflows
- Multi-step scenarios

### Test Coverage Goals
- 100% of V4 interaction code tested
- 100% of callback functions tested
- 100% of error cases handled
- 100% of edge cases documented

### Continuous Validation
After each phase:
1. Run all previous phase tests
2. Check for regressions
3. Update documentation
4. Commit results

---

## Documentation Deliverables

### 1. V4_POOL_DISCOVERY.md
- List of all discovered V4 pools
- Pool parameters (fees, ticks, liquidity)
- Comparison to V2/V3 pools
- Recommendations for routing

### 2. V4_SWAP_BENCHMARK.md
- Swap pricing comparison (V2 vs V3 vs V4)
- Gas cost comparison
- Slippage analysis
- Routing algorithm decision

### 3. V4_HOOK_ANALYSIS.md
- Hook tax measurements
- Impact on swap pricing
- Vault fee collection validation
- Double taxation analysis

### 4. V4_INTEGRATION_GUIDE.md
- How to use V4 in vault
- How to use V4 in bonding instance
- Best practices
- Common pitfalls

### 5. V4_TEST_RESULTS.md
- All test results
- Pass/fail status
- Performance metrics
- Known issues

---

## Next Immediate Actions

### Action 1: Run Pool Discovery (NOW)
```bash
forge test --mp test/fork/v4/V4SwapRouting.t.sol::test_queryV4_WETH_USDC_allFees \
    --fork-url $ETH_RPC_URL -vvv
```

**Expected Time**: 5 minutes
**Expected Outcome**: Find at least 1 V4 pool

### Action 2: Document Findings (NOW + 10 min)
Create `V4_POOL_DISCOVERY.md` with results

### Action 3: Implement First Swap Test (NOW + 2 hours)
Based on discovered pool, write working swap test

### Action 4: Compare to V2/V3 (NOW + 4 hours)
Execute same swap on V2, V3, V4 and compare

### Action 5: Make Routing Decision (NOW + 4.5 hours)
Based on comparison, update routing algorithm

---

## Conclusion

This plan transforms our V4 integration from **HYPOTHESIS** to **PROVEN REALITY**.

**Current State**: 36 stub tests, zero empirical data
**Target State**: 36 working tests, complete V4 validation

**Philosophy**: Test everything. Trust nothing. Document everything.

**Timeline**: 3-4 weeks to full integration
**Risk Level**: Medium (V4 is new, but testable)
**Reward**: Complete DeFi routing across V2/V3/V4

**Let's prove it works before we ship it.**
