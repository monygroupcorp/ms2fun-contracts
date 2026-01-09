# Vault Expansion - Quick Start Guide

**Status**: Phase 1 In Progress
**Last Updated**: 2025-01-06

---

## What We Built Today

### ✅ Complete

1. **IAlignmentVault Interface** (`src/interfaces/IAlignmentVault.sol`)
   - Formal interface for all vaults
   - 10 required methods
   - Full documentation with examples

2. **MockVault** (`test/mocks/MockVault.sol`)
   - Minimal test implementation
   - Accepts ETH, does nothing with it (perfect for testing!)
   - 1:1 shares (no complex yield logic)
   - Full IAlignmentVault compliance

3. **Strategy Documentation** (`VAULT_GOVERNANCE_STRATEGY.md`)
   - Detailed technical design (29 KB)
   - Architecture diagrams
   - Implementation patterns
   - Risk assessment

4. **Executive Summary** (`VAULT_EXPANSION_SUMMARY.md`)
   - High-level overview (18 KB)
   - Readiness assessment
   - Phase breakdown
   - Timeline estimates

5. **Project Tracker** (`VAULT_EXPANSION_TRACKER.md`)
   - Complete task breakdown
   - Checkbox tracking for all 23 core tasks
   - Testing strategy
   - Success metrics
   - Timeline with milestones

---

## Current Status

### Phase 1: Interface Standardization (Week 1)
```
Progress: [██░░░░] 33% (1/3 tasks complete)

✅ Task 1.1: Create IAlignmentVault.sol
✅ Task 1.3: Create MockVault.sol (BONUS - did this ahead of schedule!)
⏳ Task 1.2: Update UltraAlignmentVault
⏳ Task 1.4: Write compliance tests
⏳ Task 1.5: Documentation
```

---

## Next Steps (In Order)

### Step 1: Update UltraAlignmentVault.sol ⏳

**File**: `src/vaults/UltraAlignmentVault.sol`

**Changes Needed**:
```solidity
// 1. Add import at top
import {IAlignmentVault} from "../interfaces/IAlignmentVault.sol";

// 2. Update contract declaration
contract UltraAlignmentVault is
    ReentrancyGuard,
    Ownable,
    IUnlockCallback,
    IAlignmentVault  // ← ADD THIS
{

// 3. Add vaultType() method (around line 2000, near other config functions)
/**
 * @notice Get vault implementation type identifier
 * @dev Required by IAlignmentVault interface
 * @return Vault type identifier
 */
function vaultType() external pure override returns (string memory) {
    return "UniswapV4LP";
}

// 4. Add override keywords to interface methods
// These methods already exist, just add 'override' keyword:
function receiveHookTax(...) external payable override { ... }
function claimFees() external override returns (uint256) { ... }
function calculateClaimableAmount(address) external view override returns (uint256) { ... }
function getBenefactorContribution(address) external view override returns (uint256) { ... }
function getBenefactorShares(address) external view override returns (uint256) { ... }

// Note: accumulatedFees and totalShares are already public variables,
// so they automatically implement the interface getters (no changes needed)
```

**Estimated Time**: 15-30 minutes

**Test Command**: `forge build`

**Success Criteria**: Compiles without errors

---

### Step 2: Write VaultInterfaceCompliance.t.sol ⏳

**File**: `test/vaults/VaultInterfaceCompliance.t.sol`

**Test Structure**:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IAlignmentVault} from "../../src/interfaces/IAlignmentVault.sol";
import {UltraAlignmentVault} from "../../src/vaults/UltraAlignmentVault.sol";
import {MockVault} from "../mocks/MockVault.sol";
import {Currency} from "v4-core/types/Currency.sol";

