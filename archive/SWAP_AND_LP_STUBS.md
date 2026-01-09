# Swap and LP Stubs - Implementation Guide

## Overview

This document outlines all remaining stub functions in the UltraAlignmentVault that require Uniswap integration. These stubs are intentionally left as TODOs to allow the main business logic to be tested and verified independently from Uniswap integration details.

**Architecture Principle**: Swap source is DEX-agnostic; only LP management is V4-specific.

---

## Stub Functions

### 1. `swapETHForTarget()`

**Location**: `src/vaults/UltraAlignmentVault.sol:399-416`

**Current Status**: Stub (returns 0)

**Purpose**: Convert ETH to alignment target token via DEX router

**Function Signature**:
```solidity
function swapETHForTarget(
    uint256 ethAmount,
    uint256 minOutTarget,
    bytes memory swapData
) internal returns (uint256 targetTokenReceived)
```

**Parameters**:
- `ethAmount`: ETH amount to swap (in wei)
- `minOutTarget`: Minimum target tokens to receive (slippage protection)
- `swapData`: Router-specific encoded call data (flexible DEX selection)

**Return Value**:
- `targetTokenReceived`: Amount of target token received from swap

**TODO Tasks**:
- [ ] Implement actual swap call through selected router (V2Router02, SwapRouter, SwapRouter02, etc.)
- [ ] Handle slippage: revert if output < minOutTarget
- [ ] Route through appropriate DEX based on swapData
- [ ] Support V2, V3, and V4 pools seamlessly
- [ ] Test with real pools on fork (see test/fork/VaultUniswapIntegration.t.sol:test_SwapETHForTarget_*)

**Related Files**:
- `test/fork/VaultUniswapIntegration.t.sol` - Swap tests (stub placeholders)
- `test/fork/VaultLiquidityFlow.t.sol:test_Flow_ETHToSwapToPosition()` - End-to-end test

**Example Implementation Approach**:
```solidity
// Router call via encoded swapData
(bool success, bytes memory returnData) = router.call(swapData);
require(success, "Swap failed");

// Decode return value based on router type
uint256 targetTokenReceived = abi.decode(returnData, (uint256));
require(targetTokenReceived >= minOutTarget, "Slippage exceeded");

return targetTokenReceived;
```

---

### 2. `convertAndAddLiquidityV4()`

**Location**: `src/vaults/UltraAlignmentVault.sol:330-388`

**Current Status**: Partially implemented (relies on swapETHForTarget stub)

**Purpose**: Full lifecycle - swap ETH to target token and create V4 liquidity position with hook

**Function Signature**:
```solidity
function convertAndAddLiquidityV4(
    uint256 minOutTarget,
    int24 tickLower,
    int24 tickUpper
) external nonReentrant returns (uint256 lpPositionValue)
```

**Parameters**:
- `minOutTarget`: Minimum target tokens from swap (slippage protection)
- `tickLower`: Lower tick for V4 position range
- `tickUpper`: Upper tick for V4 position range

**Return Value**:
- `lpPositionValue`: Sum of position values (amount0 + amount1)

**Current Implementation**:
1. ✅ Collects ETH from benefactors
2. ✅ Calculates conversion amounts
3. ✅ Creates frozen benefactor stakes
4. 🔲 Calls swapETHForTarget (stub - currently returns 0)
5. 🔲 Records V4 LP position metadata
6. 🔲 Hook attachment (automatic when hook registered on pool)
7. ✅ Pays caller 0.5% reward
8. ✅ Updates tracking

**TODO Tasks**:
- [ ] Implement PoolManager liquidity addition:
  ```solidity
  // After swapETHForTarget() returns target tokens:
  // 1. Approve PoolManager for WETH and target token
  // 2. Call PoolManager.modifyLiquidity(key, liquidity params)
  // 3. Hook's onModifyLiquidity() is automatically called
  // 4. Record position metadata via LPPositionValuation.recordLPPosition()
  ```
- [ ] Calculate proper liquidity amount for tick range
- [ ] Handle WETH wrapping/unwrapping
- [ ] Verify hook is active on the pool before modifying
- [ ] Test V4 position creation on fork

**Related Files**:
- `test/fork/VaultUniswapIntegration.t.sol:test_ConvertAndAddLiquidityV4_*` - Integration tests
- `test/fork/VaultLiquidityFlow.t.sol:test_Flow_ETHToSwapToPosition()` - End-to-end test

