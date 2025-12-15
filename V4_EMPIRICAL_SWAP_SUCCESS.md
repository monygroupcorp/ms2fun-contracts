# V4 Swap Implementation - EMPIRICAL SUCCESS

**Date**: December 11, 2025
**Status**: ✅ **FIRST WORKING V4 SWAP ON MAINNET FORK**

---

## Critical Discovery: V4 Delta Sign Conventions

### THE KEY MISTAKE (that cost hours of debugging)

**WRONG** (what I initially thought):
- Positive delta = we owe pool (settle)
- Negative delta = pool owes us (take)

**CORRECT** (verified from `v4-core/src/test/PoolSwapTest.sol:102-113`):
- **Negative delta = we owe pool (settle)**
- **Positive delta = pool owes us (take)**

### THE SECOND KEY MISTAKE

**WRONG** (V3 convention):
- Positive amountSpecified = exact input
- Negative amountSpecified = exact output

**CORRECT** (V4 convention from `PoolSwapTest.sol:65-66`):
- **Negative amountSpecified = exact input**
- **Positive amountSpecified = exact output**

---

## Working Implementation

### Correct Settlement Logic

```solidity
function _settleDelta(PoolKey memory key, BalanceDelta delta, address recipient) internal {
    int128 delta0 = delta.amount0();
    int128 delta1 = delta.amount1();

    // Handle currency0
    if (delta0 < 0) {
        // Negative = we owe currency0 to pool (we settle/pay)
        key.currency0.settle(poolManager, address(this), uint128(-delta0), false);
    } else if (delta0 > 0) {
        // Positive = pool owes us currency0 (we take/receive)
        key.currency0.take(poolManager, recipient, uint128(delta0), false);
    }

    // Handle currency1
    if (delta1 < 0) {
        // Negative = we owe currency1 to pool (we settle/pay)
        key.currency1.settle(poolManager, address(this), uint128(-delta1), false);
    } else if (delta1 > 0) {
        // Positive = pool owes us currency1 (we take/receive)
        key.currency1.take(poolManager, recipient, uint128(delta1), false);
    }
}
```

### Correct Swap Call

```solidity
// For 0.001 ETH exact input swap:
uint256 amountIn = 0.001 ether;

uint256 usdcOut = _executeV4Swap(
    key,
    true, // zeroForOne (ETH -> USDC)
    -int256(amountIn), // NEGATIVE for exact input in V4!
    address(this)
);
```

### Correct Output Calculation

```solidity
// Calculate output amount
// Positive delta = pool owes us (we receive)
// For exactInput swaps, the output currency will have positive delta
if (zeroForOne) {
    // Swapping currency0 for currency1, expect positive delta1
    require(delta.amount1() > 0, "Expected to receive currency1");
    amountOut = uint256(uint128(delta.amount1()));
} else {
    // Swapping currency1 for currency0, expect positive delta0
    require(delta.amount0() > 0, "Expected to receive currency0");
    amountOut = uint256(uint128(delta.amount0()));
}
```

---

## Test Results

### First Successful V4 Swap on Mainnet Fork

**Pool**: Native ETH/USDC 0.05% (block 23,724,000)

**Input**: 0.001 ETH
**Output**: 3.506905 USDC
**Effective Price**: **3,506.905 USDC per ETH**

**Pool State**:
- sqrtPriceX96: 4,692,996,958,180,115,555,002,366
- Tick: -194,691

**Balance Changes**:
- ETH before: 10.000000000000000000
- ETH after: 9.999000000000000000
- ETH spent: **0.001 ETH** ✅

- USDC before: 0
- USDC after: 3,506,905 (6 decimals)
- USDC received: **3.506905 USDC** ✅

### All Assertions Passed

```solidity
assertEq(usdcAfter - usdcBefore, usdcOut, "USDC balance mismatch"); ✅
assertEq(ethBefore - ethAfter, amountIn, "ETH not fully spent"); ✅
assertGt(usdcOut, 0, "Should receive USDC"); ✅
assertGt(pricePerEth, 3000e6, "Price too low"); ✅
assertLt(pricePerEth, 4000e6, "Price too high"); ✅
```

---

## Debugging Journey

### Attempt 1: Wrong Delta Signs
- **Issue**: Had settle() and take() reversed
- **Symptom**: Trying to transfer USDC we don't have
- **Fix**: Checked `v4-core/src/test/PoolSwapTest.sol` for correct convention

