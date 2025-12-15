# V4 Testing Architecture - Technical Challenges & Solutions

**Date**: December 11, 2025
**Status**: Phase 1 Complete (Query Tests) - Phase 2 Planning (Swap/Position Tests)

---

## Executive Summary

We've successfully implemented **7 V4 liquidity query tests** that interact with real mainnet V4 pools. However, implementing swap and position management tests requires fundamentally different architecture due to V4's unique unlock-callback pattern.

**Key Finding**: V4 is NOT like V2/V3. We can't just call `swap()` or `addLiquidity()`. Everything goes through the `unlock()` callback pattern.

---

## Phase 1: Query Tests ✅ COMPLETE

### What We Implemented
- 7 real tests in `V4PoolInitialization.t.sol`
- All using `StateLibrary` for read-only pool queries
- Queries work directly via `extsload` (no unlock needed)

### StateLibrary Functions Used
```solidity
poolManager.getSlot0(poolId)         // Price, tick, fees
poolManager.getLiquidity(poolId)     // Total pool liquidity
poolManager.getFeeGrowthGlobals(poolId)  // Trading activity
```

### Why This Was Easy
- **Read-only operations** - no state changes
- **Direct calls** - no unlock callback needed
- **No token transfers** - just reading storage slots
- **No delta management** - nothing to settle

---

## Phase 2: Swap & Position Tests ❌ NOT STARTED

### The V4 Unlock-Callback Pattern

**Every state-changing operation in V4 requires:**

```solidity
// 1. User calls unlock with callback data
poolManager.unlock(abi.encode(swapParams));

// 2. PoolManager calls back to user
function unlockCallback(bytes calldata data) external returns (bytes memory) {
    // 3. Decode params
    SwapParams memory params = abi.decode(data, (SwapParams));

    // 4. Execute swap - modifies Currency deltas
    BalanceDelta delta = poolManager.swap(poolKey, params, "");

    // 5. Settle deltas (CRITICAL - must balance to zero)
    if (delta.amount0() < 0) {
        // We owe tokens to PoolManager
        poolManager.settle(currency0);
    } else {
        // PoolManager owes us tokens
        poolManager.take(currency0, address(this), uint256(delta.amount0()));
    }

    // Same for amount1...

    // 6. Return (deltas must be zero or reverts)
    return "";
}
```

### Critical Requirements

1. **IUnlockCallback Interface**
   - Test contract MUST implement `unlockCallback(bytes calldata)`
   - Called during `poolManager.unlock()` execution
   - Must return `bytes memory`

2. **Currency Delta Management**
   - V4 tracks deltas in **transient storage** (EIP-1153)
   - Deltas MUST sum to zero before unlock returns
   - Use `settle()` to pay tokens owed
   - Use `take()` to claim tokens owed to you

3. **Token Approvals**
   - Must approve PoolManager to spend tokens
   - For Native ETH, use `Currency.wrap(address(0))`
   - Must handle both ERC20 and Native ETH

4. **Callback Data Encoding**
   - Encode operation params into `bytes`
   - Decode inside unlockCallback
   - Pattern: `abi.encode(operationType, params)`

---

## Architecture Comparison

### V2/V3 (Simple)
```solidity
// Direct call - no callbacks
IUniswapV3Router.exactInputSingle(
    ExactInputSingleParams({
        tokenIn: WETH,
        tokenOut: USDC,
        fee: 3000,
        recipient: address(this),
        deadline: block.timestamp,
        amountIn: 1 ether,
        amountOutMinimum: 0,
        sqrtPriceLimitX96: 0
    })
);
```