contract VaultInterfaceComplianceTest is Test {
    UltraAlignmentVault ultraVault;
    MockVault mockVault;

    function setUp() public {
        // Deploy both vaults
        ultraVault = new UltraAlignmentVault(...);
        mockVault = new MockVault();
    }

    // Test 1: Interface compliance
    function test_UltraAlignmentVault_ImplementsInterface() public {
        IAlignmentVault vault = IAlignmentVault(address(ultraVault));
        assertEq(vault.vaultType(), "UniswapV4LP");
    }

    function test_MockVault_ImplementsInterface() public {
        IAlignmentVault vault = IAlignmentVault(address(mockVault));
        assertEq(vault.vaultType(), "MockVault");
    }

    // Test 2: All methods callable via interface
    function test_InterfaceMethods_Callable() public {
        IAlignmentVault vault = IAlignmentVault(address(mockVault));

        // Test receiveHookTax
        vault.receiveHookTax{value: 1 ether}(
            Currency.wrap(address(0)),
            1 ether,
            address(this)
        );

        // Test calculateClaimableAmount
        uint256 claimable = vault.calculateClaimableAmount(address(this));
        assertEq(claimable, 1 ether);

        // Test claimFees
        uint256 claimed = vault.claimFees();
        assertEq(claimed, 1 ether);

        // Test share queries
        assertEq(vault.getBenefactorContribution(address(this)), 1 ether);
        assertEq(vault.getBenefactorShares(address(this)), 1 ether);

        // Test vault info
        assertEq(vault.totalShares(), 1 ether);
        assertEq(vault.accumulatedFees(), 0); // After claim
    }

    // Test 3: Interface casting works
    function test_InterfaceCast_Works() public {
        // Cast to interface
        IAlignmentVault vault1 = IAlignmentVault(address(ultraVault));
        IAlignmentVault vault2 = IAlignmentVault(address(mockVault));

        // Both should have vaultType
        assertTrue(bytes(vault1.vaultType()).length > 0);
        assertTrue(bytes(vault2.vaultType()).length > 0);
    }
}
```

**Estimated Time**: 1-2 hours

**Test Command**: `forge test --match-contract VaultInterfaceComplianceTest -vvv`

**Success Criteria**: All tests pass

---

### Step 3: Create Documentation ⏳

**File**: `docs/VAULT_INTERFACE.md`

**Contents**:
- Interface method reference
- Implementation requirements
- Code examples
- Testing guidelines
- Common pitfalls

**Estimated Time**: 30-60 minutes

---

## Phase 1 Completion Checklist

Before moving to Phase 2, ensure:

- [ ] UltraAlignmentVault compiles with interface
- [ ] `forge build` succeeds
- [ ] MockVault compiles
- [ ] VaultInterfaceCompliance tests all pass
- [ ] Documentation complete
- [ ] Commit all changes to git

**Command to verify**:
```bash
forge build
forge test --match-contract VaultInterfaceComplianceTest -vvv
```

---

## After Phase 1

### Phase 2 Preview: Vault Governance

Next, you'll create:
1. **VaultApprovalGovernance.sol** - Clone FactoryApprovalGovernance
2. **MasterRegistry updates** - Add governance hooks
3. **VAULT_METADATA_STANDARD.md** - Application format

**Estimated Start**: Week 2
**Estimated Duration**: 8-12 days

---

## Project Structure

```
ms2fun-contracts/
├── src/
│   ├── interfaces/
│   │   └── IAlignmentVault.sol ✅ (DONE)
│   ├── vaults/
│   │   ├── UltraAlignmentVault.sol ⏳ (UPDATE NEEDED)
│   │   └── VaultRouter.sol (Phase 5)
│   ├── governance/
│   │   ├── FactoryApprovalGovernance.sol (existing)
│   │   └── VaultApprovalGovernance.sol (Phase 2)
│   └── master/
│       └── MasterRegistryV1.sol (Phase 2 updates)
│
├── test/
│   ├── mocks/
│   │   └── MockVault.sol ✅ (DONE)
│   ├── vaults/
│   │   ├── VaultInterfaceCompliance.t.sol ⏳ (TODO)
│   │   └── UltraAlignmentVault.t.sol (existing)
│   └── governance/
│       └── VaultApprovalGovernance.t.sol (Phase 2)
│
├── docs/
│   └── VAULT_INTERFACE.md ⏳ (TODO)
│
└── (Project Docs - Root Level)
    ├── VAULT_EXPANSION_TRACKER.md ✅ (Master checklist)
    ├── VAULT_EXPANSION_SUMMARY.md ✅ (Executive summary)
    ├── VAULT_GOVERNANCE_STRATEGY.md ✅ (Technical design)
    └── VAULT_EXPANSION_QUICKSTART.md ✅ (This file)
