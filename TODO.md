# Audit Readiness TODO - ms2fun-contracts

**Target:** Production-ready codebase for professional security audit
**Status:** 72% Ready → 100% Ready
**Estimated Time:** 4-6 days
**Last Updated:** 2025-12-16

---

## Progress Tracker

- **Critical Issues:** 0/7 complete ⚠️
- **High Priority:** 0/3 complete
- **Medium Priority:** 0/5 complete
- **Overall Progress:** 0/15 complete (0%)

---

## CRITICAL PRIORITY (BLOCKING AUDIT)

### 🔴 1. Complete Stub Function: _checkTargetAssetPriceAndPurchasePower()

**File:** `src/vaults/UltraAlignmentVault.sol:589-605`
**Status:** ❌ TODO
**Time Estimate:** 1 day
**Assignee:** TBD
**Dependencies:** None

**Current State:**
```solidity
function _checkTargetAssetPriceAndPurchasePower() internal view {
    // Stub validation: Assume pools exist with reasonable liquidity
    return;
}
```

**Requirements:**
- [ ] Implement V2 pool reserve queries (`IUniswapV2Pair.getReserves()`)
- [ ] Implement V3 pool price queries (`IUniswapV3Pool.slot0()`)
- [ ] Calculate price impact for intended swap amount
- [ ] Add oracle price fallback (Chainlink or TWAP)
- [ ] Add price deviation checks (e.g., <5% from oracle)
- [ ] Revert if no liquidity or price manipulation detected
- [ ] Add proper error messages for each failure case
- [ ] Update NatSpec documentation

**Acceptance Criteria:**
- Function queries real pool data on mainnet fork
- Reverts with clear error if pools don't exist
- Reverts if price deviates >5% from oracle
- All edge cases tested (no pools, low liquidity, price manipulation)

**Related Tests:**
- Add `test_checkTargetAssetPrice_noV2Pool_reverts()`
- Add `test_checkTargetAssetPrice_priceManipulation_reverts()`
- Add `test_checkTargetAssetPrice_lowLiquidity_reverts()`

---

### 🔴 2. Complete Stub Function: _checkCurrentVaultOwnedLpTickValues()

**File:** `src/vaults/UltraAlignmentVault.sol:613-628`
**Status:** ❌ TODO
**Time Estimate:** 6-8 hours
**Assignee:** TBD
**Dependencies:** None

**Current State:**
```solidity
function _checkCurrentVaultOwnedLpTickValues() internal view {
    // Stub: No implementation
    return;
}
```

**Requirements:**
- [ ] Query V4 PoolManager for vault's position using `getPosition()`
- [ ] Extract tickLower, tickUpper, and liquidity from position
- [ ] Calculate position value in terms of token amounts
- [ ] Handle case where vault has no position yet (totalLPUnits == 0)
- [ ] Store tick range in state or return values for use by other functions
- [ ] Add validation that position is active (liquidity > 0)
- [ ] Update NatSpec documentation

**Acceptance Criteria:**
- Function returns valid tick range when vault has position
- Returns sensible defaults when vault has no position
- Works correctly on mainnet fork with real V4 pools
- Integration tests verify correct tick range extraction

**Related Tests:**
- Add `test_checkVaultLpTicks_noPosition_returnsDefaults()`
- Add `test_checkVaultLpTicks_withPosition_returnsActualTicks()`

---

### 🔴 3. Complete Stub Function: _calculateProportionOfEthToSwapBasedOnVaultOwnedLpTickValues()

**File:** `src/vaults/UltraAlignmentVault.sol:640-669`
**Status:** ❌ TODO
**Time Estimate:** 1 day
**Assignee:** TBD
**Dependencies:** Task #2 (needs tick range from vault position)

**Current State:**
```solidity
function _calculateProportionOfEthToSwapBasedOnVaultOwnedLpTickValues()
    internal view returns (uint256 proportionToSwap)
{
    // Stub: Always returns 50%
    if (totalLPUnits == 0) {
        proportionToSwap = 5e17; // 50%
    } else {
        proportionToSwap = 5e17; // 50%
    }
    return proportionToSwap;
}
```

