# Task: Fix Fork Test Arithmetic Underflow in Price Validation

## Priority: CRITICAL
**Security Impact**: HIGH - Price validation is core security mechanism for vault operations

## Problem Statement

Fork tests for `UltraAlignmentVault` are failing with arithmetic underflow (panic 0x11) when running against real mainnet data. The failure occurs in the price validation logic that cross-checks DEX prices to prevent manipulation attacks.

**Failing Test**: `test_convertAndAddLiquidity_singleContributor` in `test/fork/VaultUniswapIntegration.t.sol`

**Error**:
```
[FAIL: panic: arithmetic underflow or overflow (0x11)] test_convertAndAddLiquidity_singleContributor() (gas: 191895)
```

## Context

The vault's `convertAndAddLiquidity()` function queries V2/V3/V4 DEX pools to:
1. Get current price of alignment token (USDC in fork tests)
2. Cross-check prices across DEXes to detect manipulation
3. Validate sufficient liquidity for pending swaps

**Mainnet Pool Data** (WETH/USDC):
- V2 Pair: `0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc`
  - reserve0 (USDC): 11,497,897,212,426 (6 decimals)
  - reserve1 (WETH): 3,561,543,994,267,740,069,836 (18 decimals)
  - token0: USDC (address < WETH)

- V3 Pool (0.3% fee): `0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8`
  - sqrtPriceX96: 1,394,388,683,296,308,605,006,416,202,478,297
  - liquidity: 3,245,100,164,776,190,177

## Root Cause Identified

**Primary Issue**: V2 price calculation did not account for token decimal differences:
- USDC has 6 decimals
- WETH has 18 decimals
- Price calculations assumed both had 18 decimals, causing ~1e12 magnitude errors

## Fixes Already Applied

### 1. Decimal Caching in Constructor
**File**: `src/vaults/UltraAlignmentVault.sol:239-245`

```solidity
// Query and cache alignment token decimals for price calculations
// Default to 18 decimals (standard) if query fails
try IERC20Metadata(_alignmentToken).decimals() returns (uint8 decimals) {
    alignmentTokenDecimals = decimals;
} catch {
    alignmentTokenDecimals = 18; // Standard default
}
```

### 2. V2 Price Calculation with Decimal Adjustment
**File**: `src/vaults/UltraAlignmentVault.sol:1297-1309`

```solidity
// Use cached alignment token decimals for price normalization
// WETH always has 18 decimals, but alignment token may differ (e.g., USDC has 6)
// Calculate decimal adjustment factor (10^decimals)
uint256 decimalAdjustment = 10 ** alignmentTokenDecimals;

if (wethIsToken0) {
    reserveWETH = reserve0;
    reserveToken = reserve1;
    // Price = (WETH reserve * 10^tokenDecimals) / Token reserve
    // This normalizes both tokens to 18 decimals for accurate price
    priceV2 = (uint256(reserve0) * decimalAdjustment) / uint256(reserve1);
} else {
    reserveWETH = reserve1;
    reserveToken = reserve0;
    // Price = (WETH reserve * 10^tokenDecimals) / Token reserve
    priceV2 = (uint256(reserve1) * decimalAdjustment) / uint256(reserve0);
}
```

### 3. Uint112 Overflow Protection
**File**: `src/vaults/UltraAlignmentVault.sol:1661-1665`

```solidity
// Calculate expected slippage
uint256 amountInWithFee = totalPendingETH * 997;
uint256 denominator = (uint256(reserveWETH) * 1000) + amountInWithFee;
require(denominator > 0, "Invalid denominator in slippage calculation");
uint256 expectedOut = (amountInWithFee * uint256(reserveToken)) / denominator;
```

## Remaining Issue

**Location**: Inside `_checkTargetAssetPriceAndPurchasePower()` at `src/vaults/UltraAlignmentVault.sol:1612-1670`

**Symptoms**:
- Test fails at gas consumption: 191,895
- When `_checkTargetAssetPriceAndPurchasePower()` is disabled, test progresses to gas: 199,866
- Underflow occurs AFTER successfully querying V2 and V3 pools
- Underflow occurs even with price deviation checks disabled

**Test Evidence**:
```solidity
// Successful queries observed in trace:
├─ [2564] V2Factory::getPair() → returns pair address
├─ [2504] V2Pair::getReserves() → returns reserves
├─ [2381] V2Pair::token0() → returns USDC address
├─ [2666] V3Factory::getPool() → returns pool address
├─ [2696] V3Pool::slot0() → returns sqrtPriceX96
├─ [2428] V3Pool::liquidity() → returns liquidity
└─ [Revert] panic: arithmetic underflow or overflow (0x11)
```

## Debugging Steps Completed

1. ✅ Confirmed V2 decimal caching works (returns 6 for USDC)
2. ✅ Added explicit uint256 casts to prevent uint112 overflow
3. ✅ Added division-by-zero guard for denominator
4. ✅ Tested with price deviation checks disabled
5. ✅ Tested with entire price check function disabled (test progresses further)
6. ✅ Tested with both RPC endpoints (eth.llamarpc.com, ethereum.publicnode.com)

## Suspected Issues

### Theory 1: Price Deviation Calculation Overflow
When comparing V2 and V3 prices with different magnitude due to decimals:
- V2 price with decimal adjustment: ~3.08e14
- V3 price without adjustment: ~3.08e26 (1e12 too large)

The `_checkPriceDeviation()` calculation at line 1593:
```solidity
uint256 diff = price1 > price2 ? price1 - price2 : price2 - price1;
```

