# ms2fun-contracts Manual Review Guide

**Last Updated**: December 2, 2025
**Status**: Ready for Manual Review
**Test Coverage**: 101 tests passing (0 failures)

---

## Review Checklist

Use this guide to systematically review the ms2fun-contracts system. Each section includes key files, critical logic points, and verification steps.

---

## 1. ARCHITECTURE OVERVIEW

### 1.1 System Topology
```
Master Registry (Factory/Instance Indexing)
    ↓
    ├─→ ERC404Factory + ERC404BondingInstance + V4Hook
    ├─→ ERC1155Factory + ERC1155Instance
    └─→ UltraAlignmentVault (Fee Hub)
         ├─→ Conversion-Indexed Benefactor Accounting
         ├─→ V4 LP Position Management
         └─→ Multi-Claim Fee Distribution
```

### 1.2 Verification Steps
- [ ] Master Registry correctly tracks factory applications
- [ ] Factory instances are registered with correct vault association
- [ ] Vault correctly receives fees from all sources (ERC404 hooks, ERC1155 tithes, direct ETH)

---

## 2. MASTER REGISTRY REVIEW

**Files to Review**:
- `src/master/MasterRegistry.sol` (ERC1967 proxy wrapper)
- `src/master/interfaces/IMasterRegistry.sol` (functional interface)

### 2.1 Key Components
| Component | Purpose | Location |
|-----------|---------|----------|
| Factory Application | Submit and vote on factories | IMasterRegistry:17-34 |
| Instance Registration | Track instances with factories & vaults | IMasterRegistry:147-154 |
| Vault Tracking | Count instances per vault | IMasterRegistry:66-74 (VaultInfo struct) |

### 2.2 Verification Checklist
- [ ] **Factory Applications**: Applications require voting before acceptance
- [ ] **Instance Registration**: Each instance is associated with exactly one factory and one vault
- [ ] **Instance Count**: `VaultInfo.instanceCount` accurately reflects number of instances using that vault
- [ ] **No Access Control Issues**: Only authorized addresses can register instances/factories
- [ ] **Vault Metadata**: VaultInfo struct contains all necessary vault identification fields

### 2.3 Critical Paths to Test
1. Factory applies for acceptance
2. Application gets votes
3. Factory is accepted
4. Factory creates instances
5. Instances are registered with vault association

---

## 3. ULTRAALIGNMENTVAULT REVIEW

**File**: `src/vaults/UltraAlignmentVault.sol` (798 lines)

### 3.1 Benefactor Contribution Tracking

**Data Structures** (Lines 74-96):
```solidity
struct BenefactorContribution {
    address benefactor;
    uint128 totalETHContributed;
    bool exists;
}
mapping(address => BenefactorContribution) public benefactorContributions;
address[] public registeredBenefactors;
uint128 public totalETHCollected;
```

**Verification Points**:
- [ ] Benefactors can be registered via `registerBenefactor()`
- [ ] ETH contributions are accurately tracked
- [ ] `totalETHCollected` is sum of all benefactor contributions
- [ ] Benefactors list never duplicates entries
- [ ] No integer overflow in contribution tracking (uint128 limits)

### 3.2 Conversion-Indexed Benefactor Accounting

**Architecture** (Lines 89-91):
```solidity
LPPositionValuation.ConversionRecord[] public conversionHistory;
mapping(address => uint256[]) public benefactorConversions;
uint256 public nextConversionId;
```

**Verification Points**:
- [ ] Each conversion creates immutable `ConversionRecord`
- [ ] Benefactor stakes are frozen per-conversion (never overwritten)
- [ ] `benefactorConversions` maps benefactor → their conversion IDs only
- [ ] Conversion IDs are sequential (0, 1, 2, ...)
- [ ] No conversion record is ever modified except for fee/claim tracking

### 3.3 convertAndAddLiquidityV4() - Critical Function

**Location**: Lines 365-446

**Verification Steps**:
1. [ ] **Preconditions**: Requires minimum threshold, valid alignment target, valid V4 pool
2. [ ] **ETH Collection**: Loops over active benefactors and collects contributions
3. [ ] **Stake Freezing**: Creates new ConversionRecord with frozen stakes
   - [ ] Stake percentages calculated correctly: `(contribution * 1e18) / totalETH`
   - [ ] Percentages sum to 1e18 (100%)
4. [ ] **V4 Position Creation**:
   - [ ] Position salt is unique: `keccak256(abi.encode(conversionId, block.timestamp))`
   - [ ] amount0 and amount1 are recorded
