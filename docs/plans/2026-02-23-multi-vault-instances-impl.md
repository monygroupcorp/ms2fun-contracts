# Multi-Vault Instances Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable project instances to hop between vaults while retaining permanent benefactor positions in all prior vaults, with alignment-target enforcement on migration.

**Architecture:** Rename `receiveInstance` → `receiveContribution` across the vault interface and all callers. Replace the single `vault` field in `IMasterRegistry.InstanceInfo` with a `vaults[]` array. Add `migrateVault()` to the registry (same-target enforcement, instance-only caller) and to all instance contracts. Add `claimAllFees()` to instances to iterate historical vault positions. Pass `masterRegistry` to instance `initialize()` via factories.

**Tech Stack:** Solidity 0.8.20, Foundry/Forge, Solady (Ownable, UUPS), IMasterRegistry (UUPS upgradeable)

---

### Task 1: Rename `receiveInstance` → `receiveContribution` in `IAlignmentVault`

**Files:**
- Modify: `src/interfaces/IAlignmentVault.sol`

**Step 1: Make the rename**

In `src/interfaces/IAlignmentVault.sol`, replace the function name and update all doc comments that reference it:

Lines 19, 55-66: Change `receiveInstance` → `receiveContribution`. Change the NatSpec `@notice` and `@dev` to reflect that contributors may be project instances OR other vaults.

```solidity
// Replace lines 50-66 with:

    // ========== Fee Reception ==========

    /**
     * @notice Receive alignment contributions from project instances, hooks, or other vaults
     * @dev Called by any registered contributor routing fees to this vault.
     *      - V4 hooks call this after collecting swap taxes
     *      - ERC1155 instances call this during creator withdrawals
     *      - Meta-vaults call this when routing their alignment cut
     *      - Must track 'benefactor' as the contributor (not msg.sender)
     *      - Must emit ContributionReceived event
     *
     * @param currency Currency of the contribution (native ETH = address(0), or ERC20)
     * @param amount Amount received (in wei or token units)
     * @param benefactor Address to credit for this contribution
     */
    function receiveContribution(
        Currency currency,
        uint256 amount,
        address benefactor
    ) external payable;
```

Also update line 72 comment: change "receiveInstance()" → "receiveContribution()".

**Step 2: Run build to verify interface compiles (will show all callers that break)**

```bash
forge build --skip "test/**" --skip "script/**" 2>&1 | grep "receiveInstance"
```

Expected: several files reported as broken (good — confirms we found all callers).

**Step 3: Commit**

```bash
git add src/interfaces/IAlignmentVault.sol
git commit -m "refactor: rename receiveInstance to receiveContribution in IAlignmentVault"
```

---

### Task 2: Update vault implementations

**Files:**
- Modify: `src/vaults/UltraAlignmentVault.sol:232`
- Modify: `src/vaults/UltraAlignmentVaultV2.sol:176`

**Step 1: Update `UltraAlignmentVault.sol`**

At line 232, rename the function declaration from `receiveInstance` to `receiveContribution`. The signature and body are unchanged — only the name changes.

```solidity
// Change line 232 from:
function receiveInstance(
// To:
function receiveContribution(
```

**Step 2: Update `UltraAlignmentVaultV2.sol`**

At line 176, same rename:

```solidity
// Change line 176 from:
function receiveInstance(Currency currency, uint256 /*amount*/, address benefactor)
// To:
function receiveContribution(Currency currency, uint256 /*amount*/, address benefactor)
```

**Step 3: Run targeted build**

```bash
forge build --skip "test/**" --skip "script/**" 2>&1 | grep "receiveInstance"
```

Expected: vault errors gone, callers still broken.

**Step 4: Commit**

```bash
git add src/vaults/UltraAlignmentVault.sol src/vaults/UltraAlignmentVaultV2.sol
git commit -m "refactor: rename receiveInstance to receiveContribution in vault implementations"
```

---

### Task 3: Update all callers of `receiveInstance`