### V4 (Complex)
```solidity
// Step 1: Encode params
bytes memory callbackData = abi.encode(
    CallbackType.SWAP,
    PoolKey({...}),
    IPoolManager.SwapParams({...})
);

// Step 2: Call unlock (triggers callback)
poolManager.unlock(callbackData);

// Step 3: PoolManager calls our unlockCallback()
function unlockCallback(bytes calldata data) external returns (bytes memory) {
    // Step 4: Decode and execute
    (CallbackType callbackType, PoolKey memory key, IPoolManager.SwapParams memory params)
        = abi.decode(data, (CallbackType, PoolKey, IPoolManager.SwapParams));

    // Step 5: Execute swap
    BalanceDelta delta = poolManager.swap(key, params, "");

    // Step 6: Settle deltas
    _settleDelta(key.currency0, delta.amount0());
    _settleDelta(key.currency1, delta.amount1());

    return abi.encode(delta);
}
```

---

## Required Infrastructure

### 1. Test Helper Contract: `V4UnlockHelper`

We need a reusable helper contract that:

```solidity
// test/fork/helpers/V4UnlockHelper.sol
contract V4UnlockHelper is IUnlockCallback {
    IPoolManager public immutable poolManager;

    enum CallbackType { SWAP, ADD_LIQUIDITY, REMOVE_LIQUIDITY }

    struct SwapCallbackData {
        PoolKey key;
        IPoolManager.SwapParams params;
        address recipient;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        // Decode callback type
        CallbackType callbackType = abi.decode(data, (CallbackType));

        if (callbackType == CallbackType.SWAP) {
            return _handleSwapCallback(data);
        } else if (callbackType == CallbackType.ADD_LIQUIDITY) {
            return _handleAddLiquidityCallback(data);
        } else {
            return _handleRemoveLiquidityCallback(data);
        }
    }

    function _handleSwapCallback(bytes calldata data) internal returns (bytes memory) {
        (, SwapCallbackData memory swapData) = abi.decode(data, (CallbackType, SwapCallbackData));

        // Execute swap
        BalanceDelta delta = poolManager.swap(swapData.key, swapData.params, "");

        // Settle deltas
        _settleDelta(swapData.key.currency0, delta.amount0());
        _settleDelta(swapData.key.currency1, delta.amount1());

        return abi.encode(delta);
    }

    function _settleDelta(Currency currency, int128 amount) internal {
        if (amount < 0) {
            // We owe tokens - settle (transfer to PoolManager)
            if (Currency.unwrap(currency) == address(0)) {
                // Native ETH
                poolManager.settle{value: uint128(-amount)}(currency);
            } else {
                // ERC20
                IERC20(Currency.unwrap(currency)).transfer(
                    address(poolManager),
                    uint128(-amount)
                );
                poolManager.settle(currency);
            }
        } else if (amount > 0) {
            // PoolManager owes us - take (claim tokens)
            poolManager.take(currency, address(this), uint128(amount));
        }
    }

    // Helper: Execute swap through unlock
    function executeSwap(
        PoolKey memory key,
        IPoolManager.SwapParams memory params
    ) external returns (BalanceDelta) {
        bytes memory data = abi.encode(
            CallbackType.SWAP,
            SwapCallbackData({
                key: key,
                params: params,
                recipient: msg.sender
            })
        );

        bytes memory result = poolManager.unlock(data);
        return abi.decode(result, (BalanceDelta));
    }
}
```

### 2. Test Contract Structure

```solidity
contract V4SwapRoutingTest is ForkTestBase, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    IPoolManager poolManager;
    V4UnlockHelper helper;

    function setUp() public {
        loadAddresses();
        poolManager = IPoolManager(UNISWAP_V4_POOL_MANAGER);
        helper = new V4UnlockHelper(poolManager);
    }

    function test_swapExactInputSingle_success() public {
        // 1. Setup
        uint256 amountIn = 1 ether;
        deal(WETH, address(helper), amountIn);

        // 2. Approve PoolManager
        vm.prank(address(helper));
        IERC20(WETH).approve(address(poolManager), amountIn);

        // 3. Build swap params
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,  // WETH -> USDC
            amountSpecified: -int256(amountIn),  // Negative = exact input
            sqrtPriceLimitX96: 0  // No limit
        });

        // 4. Execute swap through helper
        BalanceDelta delta = helper.executeSwap(key, params);

        // 5. Verify results
        assertLt(delta.amount1(), 0, "Should spend WETH");
        assertGt(delta.amount0(), 0, "Should receive USDC");

        emit log_named_int("WETH spent", delta.amount1());
        emit log_named_int("USDC received", delta.amount0());
    }
}
```