```

---

## Key Files Reference

| File | Purpose | Status |
|------|---------|--------|
| `src/interfaces/IAlignmentVault.sol` | Formal interface definition | ✅ Done |
| `test/mocks/MockVault.sol` | Testing implementation | ✅ Done |
| `VAULT_EXPANSION_TRACKER.md` | Complete project tracker | ✅ Done |
| `VAULT_GOVERNANCE_STRATEGY.md` | Technical architecture | ✅ Done |
| `VAULT_EXPANSION_SUMMARY.md` | Executive overview | ✅ Done |
| `src/vaults/UltraAlignmentVault.sol` | Production vault (needs update) | ⏳ Next |

---

## Testing the MockVault

### Quick Test

```solidity
// In Foundry console or test file
MockVault vault = new MockVault();

// Send 1 ETH
vault.receiveHookTax{value: 1 ether}(
    Currency.wrap(address(0)),
    1 ether,
    address(this)
);

// Check balance
assertEq(vault.calculateClaimableAmount(address(this)), 1 ether);
assertEq(vault.getBenefactorShares(address(this)), 1 ether);
assertEq(vault.vaultType(), "MockVault");

// Claim fees
uint256 claimed = vault.claimFees();
assertEq(claimed, 1 ether);
```

### MockVault Features

✅ **Accepts ETH**: Both `receiveHookTax()` and `receive()`
✅ **Tracks benefactors**: Stores contributions per address
✅ **Issues shares**: 1:1 with ETH (simple!)
✅ **Allows claims**: Proportional fee distribution
✅ **No complexity**: No V4, no swaps, no yield
✅ **Full compliance**: Implements all IAlignmentVault methods

**Perfect for**:
- Factory tests (don't need real vault logic)
- Instance tests (just need vault interface)
- Quick iterations (no complex setup)
- Integration tests (predictable behavior)

---

## Common Commands

### Build
```bash
forge build
```

### Test All
```bash
forge test
```

### Test Specific Contract
```bash
forge test --match-contract VaultInterfaceComplianceTest -vvv
```

### Test Specific Function
```bash
forge test --match-test test_MockVault_ImplementsInterface -vvvv
```

### Coverage
```bash
forge coverage
```

### Format
```bash
forge fmt
```

---

## Questions & Troubleshooting

### Q: Does updating UltraAlignmentVault break existing instances?
**A**: No! Adding `implements IAlignmentVault` and `vaultType()` are pure additions. Existing instances continue working exactly as before.

### Q: Can I use MockVault in production?
**A**: NO! MockVault is for testing only. It doesn't generate yield, just stores ETH. Use UltraAlignmentVault for production.

### Q: What if I want to test with a different vault type?
**A**: Create another mock! Clone MockVault, change `vaultType()` return value, and customize behavior.

### Q: Do all existing tests still pass?
**A**: Yes. Adding interface implementation doesn't break backward compatibility. Run `forge test` to verify.

### Q: When do I need to update factories/instances?
**A**: Phase 3 (factories) and Phase 4 (instances). Phase 1 is just the vault interface.

---

## Progress Tracking

**Current Week**: Week 1 (Phase 1)
**Current Task**: Task 1.2 - Update UltraAlignmentVault
**Overall Progress**: 4% (1/23 core tasks)

**Phase 1 Progress**: 33% (1/3 tasks)
- [x] Task 1.1: Create IAlignmentVault.sol
- [x] Task 1.3: Create MockVault.sol (bonus)
- [ ] Task 1.2: Update UltraAlignmentVault
- [ ] Task 1.4: Write compliance tests
- [ ] Task 1.5: Documentation

**Next Milestone**: Phase 1 complete (end of Week 1)

---

## Contact

**Primary Tracker**: `VAULT_EXPANSION_TRACKER.md`
**Daily Tasks**: TodoWrite list in session
**Questions**: Ask anytime!

---

## Let's Go! 🚀

**Your Next Action**: Update `src/vaults/UltraAlignmentVault.sol`

1. Add `import {IAlignmentVault}`
2. Add `IAlignmentVault` to contract declaration
3. Add `vaultType()` function
4. Add `override` keywords to interface methods
5. Run `forge build`
6. Commit changes

**Estimated Time**: 15-30 minutes
**Difficulty**: Easy (just adding interface compliance)

You got this! 💪