**Files:**
- Modify: `src/factories/erc404zamm/ERC404ZAMMBondingInstance.sol:487`
- Modify: `src/factories/erc404/hooks/UltraAlignmentV4Hook.sol:130`
- Modify: `src/factories/erc1155/ERC1155Instance.sol:340`
- Modify: `src/factories/erc721/ERC721AuctionInstance.sol:277`

In each file, find `vault.receiveInstance{` or `_vault.receiveInstance{` and rename to `receiveContribution`:

**ERC404ZAMMBondingInstance.sol line 487:**
```solidity
// From:
vault.receiveInstance{value: ethReceived}(Currency.wrap(address(0)), ethReceived, address(this));
// To:
vault.receiveContribution{value: ethReceived}(Currency.wrap(address(0)), ethReceived, address(this));
```

**UltraAlignmentV4Hook.sol line 130:**
```solidity
// From:
vault.receiveInstance{value: feeAmount}(key.currency0, feeAmount, sender);
// To:
vault.receiveContribution{value: feeAmount}(key.currency0, feeAmount, sender);
```

**ERC1155Instance.sol line 340:**
```solidity
// From:
vault.receiveInstance{value: taxAmount}(Currency.wrap(address(0)), taxAmount, address(this));
// To:
vault.receiveContribution{value: taxAmount}(Currency.wrap(address(0)), taxAmount, address(this));
```

**ERC721AuctionInstance.sol line 277:**
```solidity
// From:
_vault.receiveInstance{value: vaultCut}(
// To:
_vault.receiveContribution{value: vaultCut}(
```

**Step 2: Run build — should be clean**

```bash
forge build --skip "test/**" --skip "script/**"
```

Expected: clean build with no errors.

**Step 3: Run existing vault tests to confirm nothing broken**

```bash
forge test --match-path "test/vaults/**" -v
```

Expected: all pass.

**Step 4: Commit**

```bash
git add src/factories/erc404zamm/ERC404ZAMMBondingInstance.sol \
        src/factories/erc404/hooks/UltraAlignmentV4Hook.sol \
        src/factories/erc1155/ERC1155Instance.sol \
        src/factories/erc721/ERC721AuctionInstance.sol
git commit -m "refactor: update all receiveInstance callers to receiveContribution"
```

---

### Task 4: Update `IMasterRegistry` — struct and new function signatures

**Files:**
- Modify: `src/master/interfaces/IMasterRegistry.sol`

**Step 1: Replace `InstanceInfo.vault` with `vaults[]`**

Lines 32-41 — change the struct:

```solidity
struct InstanceInfo {
    address instance;
    address factory;
    address creator;
    address[] vaults;      // Append-only. Index 0 = genesis vault. Last = active vault.
    string name;
    string metadataURI;
    bytes32 nameHash;
    uint256 registeredAt;
}
```

**Step 2: Add `VaultMigrated` event and new functions**

After line 66 (`event VaultDeactivated`), add:

```solidity
event InstanceVaultMigrated(address indexed instance, address indexed newVault, uint256 vaultIndex);
```

After line 112 (`isRegisteredInstance`), add three new function signatures:

```solidity
function migrateVault(address instance, address newVault) external;
function getInstanceVaults(address instance) external view returns (address[] memory);
function getActiveVault(address instance) external view returns (address);
```

**Step 3: Build (will break MasterRegistryV1 — expected)**

```bash
forge build --skip "test/**" --skip "script/**" 2>&1 | grep "error"
```

Expected: `MasterRegistryV1` errors about missing members.

**Step 4: Commit**

```bash
git add src/master/interfaces/IMasterRegistry.sol
git commit -m "feat: add vaults array and migrateVault to IMasterRegistry interface"
```

---

### Task 5: Update `MasterRegistryV1` — implement vault array and migration

**Files:**
- Modify: `src/master/MasterRegistryV1.sol`

**Step 1: Write the failing test first**

Add to `test/master/MasterRegistry.t.sol` — add these tests after the existing ones. First add a `MockInstance` helper contract near the top of the test file (alongside `MockFactory` and `MockVaultSimple`):

