# RESOLVED: Critical Test Coverage Gap - Hook Deployment

**Date:** 2024-01-14
**Severity:** HIGH
**Status:** RESOLVED
**Discovered:** Production deployment failure
**Fixed:** 2024-01-14

---

## Executive Summary

Hook deployment was failing in production because Uniswap v4 requires hooks to be deployed at addresses with specific permission bits encoded in the address. Our test suite completely bypassed this validation, meaning the bug was invisible until production deployment.

**Root cause:** All hook tests used mock contracts that stripped out `Hooks.validateHookPermissions()`, and no integration test ever successfully deployed a real hook through the factory.

### Resolution

1. **Added CREATE2 support** to `UltraAlignmentHookFactory.createHook()` with a `bytes32 salt` parameter
2. **Created `HookAddressMiner` library** (`test/fork/helpers/HookAddressMiner.sol`) that mines salts producing addresses with EXACTLY the required permission bits
3. **Added comprehensive test suites:**
   - `test/fork/v4/V4HookDeployment.t.sol` - 6 fork tests for real deployment
   - `test/unit/HookAddressMiner.t.sol` - 13 unit tests for salt mining logic

**Key insight:** Uniswap v4's `validateHookPermissions()` requires an EXACT match - the address must have ONLY the declared permission bits set (0x44), and NO other hook flags (0x3FBB must be clear).

---

## The Bug (Historical)

### What Happens in Production

```solidity
// UltraAlignmentV4Hook.sol constructor (lines 62-80)
Hooks.validateHookPermissions(
    IHooks(address(this)),
    Hooks.Permissions({
        beforeInitialize: false,
        afterInitialize: false,
        beforeAddLiquidity: false,
        afterAddLiquidity: false,
        beforeRemoveLiquidity: false,
        afterRemoveLiquidity: false,
        beforeSwap: false,
        afterSwap: true,              // WE NEED THIS
        beforeDonate: false,
        afterDonate: false,
        beforeSwapReturnDelta: false,
        afterSwapReturnDelta: true,   // WE NEED THIS
        afterAddLiquidityReturnDelta: false,
        afterRemoveLiquidityReturnDelta: false
    })
);
```

This call **validates that the deployed contract address has the correct permission bits**. For our hook:
- `afterSwap` = bit 6 (0x40)
- `afterSwapReturnDelta` = bit 2 (0x04)
- Required address suffix: `0x44` (or similar valid encoding)

When deploying with `new UltraAlignmentV4Hook(...)`, the address is unpredictable and almost certainly won't have the correct bits, causing `validateHookPermissions()` to revert.

### Why Tests Didn't Catch It

| Test File | Problem |
|-----------|---------|
| `UltraAlignmentHookFactory.t.sol` | Never calls `createHook()` successfully - only tests reverts and admin functions |
| `ERC404Factory.t.sol` | All 19 tests use `vault = address(0)`, skipping hook creation entirely |
| `UltraAlignmentV4Hook.t.sol` | Uses `TestableHook` mock that removes `validateHookPermissions()` |
| `V4HookTaxation.t.sol` | Uses `MockTaxHook` + `vm.etch()` to fake a valid address |

---

## Test Coverage Matrix (Updated)

| Deployment Path | Tested? | Test File |
|-----------------|---------|-----------|
| `HookFactory.createHook()` success | ✅ YES | `V4HookDeployment.t.sol` |
| `ERC404Factory.createInstance()` with vault | ⚠️ Partial | Requires valid salt from frontend |
| Real `UltraAlignmentV4Hook` deployment | ✅ YES | `V4HookDeployment.t.sol` |
| `Hooks.validateHookPermissions()` pass | ✅ YES | `V4HookDeployment.t.sol` |
| CREATE2 salt computation | ✅ YES | `HookAddressMiner.t.sol` |
| Hook → Pool initialization | ✅ YES | `V4HookDeployment.t.sol` |
| Salt mining (exact flag matching) | ✅ YES | `HookAddressMiner.t.sol` (13 tests) |

---

## Proposed Test Suite: Hook Deployment Integration Tests

### New Test File: `test/fork/v4/V4HookDeployment.t.sol`

This suite will test the **actual deployment path** that fails in production.

### Test Categories

#### 1. CREATE2 Salt Mining Tests