**Critical Detail - Hook Attachment**:
- No separate "attach hook" call needed
- Hook is registered on the pool (governance/owner setup)
- When vault calls modifyLiquidity(), hook's onModifyLiquidity() fires automatically
- Hook can identify vault's position via `msg.sender == address(this)` check

---

### 3. `collectFeesFromPosition()`

**Location**: `src/vaults/UltraAlignmentVault.sol:421-447` (within claimBenefactorFees)

**Current Status**: Partially implemented (V4-specific fee collection)

**Purpose**: Collect accumulated fees from V4 position

**Functionality**:
```solidity
// Inside claimBenefactorFees():
// 1. Get current accumulated fees from LPPositionMetadata
uint256 accFees0 = currentLPPosition.accumulatedFees0;
uint256 accFees1 = currentLPPosition.accumulatedFees1;

// 2. Call V4 PoolManager to collect fees
// (TODO: Implement actual PoolManager fee collection)

// 3. Update LPPositionMetadata to reset accumulatedFees
LPPositionValuation.updateAccumulatedFees(currentLPPosition, 0, 0);
```

**TODO Tasks**:
- [ ] Implement V4 PoolManager fee collection:
  ```solidity
  // PoolManager.collectHookFees() or similar call
  // Different PoolManager versions may have different APIs
  ```
- [ ] Handle fee token conversions:
  - If token0 ≠ WETH, swap for WETH/ETH
  - If token1 ≠ WETH, already in WETH or need conversion
- [ ] Track fees properly in state
- [ ] Test fee collection on fork with real pools

**Related Files**:
- `test/fork/VaultUniswapIntegration.t.sol:test_CollectFees_*` - Fee collection tests
- `test/fork/VaultLiquidityFlow.t.sol:test_Flow_TradesAccumulateFees()` - Flow test

---

## Testing Strategy

### Unit Tests (No Fork Required)

**Status**: ✅ Passing (67 tests)

**Location**: `test/vaults/UltraAlignmentVaultV1.t.sol`

**Tests**:
- Benefactor stake creation ✅
- Fee distribution math ✅
- Vault state management ✅
- Alignment target setup ✅
- ETH reward calculations ✅

**These tests do NOT need Uniswap integration** because they mock the swap/LP functions.

---

### Fork Tests (Requires RPC URL)

**Status**: 🔲 Stubs created (implementation pending)

**Location**: `test/fork/`

**Files**:
1. `VaultUniswapIntegration.t.sol` - Tests for swap/position/fee integration
2. `VaultLiquidityFlow.t.sol` - End-to-end lifecycle tests

**Setup Required**:
```bash
# In foundry.toml or test setup:
[profile.fork]
fork_url = "https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY"
# or for testnet
fork_url = "https://sepolia.infura.io/v3/YOUR_KEY"
```

**Running Fork Tests**:
```bash
# All fork tests
forge test --match-path "test/fork/*" --fork-url $FORK_URL

# Specific test file
forge test --match-path "test/fork/VaultUniswapIntegration.t.sol" --fork-url $FORK_URL

# Specific test function
forge test --match-test "test_SwapETHForTarget_BasicSwap" --fork-url $FORK_URL
```

---

## Implementation Checklist

### Phase 1: Swap Function
- [ ] Research available routers on target network
- [ ] Choose router interface (V2Router02, SwapRouter, SwapRouter02, etc.)
- [ ] Implement swapETHForTarget() with slippage protection
- [ ] Test on fork with real pools
- [ ] Verify swap paths work for all supported DEX versions

### Phase 2: V4 Position Creation
- [ ] Get PoolKey for alignment target pool
- [ ] Calculate liquidity for tick range
- [ ] Implement PoolManager.modifyLiquidity() call
- [ ] Verify hook is attached and receives onModifyLiquidity()
- [ ] Record position metadata
- [ ] Test position creation on fork

### Phase 3: Fee Collection
- [ ] Implement PoolManager fee collection
- [ ] Handle token conversion (token0 → ETH if needed)
- [ ] Update position metadata after fee collection
- [ ] Test fee accumulation and collection on fork
- [ ] Verify benefactor fee distribution