**Requirements:**
- [ ] Use tick range from `_checkCurrentVaultOwnedLpTickValues()`
- [ ] Query current pool price (sqrtPriceX96)
- [ ] Calculate optimal token ratio for adding liquidity at current price
- [ ] Use Uniswap V3/V4 math: `LiquidityAmounts.getAmountsForLiquidity()`
- [ ] Return proportion that minimizes leftover tokens
- [ ] Handle edge case: first deposit (no existing position) → use 50%
- [ ] Add slippage buffer (e.g., swap 2% less to account for price movement)
- [ ] Update NatSpec with formula explanation

**Acceptance Criteria:**
- First deposit returns ~50% (balanced entry)
- Subsequent deposits calculate based on existing position's tick range
- Proportion changes dynamically based on current pool price
- Integration tests show <5% leftover tokens after LP addition
- Works with concentrated positions (narrow tick ranges)

**Related Tests:**
- Add `test_calculateSwapProportion_firstDeposit_returns50Percent()`
- Add `test_calculateSwapProportion_existingPosition_dynamic()`
- Add `test_calculateSwapProportion_narrowRange_correctRatio()`

---

### 🔴 4. Replace .transfer() with SafeTransferLib in VaultRegistry

**File:** `src/registry/VaultRegistry.sol:114, 160`
**Status:** ❌ TODO
**Time Estimate:** 15 minutes
**Assignee:** TBD
**Dependencies:** None

**Current State:**
```solidity
// Line 114
payable(msg.sender).transfer(msg.value - vaultRegistrationFee);

// Line 160
payable(msg.sender).transfer(msg.value - hookRegistrationFee);
```

**Requirements:**
- [ ] Import `SafeTransferLib` from Solady
- [ ] Replace both `.transfer()` calls with `SafeTransferLib.safeTransferETH()`
- [ ] Add explicit `require(msg.value >= fee, "Insufficient payment")` checks
- [ ] Test with smart contract wallet recipient

**Acceptance Criteria:**
- Refunds work for both EOAs and smart contract wallets
- Gas limit not restricted to 2300
- Clear error message if insufficient payment

**Related Tests:**
- Add `test_registerVault_contractWallet_refundSucceeds()`
- Add `test_registerHook_contractWallet_refundSucceeds()`

---

### 🔴 5. Replace .transfer() with SafeTransferLib in ERC1155Factory

**File:** `src/factories/erc1155/ERC1155Factory.sol:92`
**Status:** ❌ TODO
**Time Estimate:** 15 minutes
**Assignee:** TBD
**Dependencies:** None

**Current State:**
```solidity
payable(msg.sender).transfer(msg.value - instanceCreationFee);
```

**Requirements:**
- [ ] Import `SafeTransferLib` from Solady
- [ ] Replace `.transfer()` with `SafeTransferLib.safeTransferETH()`
- [ ] Add explicit `require(msg.value >= instanceCreationFee, "Insufficient payment")` check
- [ ] Test with smart contract wallet recipient

**Acceptance Criteria:**
- Refunds work for smart contract wallets
- Clear error message if insufficient payment

**Related Tests:**
- Add `test_createInstance_contractWallet_refundSucceeds()`

---

### 🔴 6. Replace .transfer() with SafeTransferLib in ERC404Factory

**File:** `src/factories/erc404/ERC404Factory.sol:139`
**Status:** ❌ TODO
**Time Estimate:** 15 minutes
**Assignee:** TBD
**Dependencies:** None

**Current State:**
```solidity
payable(msg.sender).transfer(msg.value - totalFee);
```

**Requirements:**
- [ ] Import `SafeTransferLib` from Solady
- [ ] Replace `.transfer()` with `SafeTransferLib.safeTransferETH()`
- [ ] Add explicit `require(msg.value >= totalFee, "Insufficient payment")` check
- [ ] Test with smart contract wallet recipient

**Acceptance Criteria:**
- Refunds work for smart contract wallets
- Clear error message if insufficient payment

**Related Tests:**
- Add `test_createInstance_contractWallet_refundSucceeds()`

---

### 🔴 7. Add Access Control to ERC404BondingInstance.deployLiquidity()

**File:** `src/factories/erc404/ERC404BondingInstance.sol:1145`
**Status:** ❌ TODO
**Time Estimate:** 5 minutes
**Assignee:** TBD
**Dependencies:** None

**Current State:**
```solidity
function deployLiquidity(...) external nonReentrant {
    // Missing onlyOwner modifier!
}
```

