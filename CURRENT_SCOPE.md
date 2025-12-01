# MS2FUN Smart Contracts - Current Implementation Scope

**Date**: December 1, 2025
**Status**: 🔧 **IN DEVELOPMENT - VAULT-HOOK REDESIGN IN PROGRESS**

---

## Executive Summary

The ms2fun smart contracts platform is undergoing a significant architectural redesign to decouple hook management from the centralized MasterRegistry. The new design moves hook ownership to individual vaults, creating a cleaner separation of concerns.

**Current Status**:
- ✅ Vault-Hook redesign implemented in core contracts
- ✅ MasterRegistry cleaned of hook tracking
- ❌ Test suite compilation errors (1 file needs fixing)
- ❌ Build not yet passing
- ⏳ Integration phases not yet completed

---

## Architecture Overview

### The Redesign: Vault-Centric Hook Management

**What Changed**: Moved from a **centralized hook registry** in MasterRegistry to **vault-owned canonical hooks**.

```
OLD ARCHITECTURE (Pre-redesign)
├── MasterRegistry (tracks everything)
│   ├── Factory registration
│   ├── Vault registration
│   ├── Hook registration ← CENTRALIZED
│   └── Instance tracking
└── Projects use hooks from registry

NEW ARCHITECTURE (Current)
├── Vault (owns its assets)
│   ├── Canonical hook (immutable)
│   ├── Benefactor tracking
│   └── Tax collection
├── MasterRegistry (only tracks vaults & instances)
│   ├── Factory registration
│   ├── Vault registration
│   └── Instance tracking
└── Projects use vault.getHook()
```

### Key Design Principles

1. **1:1 Vault-Hook Relationship**: Each vault owns exactly one immutable canonical hook
2. **Multiple Projects Per Hook**: Multiple ERC404 projects can use the same vault's hook and contribute taxes
3. **Benefactor-Centric Tracking**: Vaults track who contributed (benefactor → amount), not just the vault total
4. **Hook Optional**: Vaults can operate without hooks if creation fails (graceful degradation)
5. **No Hook Registry**: MasterRegistry no longer tracks hooks - vaults manage them

---

## Current Codebase Status

### ✅ Completed Changes

#### src/vaults/UltraAlignmentVault.sol
- Added immutable hook reference (`address public canonicalHook`)
- Added immutable hook factory reference (`address public immutable hookFactory`)
- Added hook creation in constructor via `_createCanonicalHook()`
- Added `getHook()` public accessor
- Hook creation uses try-catch for graceful failure
- Event: `event CanonicalHookCreated(address indexed hook)`

#### src/master/MasterRegistryV1.sol
- ✅ Removed hook registration state:
  - `mapping(address => IMasterRegistry.HookInfo) public hookInfo`
  - `mapping(address => bool) public registeredHooks`
  - `mapping(address => address[]) public hooksByVault`
  - `address[] public hookList`
  - `uint256 public hookRegistrationFee`
- ✅ Removed hook registration functions:
  - `registerHook()`
  - `getHookInfo()`
  - `getHookList()`
  - `getHooksByVault()`
  - `isHookRegistered()`
  - `deactivateHook()`
- ✅ Updated `registerInstance()` signature (removed `address hook` parameter)

#### src/master/interfaces/IMasterRegistry.sol
- ✅ Removed `struct HookInfo` definition
- ✅ Removed hook registry function signatures
- ✅ Removed hook-related events
- ✅ Updated `registerInstance()` signature

#### src/factories/erc404/hooks/UltraAlignmentHookFactory.sol
- ✅ Updated `createHook()` signature:
  - Removed `address projectInstance` parameter
  - Added `address wethAddr, address creator, bool isCanonical`
- ✅ Simplified hook deployment parameters

#### src/factories/erc404/hooks/UltraAlignmentV4Hook.sol
- ✅ Removed per-project binding (`address public immutable projectInstance`)
- ✅ Updated constructor signature to remove projectInstance
- ✅ Modified `afterSwap()` to use `sender` as benefactor instead of hardcoded projectInstance

#### test/mocks/MockMasterRegistry.sol
- ✅ Updated to match new MasterRegistry interface
- ✅ Removed all hook registry mock functions

### ❌ Remaining Issues

#### Compilation Error (BLOCKING)
```
test/master/MasterRegistryComprehensive.t.sol:898
Error: IMasterRegistry.HookInfo memory hookInfo = ...
       ^^^^^^^^^^^^^^^^^^^^^^^^
Identifier not found - HookInfo struct was removed
```

**Fix Required**: Remove or refactor hook-specific test cases in MasterRegistryComprehensive.t.sol

#### Incomplete Implementations (AFTER FIX)
- Phase 4 (ERC404Factory): Update `createInstance()` to retrieve hooks via `vault.getHook()`
- Test suite: Update all test files using old `registerInstance()` signature

---

## From notes.md - Requirements Status

### Completed (✅)

1. **Vault Globalization** - UltraAlignmentVault moved to `src/vaults/`
2. **LP Deployment Guard** - ERC404 setV4hook only works before bonding
3. **Tier System Simplification** - Removed redundant tier unlocking
4. **Benefactor Generalization** - Changed from "project instance" to "benefactor"
5. **General ETH Receive** - Vault has ETH receive function with benefactor tracking
6. **Master Read Function** - Implemented `getInstancesByTierAndDate()`
7. **Hook Ownership Redesign** - Moved from MasterRegistry to vault-owned
8. **Authorization Removal** - Vault accepts contributions from anyone

### Pending (⏳)

