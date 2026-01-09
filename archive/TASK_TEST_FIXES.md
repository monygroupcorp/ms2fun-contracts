# Task: Fix Test Suite (133 Failures)

**Status:** TODO
**Priority:** HIGH
**Created:** 2026-01-05
**Context:** Security remediation introduced test failures. Test suite must pass before audit.

---

## Overview

After implementing security fixes (H-01, H-02, H-03, M-02, L-01 through L-05), the test suite has:
- ✅ **365 tests passing** (73%)
- ⚠️ **133 tests failing** (27%)
- ✅ **Compilation successful**

**Root cause:** Tests were written for pre-fix behavior. Security changes modified contracts, breaking test assumptions.

---

## Failure Categories

### Category 1: Vault Arithmetic Underflow (24 failures)
**File:** `test/vaults/UltraAlignmentVault.t.sol`

**Symptom:**
```
[FAIL: panic: arithmetic underflow or overflow (0x11)]
```

**Affected Tests:**
- test_ConvertAndAddLiquidity_* (8 tests)
- test_ClaimFees_* (8 tests)
- test_CompleteWorkflow_* (2 tests)
- test_GetBenefactorShares_* (2 tests)
- test_GetUnclaimedFees_* (2 tests)
- test_EdgeCase_ManyBenefactors (1 test)
- test_CalculateClaimableAmount_* (1 test)

**Likely Cause:** L-04 dust accumulation mechanism changes
- New state variables: `accumulatedDustShares`, `dustDistributionThreshold`
- Share distribution logic modified (lines 335-376)
- Tests may expect exact share amounts that changed due to dust handling

**Investigation Steps:**
1. Run single failing test with -vvvv to see exact revert location
2. Check if tests assume specific share amounts
3. Verify dust accumulation logic doesn't break invariants
4. Update test expectations for new dust distribution behavior

**Action Items:**
- [ ] Identify exact line causing underflow in vault contract
- [ ] Determine if bug in dust logic or test expectations
- [ ] Fix dust accumulation if broken, or update tests if correct
- [ ] Add new tests for dust accumulation edge cases

---

### Category 2: Pool Configuration Failures (Setup Errors)
**Files:**
- `test/factories/erc1155/ERC1155Factory.t.sol`
- `test/factories/erc404/hooks/UltraAlignmentHookFactory.t.sol`

**Symptom:**
```
[FAIL: revert: Pool must contain native ETH (address(0))] setUp()
```

**Likely Cause:** H-02 restriction (hook only accepts native ETH)
- Hook validation changed: `token == weth || token == address(0)` → `token == address(0)`
- Test setups may configure WETH pools instead of native ETH pools
- Validation now rejects WETH, causing setup to fail

**Investigation Steps:**
1. Check test setUp() for pool configuration
2. Look for `v4PoolKey` initialization using WETH
3. Verify currency pair ordering

**Action Items:**
- [ ] Update test pool configurations to use address(0) instead of WETH
- [ ] Verify currency ordering: address(0) < alignmentToken
- [ ] Update hook factory tests for native ETH requirement
- [ ] Add test cases confirming WETH pools are rejected

---

### Category 3: Fork Test Failures (DEX Routing)
**Files:**
- `test/fork/v2/*.t.sol` (V2 routing, slippage, pair query)
- `test/fork/v3/*.t.sol` (V3 routing, pool query, fee tiers)
- `test/fork/v4/*.t.sol` (V4 pool init, position, swap, hook taxation)
- `test/fork/integration/SwapRoutingComparison.t.sol`

**Symptom:**
```
[FAIL: EvmError: Revert]
```

**Count:** ~70 failures across fork tests

**Likely Causes:**
- Fork tests may not be properly mocking pool state
- V4 PoolManager address may be incorrect for fork
- Tests may assume WETH unwrapping that now has TEST STUB guards

**Investigation Steps:**
1. Check if fork tests use correct mainnet addresses
2. Verify PoolManager deployment on fork
3. Check if tests properly fund contracts with ETH
4. Look for WETH unwrapping expectations

**Action Items:**
- [ ] Verify fork block number is recent (V4 deployed)
- [ ] Check PoolManager address matches mainnet deployment
- [ ] Update tests for native ETH flow (not WETH)
- [ ] Add forge-config for fork testing
- [ ] Consider: Skip fork tests if no mainnet access, run in CI only

---

### Category 4: PricingMath Underflows (14 failures)
**File:** `test/libraries/PricingMath.t.sol`

**Symptom:**
```
[FAIL: panic: arithmetic underflow or overflow (0x11)]
```

**Affected Tests:**
- test_calculateDemandFactor_* (8 tests)
- test_calculatePriceDecay_* (4 tests)
- test_PricingFlow_* (2 tests)

**Likely Cause:** Unrelated to security fixes (library unchanged)
- May be pre-existing failures
- Could be block.timestamp assumptions
- Math formula edge cases

**Investigation Steps:**
1. Check git history - did PricingMath tests ever pass?
2. Look for timestamp manipulation in tests
3. Verify math formulas for underflow conditions