### 3. Position Management Helper

```solidity
function executeAddLiquidity(
    PoolKey memory key,
    int24 tickLower,
    int24 tickUpper,
    uint128 liquidityDelta
) external returns (BalanceDelta) {
    bytes memory data = abi.encode(
        CallbackType.ADD_LIQUIDITY,
        AddLiquidityData({
            key: key,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidityDelta
        })
    );

    bytes memory result = poolManager.unlock(data);
    return abi.decode(result, (BalanceDelta));
}
```

---

## Key Differences from V2/V3

| Feature | V2/V3 | V4 |
|---------|-------|-----|
| **Swap Execution** | Direct router call | unlock → callback → swap → settle |
| **Position Creation** | Direct position manager call | unlock → callback → modifyLiquidity → settle |
| **State Management** | Persistent storage | Transient storage (deltas) |
| **Token Handling** | Router transfers tokens | Manual settle/take in callback |
| **Native ETH** | Must wrap to WETH | Direct support (address(0)) |
| **Callback Pattern** | None | IUnlockCallback required |

---

## Testing Strategy

### Phase 2A: Basic Swap Tests
1. ✅ Query tests (DONE)
2. ❌ Implement `V4UnlockHelper` contract
3. ❌ Test swap WETH → USDC (exact input)
4. ❌ Test swap USDC → WETH (exact output)
5. ❌ Test Native ETH swap (address(0))

### Phase 2B: Position Tests
1. ❌ Add liquidity to existing pool
2. ❌ Query position info
3. ❌ Remove liquidity
4. ❌ Collect fees

### Phase 2C: Hook Integration Tests
1. ❌ Swap through pool with hook
2. ❌ Verify hook taxation
3. ❌ Test UltraAlignmentV4Hook integration

---

## Critical V4 Concepts

### 1. Currency Type
```solidity
type Currency is address;

// Native ETH
Currency eth = Currency.wrap(address(0));

// ERC20
Currency usdc = Currency.wrap(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
```

### 2. BalanceDelta
```solidity
type BalanceDelta is int256;

// Packed as: int128 amount0, int128 amount1
// Negative = you owe PoolManager
// Positive = PoolManager owes you
```

### 3. Transient Storage (EIP-1153)
- Deltas stored in transient storage (cleared after transaction)
- More gas efficient than persistent storage
- **Requires Cancun hardfork** (why we needed `evm_version = "cancun"`)

### 4. SwapParams
```solidity
struct SwapParams {
    bool zeroForOne;           // true = currency0 -> currency1
    int256 amountSpecified;    // negative = exact input, positive = exact output
    uint160 sqrtPriceLimitX96; // price limit (0 = no limit)
}
```

### 5. ModifyLiquidityParams
```solidity
struct ModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;  // positive = add, negative = remove
    bytes32 salt;           // position identifier
}
```

---

## Risks & Challenges

### 1. Complexity
- **10x more complex** than V2/V3 testing
- Callback pattern requires careful state management
- Easy to get delta accounting wrong

### 2. Gas Costs
- Unlock pattern adds overhead
- Transient storage is cheaper but still costs gas
- Multiple currency settlements in one tx

### 3. Native ETH Handling
- Must handle both ERC20 and Native ETH (address(0))
- Native ETH uses `msg.value` and `.settle{value: amount}()`
- Can't approve Native ETH - different flow

### 4. Error Handling
- Deltas must sum to zero or entire tx reverts
- No partial success - all or nothing
- Hard to debug delta mismatches

### 5. Hook Interactions
- Hooks can modify swap behavior
- Must account for hook taxation
- Hook return deltas must be handled

---

## Resources Needed

### Code Infrastructure
1. **V4UnlockHelper.sol** - Reusable callback handler (~200 lines)
2. **SwapParams builders** - Helper functions for common swaps
3. **Position management** - Add/remove liquidity helpers
4. **Delta settlement** - Robust settle/take implementation