```solidity
/// @notice Verify we can compute a valid salt for hook deployment
function test_computeValidSalt_forHookPermissions() public {
    // Given: Hook factory and deployment parameters
    // When: We mine for a valid salt
    // Then: The resulting address has correct permission bits
}

/// @notice Verify invalid salts are rejected
function test_invalidSalt_causesDeploymentRevert() public {
    // Given: A salt that produces an invalid address
    // When: We try to deploy
    // Then: Hooks.validateHookPermissions() reverts
}
```

#### 2. Factory Integration Tests

```solidity
/// @notice Test successful hook creation through factory with valid salt
function test_hookFactory_createHook_withValidSalt_succeeds() public {
    // Given: A pre-computed valid salt
    // When: We call createHook() with that salt
    // Then: Hook deploys successfully at expected address
}

/// @notice Test hook creation through ERC404Factory with vault
function test_erc404Factory_createInstance_withVault_deploysHook() public {
    // Given: Valid instance params + vault address + valid hook salt
    // When: We call createInstance()
    // Then: Both instance and hook are deployed, hook has valid address
}
```

#### 3. End-to-End Integration Tests

```solidity
/// @notice Full flow: Deploy hook → Create pool → Execute swap → Verify tax
function test_endToEnd_hookDeployment_poolCreation_swapTaxation() public {
    // Given: Deployed hook through factory
    // When: We create a pool with the hook and swap
    // Then: Tax is collected and sent to vault
}
```

#### 4. Address Validation Tests

```solidity
/// @notice Verify hook address encodes correct permissions
function test_hookAddress_encodesCorrectPermissions() public {
    // Given: Deployed hook
    // When: We check the address bits
    // Then: afterSwap (0x40) and afterSwapReturnDelta (0x04) are set
}

/// @notice Verify Hooks.validateHookPermissions passes for deployed hook
function test_validateHookPermissions_passesForDeployedHook() public {
    // Given: Hook deployed at valid address
    // When: We call validateHookPermissions
    // Then: No revert (validation passes)
}
```

---

## Implementation Plan

### Phase 1: Salt Mining Utility

Create a helper contract/library that can compute valid CREATE2 salts:

```solidity
// test/fork/helpers/HookAddressMiner.sol

library HookAddressMiner {
    /// @notice Find a salt that produces a hook address with required permission bits
    /// @param deployer The CREATE2 deployer (factory address)
    /// @param initCodeHash The keccak256 of the hook's creation code
    /// @param requiredFlags The permission bits that must be set in the address
    /// @return salt A valid salt, or revert if none found in reasonable iterations
    function mineSalt(
        address deployer,
        bytes32 initCodeHash,
        uint160 requiredFlags
    ) internal pure returns (bytes32 salt) {
        for (uint256 i = 0; i < 100_000; i++) {
            salt = bytes32(i);
            address predicted = _computeAddress(deployer, salt, initCodeHash);
            if (_hasRequiredFlags(predicted, requiredFlags)) {
                return salt;
            }
        }
        revert("HookAddressMiner: No valid salt found");
    }

    function _computeAddress(
        address deployer,
        bytes32 salt,
        bytes32 initCodeHash
    ) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            deployer,
            salt,
            initCodeHash
        )))));
    }

    function _hasRequiredFlags(address addr, uint160 flags) internal pure returns (bool) {
        return uint160(addr) & flags == flags;
    }
}
```

### Phase 2: Integration Test Implementation

```solidity
// test/fork/v4/V4HookDeployment.t.sol

contract V4HookDeploymentTest is ForkTestBase {
    using HookAddressMiner for *;

    UltraAlignmentHookFactory hookFactory;
    UltraAlignmentVault vault;

    // Required hook flags: afterSwap (0x40) + afterSwapReturnDelta (0x04)
    uint160 constant REQUIRED_HOOK_FLAGS = 0x44;

    function setUp() public {
        loadAddresses();

        // Deploy real infrastructure
        vault = new UltraAlignmentVault(...);
        hookFactory = new UltraAlignmentHookFactory(address(0), WETH);
    }

    function test_realHookDeployment_throughFactory() public {
        // Compute init code hash for the hook
        bytes memory initCode = abi.encodePacked(
            type(UltraAlignmentV4Hook).creationCode,
            abi.encode(poolManager, vault, WETH, address(this))
        );
        bytes32 initCodeHash = keccak256(initCode);

        // Mine a valid salt
        bytes32 salt = HookAddressMiner.mineSalt(
            address(hookFactory),
            initCodeHash,
            REQUIRED_HOOK_FLAGS
        );

        // Deploy through factory - THIS IS WHAT FAILS IN PRODUCTION
        address hook = hookFactory.createHook{value: 0.001 ether}(
            UNISWAP_V4_POOL_MANAGER,
            address(vault),
            WETH,
            address(this),
            true,
            salt
        );

        // Verify deployment succeeded
        assertTrue(hook != address(0), "Hook should deploy");
        assertTrue(hook.code.length > 0, "Hook should have code");

        // Verify address has correct flags
        assertEq(
            uint160(hook) & REQUIRED_HOOK_FLAGS,
            REQUIRED_HOOK_FLAGS,
            "Hook address should have required permission bits"
        );
    }
}
```