**Action Items:**
- [ ] Determine if pre-existing or new failures
- [ ] Review PricingMath library for safe math
- [ ] Add bounds checking to prevent underflow
- [ ] Update tests with realistic timestamp values

---

### Category 5: Miscellaneous Failures
**Files:**
- `test/factories/erc404/ERC404Reroll.t.sol` (1 failure - LinkMirrorContractFailed)
- `test/master/FactoryInstanceIndexing.t.sol` (1 failure - address mismatch)
- `test/factories/erc404/ERC404Factory.t.sol` (event mismatch)

**Action Items:**
- [ ] Investigate LinkMirrorContractFailed error
- [ ] Fix address assertion in FactoryInstanceIndexing
- [ ] Update event expectations after security fixes

---

## Systematic Fix Approach

### Phase 1: Root Cause Analysis (Day 1)
1. **Run tests with maximum verbosity:**
   ```bash
   forge test --match-test test_ConvertAndAddLiquidity_ConvertsSuccessfully -vvvv
   ```

2. **Categorize failures by root cause:**
   - Dust accumulation changes (L-04)
   - Native ETH requirement (H-02)
   - Fork configuration issues
   - Pre-existing failures

3. **Create fix priority list:**
   - P0: Vault arithmetic (breaks core functionality)
   - P1: Pool configuration (breaks test setup)
   - P2: Fork tests (environment-dependent)
   - P3: PricingMath (library edge cases)

### Phase 2: Fix Implementation (Days 2-3)
1. **Fix vault tests (24 failures):**
   - Debug dust accumulation underflow
   - Update share calculation expectations
   - Add dust distribution test coverage

2. **Fix pool configuration (2 setUp failures):**
   - Update pool configs to native ETH
   - Fix currency ordering
   - Update hook factory tests

3. **Fix fork tests (70 failures):**
   - Verify mainnet fork configuration
   - Update for native ETH flow
   - Add skip conditions if fork unavailable

4. **Fix PricingMath (14 failures):**
   - Add safe math bounds
   - Fix timestamp assumptions
   - Review formulas for edge cases

### Phase 3: Verification (Day 4)
1. **Full test suite:**
   ```bash
   forge test
   forge test --fork-url $MAINNET_RPC_URL  # Fork tests
   ```

2. **Coverage report:**
   ```bash
   forge coverage
   ```

3. **Gas snapshot:**
   ```bash
   forge snapshot
   ```

---

## Success Criteria

- [ ] All 498 tests passing (100% pass rate)
- [ ] No compilation warnings
- [ ] Coverage >80% on security-fixed files
- [ ] Gas snapshots show reasonable increases from security fixes
- [ ] Fork tests pass against mainnet (or skipped with clear reason)

---

## Expected Outcomes

After completing this task:
1. **Test suite validates security fixes work correctly**
2. **Regression protection for future changes**
3. **Confidence for audit submission**
4. **Documentation of test updates for auditors**

---

## Notes for Implementation

### Test Update Guidelines
- Preserve test intent (what behavior is being verified)
- Update expectations to match new behavior
- Add comments explaining changes: "// Updated for L-04 dust accumulation"
- Don't remove failing tests - fix them
- Add new tests for security fix edge cases

### Common Test Patterns to Update
```solidity
// OLD: Exact share amounts
assertEq(shares, 1000000);

// NEW: Approximate with dust tolerance
assertApproxEqAbs(shares, 1000000, dustThreshold);

// OLD: WETH pool configuration
poolKey.currency0 = Currency.wrap(weth);

// NEW: Native ETH pool configuration
poolKey.currency0 = Currency.wrap(address(0));
```

### Test Additions Needed
1. **Dust accumulation tests:**
   - Small contribution rounds to 0 shares
   - Dust accumulates over multiple rounds
   - Distribution when threshold reached
   - Largest contributor receives dust

2. **Native ETH enforcement tests:**
   - WETH pool rejected at hook level
   - Native ETH pool accepted
   - Currency ordering validated

3. **Reentrancy protection tests:**
   - External receive() call blocked by reentrancy
   - WETH unwrapping allowed (test mode)
   - Multiple contribution attempts

---

## Timeline Estimate

- **Phase 1 (Analysis):** 4-6 hours
- **Phase 2 (Fixes):** 12-16 hours
- **Phase 3 (Verification):** 2-4 hours
- **Total:** 2-3 days for experienced dev

---

## Dependencies

- Mainnet RPC URL for fork tests (or decision to skip)
- Understanding of dust accumulation mechanism (L-04)
- Understanding of native ETH requirement (H-02)
- Access to Uniswap V4 mainnet deployment addresses

---

## References

- SECURITY_REVIEW.md - Details of all security fixes
- L-04 implementation (lines 335-376 in UltraAlignmentVault.sol)
- H-02 implementation (UltraAlignmentV4Hook.sol:142-149)
- Git diff of security changes: `git diff HEAD~5 HEAD`