5. [ ] **State Updates**:
   - [ ] `accumulatedFees0` and `accumulatedFees1` initialized to 0
   - [ ] Benefactor ETH contributions reset to 0 for next round
   - [ ] `nextConversionId` incremented
6. [ ] **Caller Reward**: 0.5% of swapped ETH paid to caller (gas incentive)
7. [ ] **Reentrancy**: Protected by `nonReentrant` modifier

### 3.4 recordAccumulatedFees() - Fee Collection

**Location**: Lines 435-450

**Verification Steps**:
- [ ] Takes `conversionId` parameter (targets specific conversion)
- [ ] Adds to existing fees via `+=` (allows multiple collections)
- [ ] Validates conversion ID is valid (< `conversionHistory.length`)
- [ ] O(1) operation (no loops)

### 3.5 claimBenefactorFees() - Multi-Claim Fee Distribution

**Location**: Lines 512-568 ⭐ **CRITICAL**

**Architecture**:
```solidity
function claimBenefactorFees() external nonReentrant returns (uint256 totalEthClaimed) {
    address benefactor = msg.sender;
    uint256[] memory conversions = benefactorConversions[benefactor];  // Only their conversions

    // Loop through benefactor's conversions only (O(k), k = conversions participated)
    for (uint256 i = 0; i < conversions.length; i++) {
        uint256 conversionId = conversions[i];
        ConversionRecord storage record = conversionHistory[conversionId];

        // Get frozen stake for this conversion
        ConversionBenefactorStake memory stake = record.stakes[benefactor];

        // Calculate total owed from this conversion
        uint256 totalFees = record.accumulatedFees0 + record.accumulatedFees1;
        uint256 totalOwed = (totalFees * stake.stakePercent) / 1e18;

        // Get previously claimed amount
        uint256 previouslyClaimed = record.claimedByBenefactor[benefactor];

        // Skip if no new fees
        if (totalOwed <= previouslyClaimed) continue;

        // KEY: Cumulative tracking enables multiple claims as fees accumulate
        uint256 newUnclaimedFees = totalOwed - previouslyClaimed;
        record.claimedByBenefactor[benefactor] = totalOwed;  // Update to total owed

        // Calculate split and transfer ETH
        totalEthClaimed += ethFromThisConversion;
    }
}
```

**Critical Verification Points** ⭐:
1. [ ] **Multi-Claim Support**: `claimedByBenefactor[benefactor] = totalOwed` (cumulative, not boolean)
   - This enables benefactors to claim multiple times from same conversion
2. [ ] **Loop Efficiency**: Only loops through `benefactorConversions[benefactor]` (O(k) not O(n))
   - Benefactor who participated in 50 conversions loops 50 times
   - NOT looping all 1000 benefactors or 1000 total conversions
3. [ ] **Fee Math**:
   - [ ] `totalOwed = (totalFees * stakePercent) / 1e18` correctly applies frozen percentage
   - [ ] `newUnclaimedFees = totalOwed - previouslyClaimed` gives current unclaimed amount
4. [ ] **State Correctness**:
   - [ ] Benefactor stake is immutable (frozen at conversion time)
   - [ ] Previous claims are tracked per-conversion, not globally
5. [ ] **Edge Cases**:
   - [ ] Benefactor with no conversions reverts correctly
   - [ ] Benefactor in conversion with 0 fees skips correctly
   - [ ] Benefactor who already claimed all available fees claims 0 new fees
6. [ ] **ETH Transfer**: Uses `call{}` with proper reentrancy protection
7. [ ] **Event Emission**: Emits `BenefactorFeesClaimed` with correct amount

### 3.6 getActiveBenefactors() - Helper Function

**Location**: Lines 306-327

**Verification Steps**:
- [ ] Counts benefactors with `totalETHContributed > 0`
- [ ] Builds array of active benefactors
- [ ] Excludes benefactors with zero contributions
- [ ] Returns correct count (no duplicates, no missed entries)

### 3.7 Query Functions

**Verify all return correct data**:
- [ ] `getBenefactorConversions(address)` - returns conversion IDs for benefactor
- [ ] `getConversionCount()` - returns total conversions
- [ ] `getConversionMetadata(uint256)` - returns tuple of conversion details
- [ ] `getConversionBenefactorStake(uint256, address)` - returns frozen stake
- [ ] `getBenefactorTotalUnclaimedFees(address)` - calculates unclaimed across conversions

---

## 4. ERC404 FACTORY & HOOK REVIEW

### 4.1 ERC404Factory

**File**: `src/factories/erc404/ERC404Factory.sol` (177 lines)

**Key Function**: `createInstance()` (Lines 76-143)

