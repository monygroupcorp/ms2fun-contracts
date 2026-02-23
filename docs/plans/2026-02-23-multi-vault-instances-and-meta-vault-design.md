# Multi-Vault Instances & Meta-Vault Design

**Date:** 2026-02-23
**Status:** Approved for implementation

## Overview

Two related improvements that make the protocol future-proof as vault quality improves over time:

1. **Multi-vault instances** — project instances can migrate to better vaults while retaining permanent benefactor positions in all prior vaults
2. **Meta-vault pattern** — a new vault type where ETH is deployed into whitelisted yield strategies, with alignment enforced at harvest time (20% of yield flows to a registered inner UltraAlignmentVault)

These changes collectively allow instances to "vault hop" to superior yield vehicles without losing historical positions, and allow the protocol to define alignment in terms of outcome (yield routing) rather than mechanism (direct LP provision).

---

## Part 1: Multi-Vault Instances

### Current State

`InstanceInfo` in `MasterRegistryV1` holds a single `address vault` field, described as "immutably bound." Vault migration is not possible.

### Changes

#### MasterRegistryV1 — InstanceInfo

Replace the single `vault` field with:

```solidity
struct InstanceInfo {
    address instance;
    address factory;
    address creator;
    address[] vaults;        // Append-only. Index 0 = genesis vault. Last = active vault.
    string name;
    string metadataURI;
    bytes32 nameHash;
    uint256 registeredAt;
}
```

Add a view helper:

```solidity
function getInstanceVaults(address instance) external view returns (address[] memory);
function getActiveVault(address instance) external view returns (address);
```

`getActiveVault` returns `vaults[vaults.length - 1]`.

#### MasterRegistryV1 — migrateVault

New registry function callable only by the instance contract itself (`msg.sender == instance`):

```solidity
function migrateVault(address instance, address newVault) external;
```

Validation:
1. `msg.sender == instance` — only the instance contract can call this
2. Instance is registered
3. `newVault` is registered and active in this registry
4. `newVault`'s `targetId` matches the genesis vault's `targetId` — alignment target is immutable across hops
5. `newVault` is not already in `instance.vaults`

On success: appends `newVault` to `instance.vaults`. Future `receiveContribution` calls from the instance are routed to `newVault`.

#### IAlignmentVault — rename receiveInstance

`receiveInstance` is renamed `receiveContribution` to reflect that the contributor may be a project instance or another vault (e.g., a meta-vault routing its 20% alignment cut). The signature is otherwise unchanged:

```solidity
function receiveContribution(
    address contributor,
    uint256 amount
) external payable;
```

#### IFactoryInstance — migrateVault

Add to the standard instance interface:

```solidity
function migrateVault(address newVault) external; // onlyOwner
```

Implementation in instance contracts:

```solidity
function migrateVault(address newVault) external onlyOwner {
    // Optional: sweep pending tax, claim fees from current vault before hop
    masterRegistry.migrateVault(address(this), newVault);
}
```

#### Instance contracts — claimAllFees

Add fee collection across all benefactor positions:

```solidity
function claimAllFees() external onlyOwner {
    address[] memory allVaults = masterRegistry.getInstanceVaults(address(this));
    for (uint256 i = 0; i < allVaults.length; i++) {
        IAlignmentVault(allVaults[i]).claimFees();
    }
}
```

Old vaults with exhausted positions simply return 0 — no special handling required.

### Invariants

- An instance's alignment target never changes. `vaults[0].targetId` is the canonical target for all future vaults.
- An instance cannot remove itself from a vault. Positions are permanent until naturally exhausted.
- Only the instance contract (not an EOA, not the factory) can trigger migration — ensuring ownership transfer via `Ownable` is respected.

---

## Part 2: Meta-Vault Pattern

### Concept

A **MetaAlignmentVault** is a vault where:
- ETH from project tithes is deployed into a curated set of whitelisted yield strategies
- When yield is harvested from those strategies back into the vault treasury, **20% is automatically routed to a registered inner UltraAlignmentVault**
- The remaining 80% accumulates as claimable yield for benefactors