Could underflow if prices are inverted or have extreme magnitude differences.

### Theory 2: V3/V4 Price Calculations Need Decimal Adjustment
V3 and V4 use sqrtPriceX96 encoding which represents price as:
```
price = (sqrtPriceX96)^2 / 2^192
```

The current code converts this to WETH/token price but may not account for token decimals correctly.

**Current V3 calculation** (lines 1376-1391):
```solidity
uint256 rawPrice = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18) >> 192;

if (token0 == weth) {
    price = (1e18 * 1e18) / rawPrice;  // Invert
} else {
    price = rawPrice;
}
```

This may need decimal adjustment similar to V2.

### Theory 3: Expected Output Calculation Edge Case
Lines 1661-1668 calculate expected swap output using constant product formula:
```solidity
uint256 amountInWithFee = totalPendingETH * 997;
uint256 denominator = (uint256(reserveWETH) * 1000) + amountInWithFee;
uint256 expectedOut = (amountInWithFee * uint256(reserveToken)) / denominator;
require(expectedOut > 0, "Insufficient purchase power");
```

With USDC's 6 decimals and large reserve values, this calculation may have edge cases.

## Required Fix

The dedicated agent must:

1. **Identify exact underflow location** using detailed traces
2. **Apply decimal normalization** to V3/V4 price calculations if needed
3. **Fix price deviation logic** to handle magnitude differences safely
4. **Validate with real mainnet data** using multiple token pairs
5. **Ensure all 23+ fork tests pass**

## Success Criteria

### Primary Goal
- [ ] `test_convertAndAddLiquidity_singleContributor` passes on mainnet fork

### Full Success
- [ ] All 23 fork tests in `VaultUniswapIntegration.t.sol` pass
- [ ] All 6 fork tests in `VaultMultiDeposit.t.sol` pass
- [ ] Price validation correctly handles:
  - [ ] 6-decimal tokens (USDC, USDT)
  - [ ] 18-decimal tokens (WETH, DAI)
  - [ ] Large reserve amounts (billions)
  - [ ] V2/V3/V4 price cross-validation

## Testing Commands

### Run Emblematic Test
```bash
forge test \
  --match-test test_convertAndAddLiquidity_singleContributor \
  --match-path "test/fork/VaultUniswapIntegration.t.sol" \
  --fork-url https://ethereum.publicnode.com \
  -vv
```

### Full Fork Test Suite
```bash
forge test \
  --match-path "test/fork/**/*.sol" \
  --fork-url https://ethereum.publicnode.com
```

### Detailed Trace
```bash
forge test \
  --match-test test_convertAndAddLiquidity_singleContributor \
  --match-path "test/fork/VaultUniswapIntegration.t.sol" \
  --fork-url https://ethereum.publicnode.com \
  -vvvvv 2>&1 | grep -B 60 "panic: arithmetic"
```

## Key Files

### Contract Under Test
- `src/vaults/UltraAlignmentVault.sol` - Main vault contract
  - Line 324: `convertAndAddLiquidity()` entry point
  - Line 339: Call to `_checkTargetAssetPriceAndPurchasePower()`
  - Line 1253: `_getV2PriceAndReserves()` - ✅ Fixed with decimal adjustment
  - Line 1324: `_queryV3PoolForFee()` - ❓ May need decimal adjustment
  - Line 1490: `_queryV4PoolForTokenPair()` - ❓ May need decimal adjustment
  - Line 1583: `_checkPriceDeviation()` - ❓ Possible underflow location
  - Line 1612: `_checkTargetAssetPriceAndPurchasePower()` - 🔴 Underflow here

### Test File
- `test/fork/VaultUniswapIntegration.t.sol` - Fork integration tests
  - Line 32: Sets `alignmentToken = USDC` (6 decimals)
  - Line 289: `test_convertAndAddLiquidity_singleContributor()`

### Supporting Files
- `test/fork/helpers/ForkTestBase.sol` - Mainnet addresses and setup

## Additional Context

### Why This Matters
1. **Security Critical**: Price validation prevents:
   - Flash loan attacks
   - DEX manipulation
   - Sandwich attacks
   - Oracle manipulation

2. **Production Blocker**: Cannot deploy vault without validated fork tests

3. **Real Money at Risk**: Vault will hold user funds - price validation must be bulletproof

### Previous Work
- Session identified root cause through systematic debugging
- Applied V2 decimal fix (confirmed working in constructor)
- Isolated underflow to price validation function
- Documented exact gas consumption patterns

## Recommended Approach

1. **Add detailed logging** to price calculation functions
   ```solidity
   emit DebugPrice("V2", priceV2);
   emit DebugPrice("V3", priceV3);
   ```

2. **Test price calculations in isolation** with hardcoded mainnet values

3. **Apply V3/V4 decimal adjustments** similar to V2 fix

4. **Verify price deviation math** handles extreme ratios safely

5. **Run full fork suite** once fix is confirmed

## Notes

- RPC rate limits may occur - use `ethereum.publicnode.com` if `eth.llamarpc.com` fails
- Test uses 5 ETH contribution: `vm.deal(alice, 5 ether)`
- Max price deviation threshold: 500 bps (5%)
- V2 Router: `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D`
- V3 Router: `0xE592427A0AEce92De3Edee1F18E0157C05861564`

---

**Agent Task**: Fix the arithmetic underflow in fork test price validation while maintaining security guarantees. All 29 fork tests must pass with real mainnet data.