### Phase 4: End-to-End Testing
- [ ] Run full flow test: ETH → swap → position → fees → distribution
- [ ] Test with multiple benefactors
- [ ] Test with multiple conversions
- [ ] Stress test with large amounts and high frequencies
- [ ] Verify alignment incentive structure (double taxation)

---

## Stub Reduction Summary

**Before (Complex)**:
- 16 TODO items across 3 pool types (V2/V3/V4)
- 150 lines of conversion logic (87 lines V2 + 67 lines V3 + 60 lines V4)
- 3 different position types (ERC20, LP token, V4 position)
- 3 different fee models
- Complex pool type detection logic

**After (Simple)**:
- 3 TODO items (swap, position creation, fee collection)
- 50 lines of V4-only conversion logic
- 1 position type (V4)
- 1 fee model (V4 hooks)
- No pool type detection needed

**Complexity Reduction**: ~70%

---

## Technical Notes

### Why These Stubs Exist

1. **Uniswap Compiler Version**: Uniswap V4 core uses old Solidity versions that conflict with our tests
2. **Mocking Limitations**: Complex pool interactions can't be reliably mocked
3. **Fork Testing**: Real pools provide realistic behavior
4. **Isolation**: Business logic (stakes, fees) separate from DEX integration

### Architecture Benefits

1. **Business Logic Unblocked**: All tests pass without DEX integration
2. **Clear Interfaces**: Each stub has well-defined inputs/outputs
3. **Flexible DEX Selection**: swapData allows different DEX/router combinations
4. **Frozen Stakes**: Benefactor percentages immutable, unaffected by LP value changes
5. **Vault-Scoped Hook**: Vault hook is registered to the vault itself, gets called by all integrated projects; vault's own V4 position earns separate pool fees

### Future Optimization

Once stubs are implemented:
1. Consider caching swap paths for gas optimization
2. Implement slippage tracking/analytics
3. Add position rebalancing logic
4. Support multiple simultaneous V4 positions

---

## Vault Hook Architecture

The vault's hook operates independently from vault-created V4 positions:

**Hook Scope**: Vault-level
- Hook is registered to the vault contract itself
- All integrated ERC404/ERC1155 projects point their hooks to the vault's hook
- When external projects execute trades, the vault hook is triggered
- Hook collects fees from external project activity
- Benefactors claim from this hook fee pool

**V4 Position Scope**: Pool-level (separate from hook)
- Vault creates a V4 position on a specific pool (e.g., WETH/TARGET)
- This position earns normal pool fees like any other LP
- These pool fees are independent of hook fees
- No position owner detection needed - hook and position are separate concerns

**Fee Flows**:
1. **External projects trade**: Hook triggered → fees accumulate in vault
2. **Vault's own position trades**: Pool fees earned → separate from hook
3. **Benefactors claim**: Receive share of hook fees based on frozen stakes

This keeps the architecture clean and simple - no special cases needed.

---

## Questions & Support

**Q**: Why is swapData just bytes memory?

**A**: This allows maximum flexibility. Callers encode router-specific call data. The vault just calls the router with those bytes. This works for V2Router02.swapExactETHForTokens(), SwapRouter.exactInputSingle(), SwapRouter02.exactInputSingle(), etc.

**Q**: Where does the vault's hook get called from?

**A**: Integrated ERC404/ERC1155 projects register the vault's hook on their own pools/contracts. When they execute trades, they trigger the vault hook, which collects fees. The vault hook is not specific to any single pool.

**Q**: What about fees from the vault's own V4 position?

**A**: Separate from hook fees. The vault's V4 position on a pool earns standard LP fees like any other position. These are claimed independently and would be managed separately from hook fee distribution.

**Q**: What if the fee collection fails?

**A**: claimBenefactorFees() should revert. The benefactor can retry later. Consider implementing retry logic in production.

**Q**: How are frozen stakes related to LP value changes?

**A**: Completely independent. Frozen stakes are calculated from ETH contributions at conversion time and never change. LP position value can fluctuate, but benefactor percentages remain frozen. This protects benefactors from IL impact on their fee distribution.

---

## See Also

- `VAULT_REDESIGN_SUMMARY.md` - Architecture overview
- `src/vaults/UltraAlignmentVault.sol` - Vault implementation
- `src/libraries/LPPositionValuation.sol` - Stake and position tracking
- `test/fork/VaultUniswapIntegration.t.sol` - Integration test stubs
- `test/fork/VaultLiquidityFlow.t.sol` - Flow test stubs