```solidity
contract MockInstance {
    address public vault;
    address public protocolTreasury;
    address private _globalMessageRegistry;
    address private _masterRegistry;
    bool private _initialized;

    function initialize(address _vault, address _treasury, address _gmr, address _mr) external {
        vault = _vault;
        protocolTreasury = _treasury;
        _globalMessageRegistry = _gmr;
        _masterRegistry = _mr;
        _initialized = true;
    }

    function getGlobalMessageRegistry() external view returns (address) {
        return _globalMessageRegistry;
    }

    // IInstanceLifecycle stub
    function instanceType() external pure returns (bytes32) {
        return keccak256("erc404");
    }

    function migrateVault(address newVault) external {
        vault = newVault;
        IMasterRegistry(_masterRegistry).migrateVault(address(this), newVault);
    }
}
```

Then add test functions:

```solidity
function _setupTargetAndVault(address token) internal returns (uint256 targetId, address vault) {
    IAlignmentRegistry.AlignmentAsset[] memory assets = new IAlignmentRegistry.AlignmentAsset[](1);
    assets[0] = IAlignmentRegistry.AlignmentAsset({
        token: token,
        symbol: "TKN",
        info: "",
        metadataURI: ""
    });
    vm.prank(daoOwner);
    targetId = alignmentRegistry.registerAlignmentTarget("Target", "", "", assets);
    vault = address(new MockVaultSimple(token));
    vm.prank(daoOwner);
    registry.registerVault(vault, alice, "Vault One", "ipfs://v1", targetId);
}

function _registerFactory() internal returns (address factory) {
    factory = address(new MockFactory(alice, daoOwner));
    vm.prank(daoOwner);
    registry.registerFactory(factory, "ERC404", "Test", "Test Factory", "ipfs://factory", new bytes32[](0));
}

function _registerInstance(address factory, address vault) internal returns (address instance) {
    MockInstance inst = new MockInstance();
    inst.initialize(vault, alice, address(0x999), address(registry));
    vm.prank(factory);
    registry.registerInstance(address(inst), factory, alice, "MyProject", "ipfs://proj", vault);
    return address(inst);
}

function test_RegisterInstance_StoresVaultArray() public {
    (uint256 targetId, address vault) = _setupTargetAndVault(dummyToken);
    address factory = _registerFactory();
    address instance = _registerInstance(factory, vault);

    address[] memory vaults = registry.getInstanceVaults(instance);
    assertEq(vaults.length, 1);
    assertEq(vaults[0], vault);
    assertEq(registry.getActiveVault(instance), vault);
}

function test_MigrateVault_AppendsToArray() public {
    (uint256 targetId, address vault1) = _setupTargetAndVault(dummyToken);
    address factory = _registerFactory();
    address instance = _registerInstance(factory, vault1);

    // Register a second vault for same target
    address vault2 = address(new MockVaultSimple(dummyToken));
    vm.prank(daoOwner);
    registry.registerVault(vault2, alice, "Vault Two", "ipfs://v2", targetId);

    // Migrate: must be called by instance itself
    vm.prank(instance);
    registry.migrateVault(instance, vault2);

    address[] memory vaults = registry.getInstanceVaults(instance);
    assertEq(vaults.length, 2);
    assertEq(vaults[0], vault1);
    assertEq(vaults[1], vault2);
    assertEq(registry.getActiveVault(instance), vault2);
}

function test_MigrateVault_RevertIfNotCalledByInstance() public {
    (, address vault1) = _setupTargetAndVault(dummyToken);
    address factory = _registerFactory();
    address instance = _registerInstance(factory, vault1);

    address vault2 = address(new MockVaultSimple(dummyToken));

    // alice cannot call migrateVault — only the instance can
    vm.prank(alice);
    vm.expectRevert("Only instance can migrate");
    registry.migrateVault(instance, vault2);
}

function test_MigrateVault_RevertIfDifferentTarget() public {
    (uint256 targetId, address vault1) = _setupTargetAndVault(dummyToken);
    address factory = _registerFactory();
    address instance = _registerInstance(factory, vault1);

    // Second vault aligned to a different token/target
    address otherToken = address(0x5678);
    IAlignmentRegistry.AlignmentAsset[] memory assets2 = new IAlignmentRegistry.AlignmentAsset[](1);
    assets2[0] = IAlignmentRegistry.AlignmentAsset({ token: otherToken, symbol: "OTH", info: "", metadataURI: "" });
    vm.prank(daoOwner);
    uint256 otherId = alignmentRegistry.registerAlignmentTarget("Other", "", "", assets2);
    address vault2 = address(new MockVaultSimple(otherToken));
    vm.prank(daoOwner);
    registry.registerVault(vault2, alice, "Other Vault", "ipfs://v2", otherId);

    vm.prank(instance);
    vm.expectRevert("Vault target mismatch");
    registry.migrateVault(instance, vault2);
}

function test_MigrateVault_RevertIfDuplicate() public {
    (, address vault1) = _setupTargetAndVault(dummyToken);
    address factory = _registerFactory();
    address instance = _registerInstance(factory, vault1);

    // Try to migrate to same vault already in array
    vm.prank(instance);
    vm.expectRevert("Vault already in array");
    registry.migrateVault(instance, vault1);
}

function test_MigrateVault_RevertIfVaultInactive() public {
    (, address vault1) = _setupTargetAndVault(dummyToken);
    address factory = _registerFactory();
    address instance = _registerInstance(factory, vault1);

    address vault2 = address(new MockVaultSimple(dummyToken));
    // vault2 is NOT registered

    vm.prank(instance);
    vm.expectRevert("New vault not active");
    registry.migrateVault(instance, vault2);
}
```