**Verification Checklist**:
- [ ] **Vault Association**: If vault provided, hook is created and set
- [ ] **Hook Creation**: Calls `hookFactory.createHook()` with vault address
- [ ] **Instance-Hook Mapping**: `instanceToHook[instance]` is set correctly
- [ ] **Master Registry**: Instance registered with correct vault association
- [ ] **Access Control**: Only authorized addresses can create instances
- [ ] **Pool Parameters**: Valid tick ranges and curve parameters accepted

### 4.2 UltraAlignmentV4Hook

**File**: `src/factories/erc404/hooks/UltraAlignmentV4Hook.sol` (166 lines)

**Critical Function**: `afterSwap()` (Lines 97-147)

**Verification Steps**:
1. [ ] **Tax Calculation**: `taxAmount = (swapAmount * taxRateBips) / 10000`
2. [ ] **ETH Enforcement**: Only accepts ETH/WETH pairs
   - [ ] Reverts if `token != weth && token != address(0)`
3. [ ] **Fee Collection**: Calls `vault.receiveERC404Tax()`
4. [ ] **Benefactor Tracking**: Passes `sender` as benefactor parameter
5. [ ] **Return Value**: Returns correct selector and tax amount

**Verification Checklist**:
- [ ] Hook registration on pool is enforced
- [ ] Tax rate is configurable and enforced
- [ ] Hook can be disabled if needed
- [ ] No reentrancy issues in fee collection

---

## 5. ERC1155 FACTORY & INSTANCE REVIEW

### 5.1 ERC1155Factory

**File**: `src/factories/erc1155/ERC1155Factory.sol` (156 lines)

**Verification Checklist**:
- [ ] **Vault Required**: Validates vault address before instance creation
- [ ] **Instance Creation**: Deploys ERC1155Instance with vault baked in
- [ ] **Vault Mapping**: `instanceToVault[instance]` is set correctly
- [ ] **Master Registry**: Instance registered with correct vault

### 5.2 ERC1155Instance - 20% Tithe Enforcement

**File**: `src/factories/erc1155/ERC1155Instance.sol` (758 lines)

**Critical Function**: `withdraw()` (Lines 335-356)

```solidity
function withdraw(uint256 amount) external nonReentrant {
    // ... validations ...

    uint256 taxAmount = (amount * 20) / 100;      // 20% tithe
    uint256 creatorAmount = amount - taxAmount;    // 80% to creator

    vault.receiveERC1155Tithe{value: taxAmount}(address(this));
    SafeTransferLib.safeTransferETH(creator, creatorAmount);
}
```

**Verification Steps**:
- [ ] **20% Tithe**: Correctly calculates 20% tax on withdrawal
- [ ] **Split**: Calculates 80% remainder correctly (no rounding errors)
- [ ] **Vault Call**: Passes instance address as benefactor parameter
- [ ] **Creator Transfer**: 80% goes to creator
- [ ] **No Bypass**: Creator cannot withdraw to unauthorized address
- [ ] **Reentrancy**: Protected by `nonReentrant`

---

## 6. LP POSITION VALUATION LIBRARY REVIEW

**File**: `src/libraries/LPPositionValuation.sol` (347 lines)

### 6.1 Key Structs

**ConversionBenefactorStake** (Lines 55-60):
```solidity
struct ConversionBenefactorStake {
    address benefactor;
    uint256 ethContributedThisRound;
    uint256 stakePercent;              // In 1e18 = 100%
    bool exists;
}
```

**ConversionRecord** (Lines 66-87):
```solidity
struct ConversionRecord {
    uint256 conversionId;
    uint256 timestamp;
    address[] benefactorsList;
    mapping(address => ConversionBenefactorStake) stakes;
    address pool;
    uint256 positionId;
    uint256 amount0;
    uint256 amount1;
    uint256 accumulatedFees0;
    uint256 accumulatedFees1;
    mapping(address => uint256) claimedByBenefactor;  // Cumulative claim tracking
}
```

**Verification Checklist**:
- [ ] `stakePercent` is in 1e18 format (100% = 1e18)
- [ ] `claimedByBenefactor` tracks cumulative amount claimed (not boolean)
- [ ] All fields are correctly initialized when record created
- [ ] No direct modification to immutable fields after creation

### 6.2 Helper Functions

**createStakesFromETH()** (Lines 105-146):
- [ ] Calculates correct percentages from ETH contributions
- [ ] Percentages sum to 1e18 (100%)
- [ ] Returns array for testing

**recordAccumulatedFees()** (Lines 239-247):
- [ ] Updates accumulated fees correctly
- [ ] Can be called multiple times (cumulative)

