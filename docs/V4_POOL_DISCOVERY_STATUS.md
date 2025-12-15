# V4 Pool Discovery Status

**Date**: December 11, 2025
**Status**: Ready to execute - RPC temporarily unavailable

---

## V4 Deployment Addresses (Ethereum Mainnet)

Based on ForkTestBase.sol configuration:

```solidity
UNISWAP_V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90
UNISWAP_V4_POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e
UNISWAP_V4_QUOTER = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203
UNISWAP_V4_STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227
UNISWAP_V4_UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af
UNISWAP_V4_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3
```

---

## Test Status

### ✅ Completed
- Pool Manager deployment address configured
- Test infrastructure created (V4SwapRouting.t.sol)
- Helper functions for PoolKey construction written

### 🔄 Pending Execution (RPC required)
- Query V4 pools for ETH/USDC (fees: 100, 500, 3000, 10000)
- Query V4 pools for ETH/USDT
- Query V4 pools for ETH/DAI
- Test native ETH (address(0)) vs WETH pools
- Extract pool state (sqrtPriceX96, tick, liquidity)

---

## Pool Discovery Query Strategy

### Method 1: Direct extsload (Current Approach)
```solidity
function _queryPoolState(PoolId poolId) internal returns (bool exists) {
    // Query slot0 using extsload
    (bool success, bytes memory data) = address(poolManager).staticcall(
        abi.encodeWithSignature("extsload(bytes32)", _getPoolStateSlot(poolId))
    );

    if (success && data.length >= 32) {
        bytes32 slot0Data = abi.decode(data, (bytes32));
        uint160 sqrtPriceX96 = uint160(uint256(slot0Data));

        if (sqrtPriceX96 > 0) {
            // Pool exists!
            int24 tick = int24(int256(uint256(slot0Data) >> 160));
            uint24 protocolFee = uint24(uint256(slot0Data) >> 184);
            uint24 lpFee = uint24(uint256(slot0Data) >> 208);
            return true;
        }
    }
    return false;
}

function _getPoolStateSlot(PoolId poolId) internal pure returns (bytes32) {
    return keccak256(abi.encode(poolId, uint256(0)));
}
```

**Advantages**:
- Direct storage access
- No gas limit issues
- Works even if pool has no public view functions

**Disadvantages**:
- Requires correct slot calculation
- Returns raw packed data that needs unpacking

### Method 2: StateLibrary (Alternative)
```solidity
using StateLibrary for IPoolManager;

function _queryPoolState(PoolId poolId) internal view returns (bool exists) {
    (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) =
        poolManager.getSlot0(poolId);

    return sqrtPriceX96 > 0;
}
```

**Advantages**:
- Clean interface
- Automatic unpacking
- Type-safe

**Disadvantages**:
- May revert on non-existent pools (need try/catch)
- Depends on StateLibrary being correct

---

## Expected Pool Pairs to Test

### High Priority (Most Likely to Exist)
1. **WETH/USDC** - Largest ETH pair on all DEXs
   - Fee 500 (0.05%) - Most liquid V3 tier
   - Fee 3000 (0.3%) - Standard tier
   - Fee 10000 (1%) - High volatility tier

2. **WETH/USDT** - Second largest ETH pair
   - Fee 500
   - Fee 3000

3. **WETH/DAI** - Third largest ETH pair
   - Fee 500
   - Fee 3000

### Medium Priority (May Exist)
4. **USDC/USDT** - Stablecoin pair
   - Fee 100 (0.01%) - Tight spread for stables
   - Fee 500

5. **Native ETH/USDC** - V4 supports native ETH
   - Currency.wrap(address(0)) instead of WETH
   - All fee tiers

---

## PoolKey Construction

### Standard WETH Pool
```solidity
PoolKey memory key = PoolKey({
    currency0: Currency.wrap(WETH < token ? WETH : token),
    currency1: Currency.wrap(WETH < token ? token : WETH),
    fee: 3000, // 0.3%
    tickSpacing: 60,
    hooks: IHooks(address(0)) // No hook
});
```

### Native ETH Pool
```solidity
address nativeETH = address(0);

PoolKey memory key = PoolKey({
    currency0: Currency.wrap(nativeETH < token ? nativeETH : token),
    currency1: Currency.wrap(nativeETH < token ? token : nativeETH),
    fee: 3000,
    tickSpacing: 60,
    hooks: IHooks(address(0))
});
```