**Step 2: Run tests — confirm they fail**

```bash
forge test --match-contract MasterRegistryReworkTest --match-test "test_MigrateVault\|test_RegisterInstance_StoresVaultArray" -v
```

Expected: compilation errors or test failures — `vaults` array not yet implemented.

**Step 3: Update `MasterRegistryV1.sol`**

**3a.** In `registerInstance` (line 160-169), change struct construction to use array:

```solidity
address[] memory initialVaults = new address[](1);
initialVaults[0] = vault;

instanceInfo[instance] = IMasterRegistry.InstanceInfo({
    instance: instance,
    factory: factory,
    creator: creator,
    vaults: initialVaults,
    name: name,
    metadataURI: metadataURI,
    nameHash: nameHash,
    registeredAt: block.timestamp
});
```

**3b.** Add three new functions before the UUPS section (after `deactivateVault`):

```solidity
// ============ Instance Vault Migration ============

function migrateVault(address instance, address newVault) external override {
    require(msg.sender == instance, "Only instance can migrate");
    require(instanceInfo[instance].instance != address(0), "Instance not registered");
    require(registeredVaults[newVault] && vaultInfo[newVault].active, "New vault not active");

    address[] storage vaults = instanceInfo[instance].vaults;
    uint256 genesisTargetId = vaultInfo[vaults[0]].targetId;
    require(vaultInfo[newVault].targetId == genesisTargetId, "Vault target mismatch");

    for (uint256 i = 0; i < vaults.length; i++) {
        require(vaults[i] != newVault, "Vault already in array");
    }

    vaults.push(newVault);
    emit InstanceVaultMigrated(instance, newVault, vaults.length - 1);
}

function getInstanceVaults(address instance) external view override returns (address[] memory) {
    return instanceInfo[instance].vaults;
}

function getActiveVault(address instance) external view override returns (address) {
    address[] storage vaults = instanceInfo[instance].vaults;
    require(vaults.length > 0, "No vaults");
    return vaults[vaults.length - 1];
}
```

**Step 4: Run tests — confirm they pass**

```bash
forge test --match-contract MasterRegistryReworkTest -v
```

Expected: all pass.

**Step 5: Run full registry test suite**

```bash
forge test --match-path "test/master/**" -v
```

Expected: all pass.

**Step 6: Commit**

```bash
git add src/master/MasterRegistryV1.sol test/master/MasterRegistry.t.sol
git commit -m "feat: add vault array and migrateVault to MasterRegistryV1"
```

---

### Task 6: Update `IFactoryInstance` — add `migrateVault`

