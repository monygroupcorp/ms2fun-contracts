# V4 Fork Testing - Empirical Findings

**Date**: December 11, 2025
**Status**: Pool Discovery Blocked

---

## What We've Proven Empirically

### ✅ V4 PoolManager Exists
```
Address: 0x000000000004444c5dc75cB358380D2e3dE08A90
Code Size: 24,009 bytes
Status: DEPLOYED and accessible on mainnet
```

### ✅ Query Method Works
- Low-level staticcall to `extsload(bytes32)` executes successfully
- Returns data without reverting
- Can unpack storage slot data (sqrtPriceX96, tick, fees)

### ❌ No Pools Found (Yet)
Tested combinations:
- Native ETH (address(0)) × USDC/USDT/DAI × 100/500/3000/10000 bps
- WETH × USDC/USDT/DAI × 100/500/3000/10000 bps
- **Result**: All queries returned sqrtPriceX96 = 0 (pool doesn't exist or wrong PoolKey)

### ⚠️ Gas Limit Issue
- Each `extsload()` query consumes significant gas
- Foundry hits 1B gas limit with just 3-4 queries in a loop
- Test framework reports OutOfGas even when queries complete
- **Blocker**: Cannot efficiently search through many pool combinations

---

## Hypotheses (Unproven)

### Why No Pools Found?

**Hypothesis 1: Hooks Required**
- We're querying with `hooks: address(0)`
- Maybe all V4 pools on mainnet have hooks attached?
- **Test needed**: Try querying with known hook addresses

**Hypothesis 2: Different Pool Parameters**
- Maybe pools use non-standard fee tiers
- Maybe tick spacing doesn't match our `_getTickSpacing()` function
- **Test needed**: Research actual V4 pool configurations on mainnet

**Hypothesis 3: Storage Slot Calculation Wrong**
```solidity
function _getPoolStateSlot(PoolId poolId) internal pure returns (bytes32) {
    return keccak256(abi.encode(poolId, uint256(0)));
}
```
- This matches StateLibrary.sol implementation
- But maybe mainnet uses different storage layout?
- **Test needed**: Verify against known working pool

**Hypothesis 4: PoolId Calculation Wrong**
```solidity
PoolId poolId = key.toId(); // keccak256(abi.encode(poolKey))
```
- PoolKey has 5 fields: currency0, currency1, fee, tickSpacing, hooks
- Maybe field ordering or packing is different?
- **Test needed**: Calculate PoolId for known pool and compare

---

## Implemented: Isolated Pool Search Tests

Following user's guidance to "isolate your tests so we can save our rpc", created 7 isolated test functions:

1. `test_queryV4_WETH_USDC_allFees()` - 4 fee tiers
2. `test_queryV4_WETH_USDT_allFees()` - 4 fee tiers
3. `test_queryV4_WETH_DAI_allFees()` - 4 fee tiers
4. `test_queryV4_USDC_USDT_allFees()` - 4 fee tiers (stablecoin pair)
5. `test_queryV4_NativeETH_USDC_allFees()` - 4 fee tiers (address(0) instead of WETH)
6. `test_queryV4_NativeETH_USDT_allFees()` - 4 fee tiers
7. `test_queryV4_NativeETH_DAI_allFees()` - 4 fee tiers

**Total coverage**: 28 pool combinations across 7 isolated tests

**Status**: Implementation complete, ready to run when RPC access available

---

## Next Steps

### Waiting for User Input
**User will provide**: Known V4 pool configurations from mainnet
**Once received**: Can validate query method against known-good pools

### Alternative: Skip Pool Discovery
**Rationale**:
- V4 pools exist (user confirmed)
- Pool discovery is just validation, not critical for vault
- Vault will create its own V4 pools via ERC404BondingInstance
- Focus on swap/position tests with mock or created pools

---

##Current Code Status

### Working Query Function
```solidity
function _tryQueryPoolWithWETH(address token, uint24 fee) internal returns (bool found) {
    PoolKey memory key = PoolKey({
        currency0: Currency.wrap(WETH < token ? WETH : token),
        currency1: Currency.wrap(WETH < token ? token : WETH),
        fee: fee,
        tickSpacing: _getTickSpacing(fee),
        hooks: IHooks(address(0))
    });

    PoolId poolId = key.toId();

    (bool success, bytes memory data) = address(poolManager).staticcall(
        abi.encodeWithSignature("extsload(bytes32)", _getPoolStateSlot(poolId))
    );

    if (success && data.length >= 32) {
        bytes32 slot0Data = abi.decode(data, (bytes32));
        uint160 sqrtPriceX96 = uint160(uint256(slot0Data));
        return sqrtPriceX96 > 0;
    }

    return false;
}
```

**Status**: Compiles, executes, returns false (no pools found)

---

## Recommendations

### Immediate Action
**Ask user for known V4 pool configuration**:
```
"You mentioned V4 has many pools with USDC/USDT/ETH. Can you provide:
1. A specific PoolId or pool configuration that exists on mainnet?
2. The PoolKey details (currencies, fee, tickSpacing, hooks)?
3. This will help us validate our query method works correctly."
```

### Alternative Approach
**Create V4 pool in test**:
1. Deploy minimal V4 pool in setUp()
2. Initialize with known parameters
3. Test query against our own pool
4. This proves the query mechanism works

### Pragmatic Path Forward
**Focus on vault integration**:
1. V4 pools clearly exist (user confirmed)
2. Pool discovery is just validation
3. Vault creates its own pools anyway (ERC404BondingInstance)
4. Skip discovery, implement swap/position tests with known pools

---

## Conclusion

**What we know for certain**:
- ✅ V4 PoolManager deployed on mainnet
- ✅ Our query method executes without reverting
- ✅ We can call extsload() and unpack data
- ❌ None of our tested pool combinations exist (or PoolKey is wrong)
- ⚠️ Gas limits prevent exhaustive search

**What we need**:
- Known V4 pool configuration to validate against
- OR accept that discovery isn't critical and move to swap/position testing

**Recommendation**: Ask user for specific V4 pool details to test with, rather than continuing blind search.