**calculateUnclaimedFees()** (Lines 155-172):
- [ ] Returns 0 if `totalOwed <= totalFeesClaimed`
- [ ] Calculates `totalOwed - totalFeesClaimed` correctly

---

## 7. TESTING VERIFICATION

**Location**: `test/vaults/UltraAlignmentVaultV1.t.sol`

### 7.1 Test Coverage
- [ ] **28 vault tests**: All passing
  - 11 multi-conversion tests
  - 4 multi-claim tests
  - 13 core functionality tests

### 7.2 Key Test Scenarios
- [ ] Benefactor registration and contribution tracking
- [ ] Frozen percentage calculation (stakePercent doesn't change)
- [ ] Multiple conversion cycles with different benefactors
- [ ] Fee accumulation and multi-claim from same conversion
- [ ] Conversion count tracking
- [ ] Unclaimed fee calculations across conversions
- [ ] Claim tracking mechanism validation

### 7.3 Test Execution
```bash
# Run all vault tests
forge test --match-path "test/vaults/UltraAlignmentVaultV1.t.sol"

# Expected result: 28 passed, 0 failed
```

---

## 8. FEE FLOW VERIFICATION

### 8.1 ERC404 Tax Flow
1. User swaps on ERC404-enabled pool
2. V4 hook triggers `afterSwap()`
3. Hook calculates tax in ETH
4. Hook calls `vault.receiveERC404Tax(sender)` ← **sender becomes benefactor**
5. Vault tracks sender contribution
6. ETH accumulates for next conversion

**Verification**:
- [ ] Hook tax percentage is correctly configured
- [ ] Vault receives ETH and credits correct benefactor
- [ ] Multiple projects' taxes accumulate in same vault

### 8.2 ERC1155 Tithe Flow
1. Creator calls `withdraw(amount)` on ERC1155Instance
2. 20% is calculated as tithe
3. Instance calls `vault.receiveERC1155Tithe{value: tithe}(address(this))`
4. Vault tracks instance address as benefactor
5. 80% goes to creator, 20% stays in vault

**Verification**:
- [ ] 20% tithe cannot be bypassed
- [ ] Vault receives correct tithe amount
- [ ] Instance address (not creator) becomes benefactor

### 8.3 Direct ETH Flow
Benefactors can send ETH directly to vault via `receiveDirect()`
- [ ] Vault accepts and tracks contribution
- [ ] Benefactor address is stored correctly

---

## 9. SECURITY REVIEW POINTS

### 9.1 Reentrancy Protection
- [ ] `claimBenefactorFees()` has `nonReentrant` modifier
- [ ] `convertAndAddLiquidityV4()` has `nonReentrant` modifier
- [ ] ERC1155 `withdraw()` has `nonReentrant` modifier
- [ ] All ETH transfers use `call{}` with proper checks

### 9.2 Access Control
- [ ] Only owner can set alignment target
- [ ] Only owner can call `recordAccumulatedFees()`
- [ ] Only creator can withdraw from ERC1155Instance
- [ ] Only registered benefactors can claim fees (implicitly validated)

### 9.3 Integer Safety
- [ ] No unchecked arithmetic that could overflow
- [ ] Percentages capped at 1e18 (100%)
- [ ] Fee calculations use proper division (no precision loss)
- [ ] uint128 used for contributions (sufficient for ETH amounts)

### 9.4 Input Validation
- [ ] Benefactor addresses validated (not zero address)
- [ ] Conversion IDs validated before access
- [ ] Amounts validated (non-zero where required)
- [ ] Pool addresses validated

### 9.5 State Consistency
- [ ] Benefactor contributions never go backwards
- [ ] Claims never exceed available fees
- [ ] Conversion records are immutable after creation
- [ ] No orphaned state or dangling references

---

## 10. CRITICAL ARCHITECTURAL DECISIONS

### 10.1 Conversion-Indexed vs. Global Index

**Decision**: Use per-conversion immutable records instead of global overwriting mapping

**Why This Matters**:
- ✅ Enables multi-conversion participation
- ✅ Frozen percentages don't drift with LP value changes
- ✅ Multi-claim support as fees accumulate
- ❌ Previous approach (singular `benefactorStakes` mapping) would overwrite

**Verify**: Old approach would have failed in multi-conversion scenarios

### 10.2 O(k) Scaling vs. O(n) Scaling

**Decision**: Benefactor claims loop through `benefactorConversions[benefactor]` (their conversions) not all conversions

**Scaling Analysis**:
- 1000 total benefactors
- 100 total conversions
- Average benefactor participates in 50 conversions
- **Claim cost**: O(50) not O(100,000)

**Verify**:
- [ ] Benefactor loop only iterates conversion IDs they participated in
- [ ] No global benefactor iterator in claim function
- [ ] No O(n) loops over total conversion count

### 10.3 Cumulative Claim Tracking

**Decision**: Track `claimedByBenefactor[benefactor]` as total amount claimed, not boolean

**Why This Matters**:
- ✅ Enables multiple claims from same conversion
- ✅ As LP earns more fees, benefactor can claim again
- ✅ Prevents double-claiming (only claim `newUnclaimedFees`)
- ❌ Previous approach would block re-claiming

**Verify**:
- [ ] `claimedByBenefactor[benefactor]` is cumulative uint256
- [ ] Each claim updates it to `totalOwed` (current total)
- [ ] New claims calculate `totalOwed - previouslyClaimed`

---

## 11. DEPLOYMENT CHECKLIST

Before deploying to mainnet:

### 11.1 Configuration
- [ ] Alignment target token address is set correctly
- [ ] V4 pool address is correct
- [ ] Minimum conversion threshold is reasonable
- [ ] Tax rate (for hooks) is configured
- [ ] Hook creation fee is set

### 11.2 Testing
- [ ] All 101 tests pass (run full test suite)
- [ ] Fork tests pass on target network (if implemented)
- [ ] Gas estimates are acceptable
- [ ] No compiler warnings

### 11.3 Audit
- [ ] This review completed
- [ ] External audit scheduled (if required)
- [ ] Known limitations documented

### 11.4 Documentation
- [ ] README updated with system overview
- [ ] API documentation complete
- [ ] Emergency procedures documented

---

## 12. KNOWN LIMITATIONS & TODOs

### 12.1 Swap Stub
**Location**: `src/vaults/UltraAlignmentVault.sol:399-416`

Current implementation returns 0. Needs:
- [ ] Router selection logic
- [ ] Swap execution (V2Router02, SwapRouter, etc.)
- [ ] Slippage protection validation
- [ ] Test on fork with real pools

### 12.2 LP Position Collection Stub
**Location**: `src/vaults/UltraAlignmentVault.sol:421-447`

Current implementation has placeholder. Needs:
- [ ] V4 PoolManager fee collection call
- [ ] Token conversion (token0 → ETH if needed)
- [ ] Updated fee tracking

See `SWAP_AND_LP_STUBS.md` for detailed implementation guide.

---

## 13. REVIEW COMPLETION CHECKLIST

**Final Verification Before Signing Off**:

- [ ] All 101 tests pass
- [ ] No compiler errors or warnings
- [ ] All critical functions reviewed
- [ ] Fee flow traced end-to-end
- [ ] Multi-conversion scenario validated
- [ ] Multi-claim mechanism verified
- [ ] O(k) scaling confirmed
- [ ] Security review completed
- [ ] Known limitations documented
- [ ] Architecture decisions understood

---

## 14. APPENDIX: File Map

| File | Lines | Purpose |
|------|-------|---------|
| `src/vaults/UltraAlignmentVault.sol` | 798 | Main vault contract (benefactor accounting, fee distribution) |
| `src/libraries/LPPositionValuation.sol` | 347 | Structs and helpers for conversion-indexed accounting |
| `src/master/MasterRegistry.sol` | 86 | ERC1967 proxy wrapper |
| `src/master/interfaces/IMasterRegistry.sol` | ~200 | Functional interface (factories, instances, vaults) |
| `src/factories/erc404/ERC404Factory.sol` | 177 | Creates ERC404 instances with vault hooks |
| `src/factories/erc404/hooks/UltraAlignmentV4Hook.sol` | 166 | V4 hook for swap tax collection |
| `src/factories/erc1155/ERC1155Factory.sol` | 156 | Creates ERC1155 instances with vault link |
| `src/factories/erc1155/ERC1155Instance.sol` | 758 | ERC1155 with 20% vault tithe enforcement |
| `test/vaults/UltraAlignmentVaultV1.t.sol` | ~800 | 28 comprehensive unit tests |

---

## 15. SIGN-OFF TEMPLATE

When review is complete, use this template:

```
MANUAL REVIEW COMPLETE
Date: [DATE]
Reviewer: [YOUR NAME]

✅ Architecture verified
✅ Fee flows traced and validated
✅ Security review passed
✅ Test coverage sufficient
✅ Known limitations documented

Notes: [ANY OBSERVATIONS]

Status: [APPROVED / APPROVED WITH NOTES / REQUIRES CHANGES]
```

---

**Good luck with your review!**