**Requirements:**
- [ ] Add `onlyOwner` modifier to function signature
- [ ] Verify existing tests still pass
- [ ] Add test for unauthorized access attempt

**Acceptance Criteria:**
- Only owner can call deployLiquidity()
- Non-owner calls revert with "Unauthorized" error
- Existing functionality unchanged for owner

**Related Tests:**
- Add `test_deployLiquidity_nonOwner_reverts()`

---

## HIGH PRIORITY

### 🟠 8. Replace v4-core/test/ Imports with Production Code

**Files:**
- `src/vaults/UltraAlignmentVault.sol:11` (CurrencySettler)
- `src/factories/erc404/ERC404BondingInstance.sol:17` (LiquidityAmounts)

**Status:** ❌ TODO
**Time Estimate:** 2-3 hours
**Assignee:** TBD
**Dependencies:** None

**Current State:**
```solidity
import {CurrencySettler} from "../../lib/v4-core/test/utils/CurrencySettler.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
```

**Requirements:**
- [ ] Copy CurrencySettler.sol into `src/libraries/v4/CurrencySettler.sol`
- [ ] Copy LiquidityAmounts.sol into `src/libraries/v4/LiquidityAmounts.sol`
- [ ] Update import statements in both files
- [ ] Verify all tests still pass with new imports
- [ ] Add license headers to copied files
- [ ] Document source in file comments

**Acceptance Criteria:**
- No imports from v4-core/test/ directories
- All tests pass with production imports
- Code is identical to test utils (copy, not modify)

**Related Tests:**
- Run full test suite to verify compatibility

---

### 🟠 9. Add Unit Tests for UltraAlignmentV4Hook.afterSwap()

**File:** `test/factories/erc404/hooks/UltraAlignmentV4Hook.t.sol` (create new file)
**Status:** ❌ TODO
**Time Estimate:** 4 hours
**Assignee:** TBD
**Dependencies:** None

**Requirements:**
- [ ] Create dedicated hook unit test file
- [ ] Test tax calculation for various swap amounts
- [ ] Test tax rounding for very small swaps
- [ ] Test vault.receiveHookTax() integration
- [ ] Test with 0% tax rate (should not call vault)
- [ ] Test with maximum tax rate (10000 bps)
- [ ] Test gas efficiency with many swaps
- [ ] Mock vault to verify exact tax amounts sent