**Files:**
- Modify: `src/interfaces/IFactoryInstance.sol`

**Step 1: Add `migrateVault` to the interface**

```solidity
// After getGlobalMessageRegistry(), add:

/// @notice Migrate this instance to a new vault (must share the same alignment target)
/// @dev Only callable by instance owner. Updates active vault and appends to registry array.
/// @param newVault Address of the new registered vault to migrate to
function migrateVault(address newVault) external;

/// @notice Claim fees from all vault positions this instance has ever held
/// @dev Iterates the registry vault array and calls claimFees() on each
function claimAllFees() external;
```

**Step 2: Build check**

```bash
forge build --skip "test/**" --skip "script/**"
```

Expected: clean (these are additions to an interface, nothing implements them yet so no required-override errors from existing contracts).

**Step 3: Commit**

```bash
git add src/interfaces/IFactoryInstance.sol
git commit -m "feat: add migrateVault and claimAllFees to IFactoryInstance"
```

---

### Task 7: Update `ERC404ZAMMBondingInstance` — masterRegistry, migrateVault, claimAllFees

**Files:**
- Modify: `src/factories/erc404zamm/ERC404ZAMMBondingInstance.sol`

**Step 1: Write failing tests**

Add to `test/factories/erc404zamm/ERC404ZAMMBondingInstance.t.sol`. Find the test setup — locate where the instance is initialized. Add these tests:

```solidity
function test_MigrateVault_UpdatesActiveVault() public {
    // Deploy a second vault (same alignment target as the first)
    // Call instance.migrateVault(newVault) as instance owner
    // Assert: instance.vault() == newVault
    // Assert: registry.getActiveVault(address(instance)) == newVault
    // Assert: registry.getInstanceVaults(address(instance)).length == 2
}

function test_ClaimAllFees_IteratesAllVaults() public {
    // Migrate to a second vault so instance has two vault positions
    // Accumulate some yield in both vaults (use vm.deal or mock)
    // Call instance.claimAllFees() as owner
    // Assert: fees from both vaults were claimed (instance received ETH)
}

function test_MigrateVault_RevertIfNotOwner() public {
    address stranger = makeAddr("stranger");
    vm.prank(stranger);
    vm.expectRevert(); // Ownable: not owner
    instance.migrateVault(address(0x1234));
}
```

Run to confirm failure:
```bash
forge test --match-contract ERC404ZAMMBondingInstanceTest --match-test "test_MigrateVault\|test_ClaimAllFees" -v
```

**Step 2: Add `masterRegistry` state variable**

In `ERC404ZAMMBondingInstance.sol`, find the state variables block (around line 91-139). Add after `vault`:

```solidity
IMasterRegistry public masterRegistry;
```

Add the import at the top of the file:
```solidity
import {IMasterRegistry} from "../../master/interfaces/IMasterRegistry.sol";
```

**Step 3: Add `_masterRegistry` to `initialize()` parameters**

In the `initialize()` function signature (line 156), add as the last parameter:

```solidity
address _masterRegistry
```

In the body, after the existing vault assignment (`vault = IAlignmentVault(payable(_vault));`), add:

```solidity
masterRegistry = IMasterRegistry(_masterRegistry);
```

**Step 4: Add `migrateVault()` and `claimAllFees()` functions**

Add after `setBondingActive()` in the owner functions section:

```solidity
/// @notice Migrate to a new vault. New vault must share this instance's alignment target.
/// @dev Updates local active vault and appends to registry vault array.
function migrateVault(address newVault) external onlyOwner {
    vault = IAlignmentVault(payable(newVault));
    masterRegistry.migrateVault(address(this), newVault);
}

/// @notice Claim accumulated fees from all vault positions (current and historical).
function claimAllFees() external onlyOwner {
    address[] memory allVaults = masterRegistry.getInstanceVaults(address(this));
    for (uint256 i = 0; i < allVaults.length; i++) {
        IAlignmentVault(allVaults[i]).claimFees();
    }
}
```

**Step 5: Run tests**

```bash
forge test --match-contract ERC404ZAMMBondingInstanceTest -v
```