### Attempt 2: Wrong amountSpecified Sign
- **Issue**: Used positive amountSpecified (V3 convention)
- **Symptom**: Swap hitting price limits, massive amounts
- **Fix**: Changed to negative amountSpecified for exact input

### Attempt 3: Price Limit Issues
- **Issue**: Various sqrtPriceLimitX96 values causing partial execution
- **Solution**: Use MIN_SQRT_PRICE + 1 / MAX_SQRT_PRICE - 1 for full range
- **Note**: With correct signs, even strict limits work fine

---

## Key V4 Concepts Validated

### 1. Unlock-Callback Pattern Works

```solidity
contract V4SwapRoutingTest is IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only PoolManager");

        SwapCallbackData memory params = abi.decode(data, (SwapCallbackData));

        // Execute swap
        BalanceDelta delta = poolManager.swap(params.key, params.params, "");

        // Settle deltas
        _settleDelta(params.key, delta, params.recipient);

        return abi.encode(delta);
    }
}
```

### 2. Native ETH Support Works

- Pool uses `Currency.wrap(address(0))` for ETH
- No need to wrap to WETH
- Settlement automatically handles ETH via `settle{value: amount}()`

### 3. CurrencySettler Utility

```solidity
using CurrencySettler for Currency;

// For native ETH (address(0)):
currency0.settle(poolManager, address(this), amount, false);
// Internally calls: poolManager.settle{value: amount}()

// For ERC20:
currency1.settle(poolManager, address(this), amount, false);
// Internally calls: IERC20(currency).transferFrom(...) then poolManager.settle()
```

---

## Files Modified

### test/fork/v4/V4SwapRouting.t.sol

**Major Changes**:
1. Added IUnlockCallback interface implementation
2. Implemented unlockCallback() with correct delta settlement
3. Implemented _settleDelta() with CORRECT sign conventions
4. Implemented _executeV4Swap() with unlock pattern
5. Rewrote test_swapExactInputSingle_success() with REAL swap logic
6. Used NEGATIVE amountSpecified for exact input swaps

**Lines of Real Code**: ~150 lines of working V4 swap infrastructure

---

## Next Steps

### Immediate
- [ ] Implement test_swapExactOutputSingle_success (positive amountSpecified)
- [ ] Implement test_swapNativeETH_multiHop (ETH -> USDC -> DAI)
- [ ] Implement test_swapWithHookTaxation_reducesOutput

### Medium-term
- [ ] Implement V4 position creation tests (modifyLiquidity)
- [ ] Implement V4 fee collection tests
- [ ] Implement V4 hook taxation integration tests

### Long-term
- [ ] Use this infrastructure in UltraAlignmentVault._executeV4Swap()
- [ ] Implement UltraAlignmentVault V4 position management
- [ ] Deploy and test on real mainnet

---

## Lessons Learned

### 1. Always Check Official Test Implementations

Don't assume conventions carry over from V3 to V4. The official V4 test contracts (`PoolSwapTest.sol`, etc.) are the source of truth.

### 2. Delta Signs Matter

V4's delta sign convention is:
- Negative = debt (you must settle)
- Positive = credit (you can take)

This is the OPPOSITE of what seems intuitive!

### 3. Amount Sign Convention Changed

V3: positive = exact input
V4: **negative = exact input**

This breaking change requires careful attention when porting V3 code.

### 4. Price Limit Behavior

When a swap hits sqrtPriceLimitX96:
- Swap executes partially
- Returns whatever liquidity was consumed
- Doesn't revert (unlike some expectations)

With small swaps and correct signs, this rarely matters.

---

## Success Metrics

**Before This Session**:
- V4 swap tests: 0/8 working (all TODO stubs)
- V4 swap infrastructure: Not implemented
- V4 delta conventions: Misunderstood

**After This Session**:
- V4 swap tests: 1/8 working ✅
- V4 swap infrastructure: Fully implemented ✅
- V4 delta conventions: Correctly documented ✅

**Impact**:
- Proven V4 swaps work on mainnet fork
- Infrastructure ready for remaining tests
- Critical for UltraAlignmentVault implementation

---

## References

1. `lib/v4-core/src/test/PoolSwapTest.sol` - Official swap test pattern
2. `lib/v4-core/test/utils/CurrencySettler.sol` - Settlement utilities
3. `V4_POOLS_DISCOVERED.md` - Available pools for testing
4. `V4_SESSION_SUMMARY.md` - Previous V4 exploration work

---

**END OF REPORT**