### Tick Spacing by Fee Tier
```solidity
function _getTickSpacing(uint24 fee) internal pure returns (int24) {
    if (fee == 100) return 1;      // 0.01%
    if (fee == 500) return 10;     // 0.05%
    if (fee == 3000) return 60;    // 0.3%
    if (fee == 10000) return 200;  // 1%
    revert("Unknown fee tier");
}
```

---

## Next Steps When RPC Available

### Step 1: Basic Pool Discovery (5 min)
```bash
forge test --match-path "test/fork/v4/V4SwapRouting.t.sol" \
    --match-test "test_queryV4PoolManager_deployed" \
    --fork-url $ETH_RPC_URL -vv
```

**Expected**: Verify PoolManager has code at address

### Step 2: Pool Query Tests (10 min)
```bash
forge test --match-path "test/fork/v4/V4SwapRouting.t.sol" \
    --match-test "test_queryV4_WETH_USDC_allFees" \
    --fork-url $ETH_RPC_URL -vvv
```

**Expected**: Find at least 1 WETH/USDC pool
**Output**: sqrtPriceX96, tick, fees

### Step 3: Document Results
Create table of discovered pools:

| Pair | Fee | sqrtPriceX96 | Tick | Hook | Liquidity |
|------|-----|--------------|------|------|-----------|
| WETH/USDC | 500 | ??? | ??? | None | ??? |
| WETH/USDC | 3000 | ??? | ??? | None | ??? |

### Step 4: Select Best Pool for Swap Tests
Choose pool with:
- Highest liquidity
- No hook (for baseline)
- Standard fee (500 or 3000)

---

## Troubleshooting Guide

### Issue: getSlot0() reverts
**Solution**: Use extsload directly (Method 1 above)

### Issue: sqrtPriceX96 = 0 for all pools
**Possible Causes**:
1. PoolKey construction is wrong (check currency ordering)
2. tickSpacing doesn't match fee tier
3. V4 pools don't exist yet on mainnet
4. Using wrong PoolManager address

**Debug**:
```solidity
// Log PoolId to verify calculation
PoolId poolId = key.toId();
console2.logBytes32(PoolId.unwrap(poolId));

// Try with different currency orders
tryBothOrders(tokenA, tokenB, fee);
```

### Issue: RPC connection fails
**Workaround**: Test on different network where V4 is more active:
- Base (V4 launched there first)
- Arbitrum
- Optimism

---

## Alternative: Create Test Pools

If no V4 pools exist on mainnet, we can create them:

```solidity
function test_createV4Pool() public {
    // Initialize new pool
    PoolKey memory key = PoolKey({
        currency0: Currency.wrap(WETH),
        currency1: Currency.wrap(USDC),
        fee: 3000,
        tickSpacing: 60,
        hooks: IHooks(address(0))
    });

    // Calculate initial price: 1 ETH = 3400 USDC
    // sqrtPriceX96 = sqrt(3400 * 1e6 / 1e18) * 2^96
    uint160 sqrtPriceX96 = 1461446703485210103287273052203988822378723970341;

    // Initialize pool
    poolManager.initialize(key, sqrtPriceX96);

    // Verify creation
    (uint160 price, int24 tick, , ) = poolManager.getSlot0(key.toId());
    assertGt(price, 0, "Pool should be initialized");
}
```

---

## Status Summary

**Current Blocker**: RPC connection temporarily unavailable

**Ready to Execute**:
- ✅ Test code written
- ✅ Helper functions implemented
- ✅ V4 addresses configured
- ✅ Query strategy defined

**Blocked Until RPC Fixed**:
- ❌ Actual pool discovery
- ❌ Pool state extraction
- ❌ Swap execution tests

**Alternative Path**:
Continue with implementation code (unlock callbacks, swap logic) while waiting for RPC access. We can test these implementations once RPC is restored.

---

## Implementation Plan (RPC-Independent)

While waiting for RPC, we can:

1. **Write unlock callback implementations** for:
   - Swaps (Phase 2)
   - LP position creation (Phase 3)
   - Fee collection (Phase 4)

2. **Update UltraAlignmentVault.sol** with:
   - V4 swap function signatures
   - V4 LP position management
   - UnlockCallback interface implementation

3. **Update ERC404BondingInstance.sol** with:
   - Verified deployLiquidity implementation
   - Hook attachment validation

4. **Write unit tests** (non-fork) for:
   - PoolKey construction
   - Liquidity calculations
   - Tick math

These can all be done without mainnet fork access and will accelerate integration once RPC is available.