Expected: all pass including new migration tests.

**Step 6: Commit**

```bash
git add src/factories/erc404zamm/ERC404ZAMMBondingInstance.sol \
        test/factories/erc404zamm/ERC404ZAMMBondingInstance.t.sol
git commit -m "feat: add masterRegistry, migrateVault, claimAllFees to ERC404ZAMMBondingInstance"
```

---

### Task 8: Update `ERC404ZAMMFactory` — pass `masterRegistry` to instance initialize

**Files:**
- Modify: `src/factories/erc404zamm/ERC404ZAMMFactory.sol`

**Step 1: Update the `initialize()` call on line 161**

The factory already has `masterRegistry` as a storage variable. In the `createInstance` function, find the `ERC404ZAMMBondingInstance(payable(instance)).initialize(...)` call (line 161). Add `address(masterRegistry)` as the last argument:

```solidity
ERC404ZAMMBondingInstance(payable(instance)).initialize(
    name,
    symbol,
    maxSupply,
    liquidityReservePercent,
    curveParams,
    tierConfig,
    address(this),
    globalMessageRegistry,
    vault,
    instanceCreator,
    styleUri,
    protocolTreasury,
    bondingFeeBps,
    graduationFeeBps,
    creatorGraduationFeeBps,
    creator,
    unit,
    address(liquidityDeployer),
    address(curveComputer),
    address(masterRegistry)   // ← added last
);
```

**Step 2: Run factory tests**

```bash
forge test --match-contract ERC404ZAMMFactoryTest -v
```

Expected: all pass.

**Step 3: Commit**

```bash
git add src/factories/erc404zamm/ERC404ZAMMFactory.sol
git commit -m "feat: pass masterRegistry to ERC404ZAMMBondingInstance initialize"
```

---

### Task 9: Update `ERC404BondingInstance` — masterRegistry, migrateVault, claimAllFees

**Files:**
- Modify: `src/factories/erc404/ERC404BondingInstance.sol`

**Step 1: Write failing tests**

Add to `test/factories/erc404/ERC404BondingInstance.t.sol`:

```solidity
function test_MigrateVault_UpdatesActiveVault() public {
    // Deploy second vault (same alignment target)
    // Call instance.migrateVault(newVault) as owner
    // Assert instance.vault() == newVault
    // Assert registry.getActiveVault(address(instance)) == newVault
}

function test_ClaimAllFees_IteratesAllVaults() public {
    // Migrate to second vault
    // Accumulate yield in both
    // claimAllFees() claims from both
}
```

Run to confirm failure:
```bash
forge test --match-contract ERC404BondingInstanceTest --match-test "test_MigrateVault\|test_ClaimAllFees" -v
```

**Step 2: Add `masterRegistry` state variable**

In the state variables block, add after `vault`:

```solidity
IMasterRegistry public masterRegistry;
```

Add import:
```solidity
import {IMasterRegistry} from "../../master/interfaces/IMasterRegistry.sol";
```

**Step 3: Add `_masterRegistry` to `initialize()` parameters**

In `initialize()` (line 187), add as the last parameter:

```solidity
address _masterRegistry
```

In the body, after `vault = IAlignmentVault(payable(_vault));`, add:

```solidity
masterRegistry = IMasterRegistry(_masterRegistry);
```

**Step 4: Add `migrateVault()` and `claimAllFees()`**

Add in the owner functions section:

```solidity
/// @notice Migrate to a new vault. New vault must share this instance's alignment target.
function migrateVault(address newVault) external onlyOwner {
    vault = IAlignmentVault(payable(newVault));
    masterRegistry.migrateVault(address(this), newVault);
}

/// @notice Claim accumulated fees from all vault positions (current and historical).
function claimAllFees() external onlyOwner {
    address[] memory allVaults = masterRegistry.getInstanceVaults(address(this));
    for (uint256 i = 0; i < allVaults.length; i++) {
        IAlignmentVault(allVaults[i]).claimFees();
    }
}
```

**Step 5: Run tests**

```bash
forge test --match-contract ERC404BondingInstanceTest -v
```