**Test Cases:**
- `test_afterSwap_1percentTax_correctAmount()`
- `test_afterSwap_smallSwap_taxRoundsDownCorrectly()`
- `test_afterSwap_zeroTax_noVaultCall()`
- `test_afterSwap_maxTax_100percentToVault()`
- `test_afterSwap_vaultCallFails_swapSucceeds()` (hook shouldn't revert)

**Acceptance Criteria:**
- 100% coverage of afterSwap() logic
- All edge cases tested (0 tax, max tax, rounding)
- Tests use mocked vault to verify exact tax transfers

---

### 🟠 10. Add Unit Tests for MasterRegistryV1 Queue System

**File:** `test/registry/MasterRegistryQueue.t.sol` (create new file)
**Status:** ❌ TODO
**Time Estimate:** 1 day
**Assignee:** TBD
**Dependencies:** None

**Requirements:**
- [ ] Test rentFeaturedPosition() with various positions
- [ ] Test bumpPosition() queue shifting logic
- [ ] Test renewPosition() with expired rentals
- [ ] Test queue cleanup when rentals expire
- [ ] Test position shifting with edge cases (first position, last position)
- [ ] Test demand tracking updates during bumps
- [ ] Test rental refunds when position removed
- [ ] Fuzz test queue manipulation with random operations

**Test Cases:**
- `test_rentFeaturedPosition_emptyQueue_success()`
- `test_bumpPosition_shiftsQueueCorrectly()`
- `test_bumpPosition_firstPosition_noShift()`
- `test_renewPosition_expiresOldRental()`
- `test_queueCleanup_expiredRental_removesFromQueue()`
- `test_fuzz_queueOperations_maintainsConsistency()`

**Acceptance Criteria:**
- All queue operations tested with unit tests
- Edge cases covered (empty queue, full queue, single item)
- Fuzz tests ensure queue integrity under random operations

---

## MEDIUM PRIORITY

### 🟡 11. Add Explicit Fee Validation Checks

**Files:**
- `src/registry/VaultRegistry.sol:114, 160`
- `src/factories/erc1155/ERC1155Factory.sol:92`
- `src/factories/erc404/ERC404Factory.sol:139`

**Status:** ❌ TODO
**Time Estimate:** 30 minutes
**Assignee:** TBD
**Dependencies:** Tasks #4, #5, #6 (doing together with .transfer() replacement)

**Requirements:**
- [ ] Add `require(msg.value >= fee, "Insufficient payment")` before each refund calculation
- [ ] Use descriptive error messages for each contract
- [ ] Test with exact payment (no refund)
- [ ] Test with insufficient payment (should revert)

**Acceptance Criteria:**
- Explicit validation before all fee calculations
- Clear error messages distinguish between contracts
- Tests cover exact payment and underpayment cases

**Related Tests:**
- `test_registerVault_insufficientPayment_reverts()`
- `test_createInstance_exactPayment_noRefund()`

---

### 🟡 12. Add V4 Pool Validation in UltraAlignmentVault

**File:** `src/vaults/UltraAlignmentVault.sol`
**Status:** ❌ TODO
**Time Estimate:** 2 hours
**Assignee:** TBD
**Dependencies:** None

**Requirements:**
- [ ] Add `_validateV4Pool()` internal function
- [ ] Check pool is initialized (has liquidity)
- [ ] Verify pool contains correct token pair (currency0, currency1)
- [ ] Validate fee tier is reasonable (3000, 500, 10000)
- [ ] Call validation in `setV4PoolKey()` and before first LP operation
- [ ] Add clear error messages for each validation failure

**Acceptance Criteria:**
- Cannot set invalid pool key
- Cannot add liquidity to uninitialized pool
- Clear error messages for each failure case

**Related Tests:**
- `test_setV4PoolKey_uninitializedPool_reverts()`
- `test_convertAndAddLiquidity_invalidPool_reverts()`

---

### 🟡 13. Add WETH Balance Checks Before Withdrawals

**File:** `src/vaults/UltraAlignmentVault.sol`
**Status:** ❌ TODO
**Time Estimate:** 1 hour
**Assignee:** TBD
**Dependencies:** None

**Requirements:**
- [ ] Add balance check before large WETH withdrawals
- [ ] Ensure vault has sufficient WETH before unwrapping
- [ ] Add descriptive error message for insufficient balance
- [ ] Test edge case where settlement returns less than expected

**Acceptance Criteria:**
- Cannot withdraw more WETH than balance
- Clear error message if insufficient balance
- Tests cover settlement edge cases

**Related Tests:**
- `test_convertAndAddLiquidity_insufficientWETH_reverts()`

---

### 🟡 14. Add Comprehensive NatSpec to ERC404BondingInstance

**File:** `src/factories/erc404/ERC404BondingInstance.sol`
**Status:** ❌ TODO
**Time Estimate:** 4-6 hours
**Assignee:** TBD
**Dependencies:** None

**Requirements:**
- [ ] Add @notice, @dev, @param, @return to all public/external functions
- [ ] Document staking functions (lines 842-1016)
- [ ] Document balance mint and message system
- [ ] Explain bonding curve mechanics in contract-level comment
- [ ] Document tier system with example password hashes
- [ ] Add examples for complex functions (reroll, staking)
- [ ] Document state machine (bonding phases)

**Acceptance Criteria:**
- All public/external functions have complete NatSpec
- Complex logic has @dev explanations
- Examples provided for non-obvious usage patterns
- Contract-level documentation explains overall architecture

---

### 🟡 15. Create Architecture Documentation

**File:** `docs/ARCHITECTURE.md` (create new)
**Status:** ❌ TODO
**Time Estimate:** 3-4 hours
**Assignee:** TBD
**Dependencies:** None

**Requirements:**
- [ ] Create visual diagram: Factory → Instance → Hook → Vault flow
- [ ] Explain V4 unlock callback pattern with code examples
- [ ] Document fee claim delta calculation with examples
- [ ] Explain MasterRegistry queue rental system
- [ ] Document WETH vs native ETH usage patterns
- [ ] Add deployment checklist for new chains
- [ ] Document upgrade path for MasterRegistry proxy

**Sections:**
1. System Overview & Architecture Diagram
2. Contract Interactions & Data Flow
3. Uniswap V4 Integration Patterns
4. Fee Distribution Mechanism
5. Queue Rental System
6. Deployment Guide
7. Upgrade Procedures

**Acceptance Criteria:**
- Visual diagram shows all contract interactions
- Each integration pattern has code example
- New developers can understand system from documentation
- Deployment checklist is actionable

---

## VALIDATION & TESTING

### 🔵 16. Run Full Test Suite & Coverage

**Status:** ❌ TODO
**Time Estimate:** 1 hour
**Assignee:** TBD
**Dependencies:** All above tasks complete

**Commands:**
```bash
# Run all tests
forge test

# Run fork tests
forge test --mp test/fork/ --fork-url $ETH_RPC_URL

# Generate coverage report
forge coverage --report summary

# Run gas analysis
forge test --gas-report
```

**Requirements:**
- [ ] All tests pass on local
- [ ] All tests pass on mainnet fork
- [ ] Coverage >80% for critical contracts
- [ ] No regressions from changes
- [ ] Gas costs within reasonable limits

**Acceptance Criteria:**
- 100% test pass rate
- UltraAlignmentVault: >85% coverage
- ERC404BondingInstance: >80% coverage
- MasterRegistryV1: >75% coverage
- All critical functions have tests

---

### 🔵 17. Final Audit Preparation Checklist

**Status:** ❌ TODO
**Time Estimate:** 2 hours
**Assignee:** TBD
**Dependencies:** Tasks 1-16 complete

**Pre-Audit Checklist:**
- [ ] All TODO items in code removed or documented
- [ ] All stub functions implemented
- [ ] No deprecated patterns (e.g., .transfer())
- [ ] All critical functions have access control
- [ ] All external calls have safety checks
- [ ] Test coverage >80% on critical paths
- [ ] NatSpec complete for all public functions
- [ ] Architecture documentation complete
- [ ] README updated with setup instructions
- [ ] Known limitations documented
- [ ] Deployment scripts tested
- [ ] Gas optimization review complete
- [ ] No compiler warnings
- [ ] All dependencies audited or well-known
- [ ] Emergency pause mechanisms documented

---

## PROJECT TRACKING

### Time Allocation
- **Day 1-2:** Stub functions (#1, #2, #3) + access control (#7)
- **Day 3:** .transfer() replacements (#4, #5, #6) + imports (#8) + validation (#11, #12, #13)
- **Day 4:** Hook tests (#9)
- **Day 5:** Registry tests (#10)
- **Day 6:** Documentation (#14, #15) + validation (#16, #17)

### Success Metrics
- ✅ Zero stub functions remaining
- ✅ Zero deprecated patterns (.transfer())
- ✅ Zero test utility imports in production code
- ✅ >80% test coverage on critical contracts
- ✅ Complete NatSpec documentation
- ✅ Architecture docs with diagrams
- ✅ All tests passing on mainnet fork

### Audit Submission Criteria
When all tasks complete:
- [ ] Run final test suite (Task #16)
- [ ] Complete audit checklist (Task #17)
- [ ] Create final audit-ready commit
- [ ] Tag release: `v1.0.0-audit-ready`
- [ ] Generate submission package with docs
- [ ] Submit to audit firm

---

## NOTES & DECISIONS

### Design Decisions
- **Stub Functions:** Will implement with oracle fallback for price protection
- **Test Utilities:** Copying into src/libraries/ rather than dependency
- **Access Control:** Using Solady's Ownable pattern throughout
- **Documentation:** Following NatSpec standards from OpenZeppelin

### Known Limitations (To Document)
- V4 integration requires mainnet fork for testing
- Oracle dependency for price protection (Chainlink recommended)
- Queue rental system requires off-chain monitoring for expirations
- WETH vs ETH: Vault uses WETH internally, native ETH at boundaries

### Future Enhancements (Post-Audit)
- Implement governance for parameter changes
- Add emergency pause mechanism
- Multi-sig ownership for critical functions
- Gas optimization pass
- Additional DEX integrations (V2, V3)

---

**Last Updated:** 2025-12-16
**Next Review:** After completing tasks 1-7 (critical path)
**Questions/Blockers:** None currently