Alignment is enforced at harvest time, not at deposit time. The constraint is on the yield return path, not the investment path.

### Structure

```solidity
contract MetaAlignmentVault is IAlignmentVault {
    address public innerAlignmentVault;     // Registered UltraAlignmentVault (same targetId)
    address[] public whitelistedStrategies; // Approved protocol contracts
    uint256 public alignmentCutBps = 2000;  // 20% — governance-adjustable with floor

    mapping(address => uint256) public deployedCapital; // Per strategy principal tracking

    // Harvest: pulls yield from a strategy, enforces alignment cut
    function harvest(address strategy) external;
}
```

### Whitelisted Strategies

Managers can only call approved strategy contracts. Strategy interactions are constrained to a defined interface (e.g., `IStrategy.deposit()`, `IStrategy.withdraw()`). The whitelist is DAO-governed via the same Timelock that governs other registry changes.

### Harvest Enforcement

When yield returns from a strategy:

```solidity
function harvest(address strategy) external {
    require(isWhitelisted[strategy], "Strategy not whitelisted");
    uint256 returned = IStrategy(strategy).withdraw();
    uint256 principal = deployedCapital[strategy];
    uint256 yield = returned > principal ? returned - principal : 0;

    uint256 alignmentCut = (yield * alignmentCutBps) / 10000;
    IAlignmentVault(innerAlignmentVault).receiveContribution{value: alignmentCut}(
        address(this),
        alignmentCut
    );

    // Remaining yield distributed to benefactors via MasterChef accumulator
    _distributeYield(returned - alignmentCut);
}
```

### Registration

The meta-vault is registered in `MasterRegistryV1` like any other vault:
- Must expose `alignmentToken()` — returns the inner vault's alignment token
- `targetId` must match the inner vault's `targetId`
- The inner UltraAlignmentVault is **separately registered** as its own `VaultInfo` entry
- The meta-vault is a **benefactor of the inner vault** — it calls `receiveContribution` on it, routing the 20% alignment cut

### Draining Protection (Future)

A strategy whitelist prevents arbitrary outflows. Future iterations may add:
- Per-strategy capital caps
- Timelock on new strategy additions
- Market-enforced alignment via benefactor mobility (projects switching to better-acting vaults)

---

## What Does NOT Change

- `VaultInfo` struct — no changes needed. `vaultType()` on the contract itself is sufficient for classification.
- `AlignmentRegistryV1` — alignment targets are unchanged.
- `IInstanceLifecycle` — state machine is unchanged.
- Factory registration flow — unchanged.
- Benefactor sharing/yield math inside vaults — unchanged per vault type.

---

## Migration Path for Existing Instances

All current instances (ERC404BondingInstance, ERC404ZAMMBondingInstance) are pre-production. The `vault` field in `InstanceInfo` can be replaced with `vaults[]` without any migration concern. All instance contracts receive `migrateVault()` and `claimAllFees()` as part of this change.

---

## Summary of Affected Files

| File | Change |
|------|--------|
| `src/interfaces/IAlignmentVault.sol` | Rename `receiveInstance` → `receiveContribution` |
| `src/interfaces/IFactoryInstance.sol` | Add `migrateVault(address)` |
| `src/master/MasterRegistryV1.sol` | `InstanceInfo.vault` → `vaults[]`, add `migrateVault()`, `getInstanceVaults()`, `getActiveVault()` |
| `src/vaults/UltraAlignmentVault.sol` | Rename function, update internal calls |
| `src/vaults/UltraAlignmentVaultV2.sol` | Rename function, update internal calls |
| `src/factories/erc404/ERC404BondingInstance.sol` | Add `migrateVault()`, `claimAllFees()`, update vault routing |
| `src/factories/erc404zamm/ERC404ZAMMBondingInstance.sol` | Add `migrateVault()`, `claimAllFees()`, update vault routing |
| `src/vaults/MetaAlignmentVault.sol` | New contract |
| `src/interfaces/IMetaAlignmentVault.sol` | New interface (optional) |
| `test/**` | Update all vault-related tests |