Expected: all pass.

**Step 6: Commit**

```bash
git add src/factories/erc404/ERC404BondingInstance.sol \
        test/factories/erc404/ERC404BondingInstance.t.sol
git commit -m "feat: add masterRegistry, migrateVault, claimAllFees to ERC404BondingInstance"
```

---

### Task 10: Update `ERC404Factory` — pass `masterRegistry` to instance initialize

**Files:**
- Modify: `src/factories/erc404/ERC404Factory.sol`

**Step 1: Update the `initialize()` call**

The factory already has `masterRegistry`. In `createInstance`, find `ERC404BondingInstance(payable(instance)).initialize(...)` (around line 258). Add `address(masterRegistry)` as the last argument (after `address(curveComputer)`):

```solidity
ERC404BondingInstance(payable(instance)).initialize(
    name,
    symbol,
    maxSupply,
    liquidityReservePercent,
    curveParams,
    tierConfig,
    v4PoolManager,
    hook,
    weth,
    address(this),
    globalMessageRegistry,
    vault,
    instanceCreator,
    styleUri,
    protocolTreasury,
    bondingFeeBps,
    graduationFeeBps,
    polBps,
    creator,
    creatorGraduationFeeBps,
    profile.poolFee,
    profile.tickSpacing,
    unit,
    address(stakingModule),
    address(liquidityDeployer),
    address(curveComputer),
    address(masterRegistry)   // ← added last
);
```

**Step 2: Run factory tests**

```bash
forge test --match-contract ERC404FactoryTest -v
```

Expected: all pass.

**Step 3: Commit**

```bash
git add src/factories/erc404/ERC404Factory.sol
git commit -m "feat: pass masterRegistry to ERC404BondingInstance initialize"
```

---

### Task 11: Update `ERC1155Instance` and `ERC721AuctionInstance`

**Files:**
- Read first: `src/factories/erc1155/ERC1155Instance.sol`
- Read first: `src/factories/erc721/ERC721AuctionInstance.sol`

**Steps:** Follow the same pattern as Tasks 7-10:

1. Read each instance file to find the `vault` / `_vault` state variable and `initialize()` params
2. Add `masterRegistry` storage and import
3. Add `_masterRegistry` to `initialize()` as last param; assign in body
4. Add `migrateVault()` and `claimAllFees()` functions (identical logic to ERC404 instances, using whichever vault variable name is used — `vault` vs `_vault`)
5. Update the corresponding factory to pass `address(masterRegistry)` as last arg to `initialize()`
6. Run tests: `forge test --match-contract ERC1155InstanceTest -v` and `forge test --match-contract ERC721AuctionInstanceTest -v`
7. Commit each instance + factory pair separately

---

### Task 12: Fix tests that access `instanceInfo.vault` (now `instanceInfo.vaults`)

**Files:**
- Search: `forge grep` for `.vault` on `InstanceInfo` results across all test files

**Step 1: Find all test access of the old `.vault` field**

```bash
grep -rn "\.vault\b" test/ | grep -i "instance"
```

**Step 2: Update each occurrence**

Any test that accesses `registry.getInstanceInfo(addr).vault` should change to either:
- `registry.getActiveVault(addr)` — for the current active vault
- `registry.getInstanceVaults(addr)[0]` — for the genesis vault

**Step 3: Run full test suite**

```bash
forge test -v 2>&1 | tail -20
```

Expected: all ~1009 tests pass.

**Step 4: Commit**

```bash
git add test/
git commit -m "fix: update tests to use vaults array instead of vault field on InstanceInfo"
```

---

### Task 13: Final verification

**Step 1: Full build**

```bash
forge build --skip "test/**" --skip "script/**"
```

Expected: clean.

**Step 2: Full test suite**

```bash
forge test
```

Expected: all tests pass, no regressions.

**Step 3: Verify rename is complete**

```bash
grep -rn "receiveInstance" src/
```

Expected: zero results (only doc comments if any remain — update those too).

**Step 4: Final commit**

```bash
git add .
git commit -m "chore: final cleanup — verify receiveInstance rename complete"
```