### Documentation
1. **V4 callback patterns** - Code examples
2. **Delta accounting guide** - How to avoid reverts
3. **Native ETH flows** - Handling address(0)

### Testing
1. **Unit tests** for helper contracts
2. **Integration tests** for swap flows
3. **Fork tests** with real mainnet pools

---

## Estimated Effort

| Task | Complexity | Lines of Code | Time Estimate |
|------|-----------|---------------|---------------|
| V4UnlockHelper | High | ~250 | 4-6 hours |
| Basic swap tests | Medium | ~150 | 2-3 hours |
| Position tests | High | ~200 | 4-5 hours |
| Hook integration | Very High | ~300 | 6-8 hours |
| **Total** | **Very High** | **~900** | **16-22 hours** |

Compare to query tests: **~100 lines, 1-2 hours**

---

## Next Steps

### Option 1: Full Implementation
Build complete V4 testing infrastructure:
1. Implement V4UnlockHelper
2. Add swap tests (6 tests)
3. Add position tests (10 tests)
4. Add hook taxation tests (6 tests)

**Pros**: Complete V4 test coverage
**Cons**: 16-22 hours of work, high complexity

### Option 2: Minimal Viable Tests
Focus on critical paths only:
1. One basic swap test (WETH → USDC)
2. One position creation test
3. Document the architecture for future work

**Pros**: Faster (4-6 hours), proves concept
**Cons**: Incomplete coverage

### Option 3: Document & Defer
Document what's needed, implement when building UltraAlignmentVault:
1. Update V4_POOLS_DISCOVERED.md with liquidity findings
2. Create this architecture doc
3. Implement V4 helpers when actually needed for vault

**Pros**: Most pragmatic, no wasted effort
**Cons**: Tests remain stubs for now

---

## Recommendation

**Option 3: Document & Defer**

**Reasoning:**
1. We've proven V4 pools exist and are queryable ✅
2. We understand the architecture needed for swaps/positions ✅
3. Building full infrastructure now is premature - we don't know exact vault requirements yet
4. Better to implement V4 helpers when building UltraAlignmentVault with real use cases

**Immediate Action:**
1. ✅ Update V4_POOLS_DISCOVERED.md with liquidity data
2. ✅ Create V4_TESTING_ARCHITECTURE.md (this doc)
3. Update todos to reflect deferred work
4. Move to other priorities (governance tests, vault implementation, etc.)

When we implement UltraAlignmentVault's `_executeV4Swap()` and `_createV4Position()`, we'll:
- Build V4UnlockHelper with real requirements
- Test against our actual hook implementation
- Have concrete use cases for position management

This avoids building infrastructure we might not need or use incorrectly.

---

## Appendix: V4 Core Interfaces

### IUnlockCallback
```solidity
interface IUnlockCallback {
    /// @notice Called by PoolManager during unlock
    /// @param data Encoded callback data
    /// @return Arbitrary bytes returned to unlock caller
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}
```

### IPoolManager (Key Functions)
```solidity
interface IPoolManager {
    /// @notice Unlock the pool manager
    function unlock(bytes calldata data) external returns (bytes memory);

    /// @notice Execute a swap
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external returns (BalanceDelta);

    /// @notice Modify liquidity
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external returns (BalanceDelta, BalanceDelta);

    /// @notice Settle currency owed to pool manager
    function settle(Currency currency) external payable returns (uint256);

    /// @notice Take currency from pool manager
    function take(Currency currency, address to, uint256 amount) external;
}
```

### StateLibrary (Read-Only)
```solidity
library StateLibrary {
    function getSlot0(IPoolManager manager, PoolId poolId)
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);

    function getLiquidity(IPoolManager manager, PoolId poolId)
        returns (uint128 liquidity);

    function getPositionInfo(IPoolManager manager, PoolId poolId, bytes32 positionId)
        returns (uint128 liquidity, uint256 feeGrowthInside0, uint256 feeGrowthInside1);
}
```

---

**End of Document**