### Phase 3: Add to CI/CD

Ensure these tests run on every PR:

```yaml
# In CI config
- name: Run Hook Deployment Tests
  run: |
    forge test \
      --match-path "test/fork/v4/V4HookDeployment.t.sol" \
      --fork-url $ETH_RPC_URL \
      -vvv
```

---

## Test File Structure

```
test/
├── fork/
│   ├── WARNING_REPORT_HOOK.md          # This document
│   ├── helpers/
│   │   ├── ForkTestBase.sol
│   │   ├── UniswapHelpers.sol
│   │   └── HookAddressMiner.sol        # Salt mining utility
│   └── v4/
│       ├── V4FeeCollection.t.sol
│       ├── V4HookTaxation.t.sol
│       ├── V4PoolInitialization.t.sol
│       ├── V4PositionCreation.t.sol
│       ├── V4PositionQuery.t.sol
│       ├── V4SwapRouting.t.sol
│       └── V4HookDeployment.t.sol      # Integration tests (6 tests)
└── unit/
    └── HookAddressMiner.t.sol          # Unit tests (13 tests)
```

### Running the Tests

```bash
# Fork tests (requires RPC URL)
forge test --match-path "test/fork/v4/V4HookDeployment.t.sol" --fork-url $ETH_RPC_URL -vvv

# Unit tests (no fork required)
forge test --match-path "test/unit/HookAddressMiner.t.sol" -vvv
```

---

## Acceptance Criteria

All tests now pass:

- [x] `test_computeValidSalt_producesAddressWithCorrectFlags` - Can mine valid salts
- [x] `test_arbitraryAddress_failsValidation` - Demonstrates why regular CREATE fails
- [x] `test_hookFactory_createHook_withValidSalt_succeeds` - Factory deploys real hook
- [x] `test_hookFactory_createHook_withInvalidSalt_reverts` - Invalid salts rejected
- [x] `test_deployedHook_canInitializePool` - Hook can initialize V4 pools
- [x] `test_hookAddress_passesValidateHookPermissions` - Address validation passes

**Additional unit tests (13 tests in `test/unit/HookAddressMiner.t.sol`):**
- [x] Flag constant verification
- [x] CREATE2 address computation
- [x] Exact flag matching (required AND forbidden)
- [x] Salt mining for valid addresses

---

## Lessons Learned

1. **Mock contracts hide integration bugs.** Tests passed because mocks removed the validation that fails in production.

2. **Test the deployment path, not just the behavior.** We tested hook behavior extensively but never tested whether hooks could actually be deployed.

3. **Integration tests are not optional.** Unit tests with mocks are insufficient for contracts that interact with external protocols.

4. **Address-dependent behavior requires address-aware tests.** Uniswap v4's hook system encodes permissions in addresses - tests must account for this.

---

## References

- [Uniswap v4 Hook Documentation](https://docs.uniswap.org/contracts/v4/concepts/hooks)
- [CREATE2 Address Derivation](https://eips.ethereum.org/EIPS/eip-1014)
- [Hooks.sol - validateHookPermissions](https://github.com/Uniswap/v4-core/blob/main/src/libraries/Hooks.sol)
- Related files in this repo:
  - `src/factories/erc404/hooks/UltraAlignmentHookFactory.sol`
  - `src/factories/erc404/hooks/UltraAlignmentV4Hook.sol`
  - `src/factories/erc404/ERC404Factory.sol`
