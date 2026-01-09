# Full-Range Liquidity Enforcement Fix

**Date:** 2025-12-19
**File:** `src/factories/erc404/ERC404BondingInstance.sol`
**Function:** `deployLiquidity()`

## Summary

Fixed the `deployLiquidity()` function to **enforce full-range (infinite range) liquidity** when deploying to Uniswap V4. Previously, the function allowed the owner to specify arbitrary tick ranges, which could result in concentrated liquidity positions instead of the intended full-range liquidity.

## The Problem

### Before Fix

The original function signature allowed the caller to specify `tickLower` and `tickUpper` parameters:

```solidity
function deployLiquidity(
    uint24 poolFee,
    int24 tickSpacing,
    int24 tickLower,      // ⚠️ CALLER could provide ANY value
    int24 tickUpper,      // ⚠️ CALLER could provide ANY value
    uint256 amountToken,
    uint256 amountETH,
    uint160 sqrtPriceX96
) external payable onlyOwner nonReentrant returns (uint128 liquidity)
```

**Validation performed:**
```solidity
require(tickLower < tickUpper, "Invalid tick range");
require(tickLower >= TickMath.minUsableTick(tickSpacing), "Tick lower out of bounds");
require(tickUpper <= TickMath.maxUsableTick(tickSpacing), "Tick upper out of bounds");
```

**Issue:** These checks only validated that the ticks were within bounds and in correct order, but **did not enforce full-range liquidity**. An owner could deploy concentrated liquidity like:
- `tickLower = -60000, tickUpper = 60000` (concentrated around current price)
- `tickLower = 0, tickUpper = 100000` (one-sided range)

### Why Full-Range Matters

For the ERC404 bonding curve liquidity deployment:
1. **Liquidity availability at all prices:** Full-range ensures swaps work regardless of price movement
2. **Hook taxation uniformity:** The vault hook taxes all swaps - needs liquidity at all price points
3. **Simplicity:** No need for active liquidity management or rebalancing
4. **Alignment with bonding curve philosophy:** Bonding curve provides liquidity at all prices, V4 pool should too

## The Solution

### After Fix

Removed `tickLower` and `tickUpper` parameters and **automatically calculate** them from `tickSpacing`:

```solidity
function deployLiquidity(
    uint24 poolFee,
    int24 tickSpacing,
    uint256 amountToken,
    uint256 amountETH,
    uint160 sqrtPriceX96
) external payable onlyOwner nonReentrant returns (uint128 liquidity) {
    // ...validations...

    // ENFORCE FULL-RANGE LIQUIDITY: Always use min/max usable ticks
    int24 tickLower = TickMath.minUsableTick(tickSpacing);
    int24 tickUpper = TickMath.maxUsableTick(tickSpacing);

    // ...rest of deployment...
}
```

**Result:**
- ✅ Full-range is **enforced** by the contract, not optional
- ✅ No way to deploy concentrated liquidity
- ✅ Cleaner function signature (fewer parameters)
- ✅ Self-documenting: function name says "deploy liquidity", implementation guarantees full-range

## Examples of Full-Range Ticks by Tick Spacing

| Fee Tier | Tick Spacing | tickLower | tickUpper | Price Range |
|----------|--------------|-----------|-----------|-------------|
| 0.05% | 10 | -887,270 | 887,270 | ~1e-38 to ~1e38 |
| 0.30% | 60 | -887,220 | 887,220 | ~1e-38 to ~1e38 |
| 1.00% | 200 | -887,200 | 887,200 | ~1e-38 to ~1e38 |

All of these provide liquidity at effectively **all possible prices** (limited only by Solidity's int24 tick range).

## Code Changes

### Function Signature Change

```diff
 function deployLiquidity(
     uint24 poolFee,
     int24 tickSpacing,
-    int24 tickLower,
-    int24 tickUpper,
     uint256 amountToken,
     uint256 amountETH,
     uint160 sqrtPriceX96
 ) external payable onlyOwner nonReentrant returns (uint128 liquidity)
```

### Automatic Tick Calculation

```solidity
// ENFORCE FULL-RANGE LIQUIDITY: Always use min/max usable ticks
int24 tickLower = TickMath.minUsableTick(tickSpacing);
int24 tickUpper = TickMath.maxUsableTick(tickSpacing);
```

### Stack Too Deep Fix

As a bonus, removing the parameters and using scoped blocks helped resolve a "stack too deep" compilation error:

```solidity
// Store original amounts before any swapping
uint256 originalTokenAmount = amountToken;
uint256 originalETHAmount = amountETH;

// Create pool key and determine currency ordering
PoolKey memory poolKey;
bool token0IsThis;
{
    // Scoped block to reduce stack depth
    Currency currency0 = Currency.wrap(address(this));
    Currency currency1 = Currency.wrap(weth);
    token0IsThis = currency0 < currency1;

    // ...
}
```

## Impact Analysis

### Breaking Changes

✅ **Function signature changed** - any external callers need to update:

**Old call:**
```solidity
instance.deployLiquidity(
    3000,
    60,
    -887220,  // removed
    887220,   // removed
    500000 ether,
    5 ether,
    sqrtPriceX96
);
```

**New call:**
```solidity
instance.deployLiquidity(
    3000,
    60,
    500000 ether,
    5 ether,
    sqrtPriceX96
);
```

### Security Improvements

✅ **Cannot deploy concentrated liquidity** - enforced at contract level
✅ **Simpler attack surface** - fewer parameters to validate
✅ **Deterministic behavior** - given tickSpacing, range is always the same

### Gas Impact

✅ **Slightly lower gas** - fewer function parameters (saves calldata)
✅ **Same execution cost** - tick calculation is very cheap

## Testing

### Existing Tests

All 7 existing tests in `test/factories/erc404/ERC404BondingInstance.t.sol` still pass:
- ✅ test_Deployment
- ✅ test_SetBondingOpenTime
- ✅ test_SetBondingOpenTime_RevertIfNotOwner
- ✅ test_SetBondingActive
- ✅ test_CalculateCost
- ✅ test_CalculateRefund
- ✅ test_TierPasswordVerification

### Recommended Additional Tests

**TODO:** Add integration test for `deployLiquidity()` that verifies:
1. Pool is initialized with correct full-range ticks
2. Position is queryable in V4 PoolManager
3. Position has liquidity at min and max ticks
4. Hook is correctly attached to pool

## Documentation Updates

Updated files:
- ✅ `src/factories/erc404/ERC404BondingInstance.sol` - Function documentation clarifies full-range enforcement
- ✅ `V4_IMPLEMENTATION_PLAN.md` - Example code updated with new signature

## Related Issues

This fix addresses the concern raised during code review about ensuring infinite range liquidity for vault hook taxation uniformity.

## Conclusion

The `deployLiquidity()` function now **guarantees full-range liquidity** by automatically calculating min/max usable ticks from the tick spacing. This ensures:

1. ✅ Liquidity is available at all price points
2. ✅ Hook taxation works uniformly across entire price spectrum
3. ✅ No manual tick range specification required
4. ✅ Cleaner, safer API with fewer parameters
5. ✅ Self-documenting code that enforces architectural requirements

The bonding curve instances will now **always** deploy with full-range liquidity to Uniswap V4, as intended.