4. **ERC404 Reroll Feature** - Selective NFT reroll (not yet implemented)
5. **LP Default Infinite Range** - V4 pools default to infinite range (not yet implemented)
6. **ETH Raw Support** - Use ETH instead of WETH in V4 (not yet implemented)
7. **V2 Pool Support** - Vault accommodates V2 liquidity pools (not yet implemented)
10. **Fork Testing Framework** - Dedicated test suite for swaps (not yet implemented)
12. **V4 Hook Generalization** - Update hook endpoints after vault functions (pending compilation fix)
14. **Master Registry Hook Enforcement** - Vault manages canonical hooks (IN PROGRESS - needs build fix)

---

## Implementation Timeline

### Phase 0: Foundation (Current ❌ BLOCKED)
- [x] Design vault-centric hook architecture
- [x] Update vault contracts with hook creation
- [x] Clean up MasterRegistry
- [x] Update interfaces
- [ ] **FIX: Compilation errors** ← BLOCKER
- [ ] Verify full build passes

### Phase 1: Core Features (⏳ AFTER PHASE 0)
- [ ] Update ERC404Factory to use `vault.getHook()`
- [ ] Update all test files for new signatures
- [ ] Run full test suite
- [ ] Verify 100% of tests pass

### Phase 2: V4 Enhancements (⏳ AFTER PHASE 1)
- [ ] Implement infinite range default for pools
- [ ] Add raw ETH support to hooks
- [ ] Generalize hook receiving functions

### Phase 3: Extended Features (⏳ AFTER PHASE 2)
- [ ] Add V2 pool support
- [ ] Implement ERC404 reroll feature
- [ ] Set up fork testing framework for swaps

---

## How to Help

### If You're Fixing the Build

1. **Read the error**: `test/master/MasterRegistryComprehensive.t.sol:898` references removed `IMasterRegistry.HookInfo` struct
2. **Option A**: Delete all hook-related test cases in that file
3. **Option B**: Refactor those tests to work with new vault-owned hook model
4. **Verify**: Run `forge build` to confirm 0 errors

### If You're Continuing Implementation

1. **Phase 4**: Update `ERC404Factory.createInstance()` signature
   - Remove `address hook` parameter
   - Add `address hook = vault.getHook();`
   - Update instance registration call

2. **Tests**: Fix any test files that call old 7-param `registerInstance()`
   - Should now be 6 params (removed hook parameter)

3. **Integration**: Ensure hook creation works end-to-end
   - Vault constructor calls hook factory
   - Projects retrieve hook via `vault.getHook()`
   - Hook receives taxes from swaps

---

## File Structure

```
src/
├── master/
│   ├── MasterRegistryV1.sol ✅
│   ├── interfaces/
│   │   └── IMasterRegistry.sol ✅
│   └── upgrades/
│       └── MasterRegistryV1Upgrade.sol
├── vaults/
│   ├── UltraAlignmentVault.sol ✅
│   └── UltraAlignmentVaultV1.sol (if UUPS proxy)
├── factories/
│   ├── erc404/
│   │   ├── ERC404Factory.sol ⏳
│   │   ├── ERC404BondingInstance.sol
│   │   └── hooks/
│   │       ├── UltraAlignmentV4Hook.sol ✅
│   │       └── UltraAlignmentHookFactory.sol ✅
│   └── erc1155/
│       └── ERC1155Factory.sol
├── governance/
│   └── FactoryApprovalGovernance.sol
└── interfaces/
    └── (various)

test/
├── master/
│   ├── VaultHookRegistry.t.sol
│   └── MasterRegistryComprehensive.t.sol ❌ (compilation error)
├── factories/
│   └── (test files)
└── mocks/
    └── MockMasterRegistry.sol ✅
```

---

## Dependencies

- **Solidity**: ^0.8.20
- **Solady**: Latest (Ownable, ReentrancyGuard, proxies)
- **Uniswap V4**: v4-core
- **OpenZeppelin**: Standard contracts
- **Foundry**: Testing framework

---

## Deployment Architecture

### Single-Deployment Model

No phase 1/phase 2 split. Everything ships together:

```
1. Deploy MasterRegistryV1 (with all features)
2. Deploy FactoryApprovalGovernance
3. Deploy UltraAlignmentVault
4. Deploy UltraAlignmentHookFactory
5. Initialize all contracts
6. Ready for production
```

---

## Success Criteria

- [x] Vault owns its canonical hook
- [x] MasterRegistry cleaned of hook tracking
- [x] Interfaces updated to reflect new design
- [ ] **Build compiles with 0 errors** ← CURRENT BLOCKER
- [ ] All tests pass (100%)
- [ ] ERC404Factory uses vault.getHook()
- [ ] End-to-end workflow tested
- [ ] Production-ready

---

## Notes for Future Work

1. **Hook Creation Fee**: Currently 0.001 ETH (hardcoded in hook creation)
2. **Immutable Design**: Once set, hook address never changes
3. **Benefactor Model**: Vaults track individual contributors, not just totals
4. **Graceful Degradation**: Vault works without hook; no hard failure
5. **Multi-Project Sharing**: Multiple ERC404 projects can use same vault's hook

---

## Quick Commands

```bash
# Check build status
forge build 2>&1 | tail -20

# Run specific test
forge test --match-path "test/master/MasterRegistryComprehensive.t.sol"

# Count errors
forge build 2>&1 | grep -c "^Error"

# Full test suite
forge test
```

---

**Status**: Ready for Phase 0 completion (fix compilation error)
**Next Step**: Fix `test/master/MasterRegistryComprehensive.t.sol:898`
