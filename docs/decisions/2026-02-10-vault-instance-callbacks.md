# Vault-to-Instance Callback Pattern Design Decision

## Status: Proposed

## Context

Communication in the protocol is currently one-directional:

```
Instance -> Vault (via receiveHookTax, claimFees)
```

The vault never calls back into instances. Instances push contributions and pull fees. The vault is passive from the instance's perspective.

## Problem

Future vault types — particularly DAO vaults — need reverse communication:

- **Governance decisions:** "The DAO voted to change the tax rate from 1% to 2%"
- **Emergency actions:** "Pause trading on all instances — vulnerability discovered"
- **Vault migration:** "This vault is being deprecated, instances should migrate"
- **Parameter updates:** "New staking requirements are in effect"

Without vault-to-instance communication, governance decisions are advisory only.

## Options

### Option A: Callback Interface (IVaultAwareInstance)

```solidity
interface IVaultAwareInstance {
    function onVaultAction(bytes32 actionType, bytes calldata data) external;
}
```

Vault calls `instance.onVaultAction(ACTION_CHANGE_TAX_RATE, abi.encode(200))` on each registered instance.

**Pros:**
- Direct, synchronous, on-chain enforcement
- Type-safe — instances know exactly what action was taken
- Atomic — action and enforcement happen in same transaction

**Cons:**
- Gas prohibitive at scale. 1000 instances x ~30k gas per call = 30M gas. May exceed block gas limit.
- Requires all instances to implement the interface — breaking change
- Vault must track all instances (storage overhead)
- Reentrancy risk — vault calls into instance which might call back into vault

### Option B: Event-Based (Off-Chain Relay)

Vault emits events. Off-chain relayer watches events and calls instances.

**Pros:**
- No gas scaling problem — relayer pays gas per instance
- No on-chain coupling between vault and instances
- Works with any number of instances
- Can batch and retry failed deliveries

**Cons:**
- Trust assumption: Who runs the relayer? What if it's offline?
- Latency: Actions are not immediate
- Signature scheme needed to prove the action is legitimate
- Instances must verify the relayer's authority

### Option C: Pull-Based

Instances periodically check the vault for pending actions:

```solidity
function pendingAction() external view returns (bytes32 actionType, bytes memory data, uint256 nonce);
```

**Pros:**
- No callback complexity — instances pull at their own pace
- No gas scaling problem on the vault side
- No off-chain infrastructure needed
- Natural integration point: check before claimFees()

**Cons:**
- Stale state between checks — if no one claims fees, actions are never processed
- Only works for the latest action (or needs a queue)
- Instance must process actions even if user just wants to claim fees
- No guarantee actions are ever processed

## Scale Concern

The protocol is designed for many projects per vault. A successful vault could easily have 100-1000 instances. At that scale:

- **Option A** is gas-prohibitive (30M+ gas for 1000 callbacks)
- **Option B** scales well but needs infrastructure
- **Option C** scales well but has delivery guarantee issues

## Recommendation

**Hybrid: Pull-based for enforcement, Events for notification.**

1. **Primary mechanism — Pull-based:** Add a simple `currentPolicy()` view function to `IAlignmentVault` that returns the vault's current parameters (tax rate, staking requirements, etc.). Instances check this when performing key actions (claiming, staking). No callback needed — the vault is the source of truth and instances read it.

2. **Notification layer — Events:** Vault emits `VaultPolicyUpdated(bytes32 key, bytes value)` events. Frontends watch these and prompt users to interact with their instances (which will then pull the new policy). No relayer needed — the frontend IS the relayer.

This avoids:
- Gas scaling problems (no on-chain iteration)
- Off-chain infrastructure (frontend watches events)
- Stale state (instances read current policy on every interaction)
- Breaking changes (instances that don't check policy still work)

The key insight: most vault-to-instance communication is really "the vault's parameters changed, and instances should respect the new parameters." This is a read, not a callback.

For truly imperative actions (emergency pause), the vault owner can call a registry-level pause that frontends respect, without needing to touch every instance contract.

## Interface Changes Required

Consider adding to `IAlignmentVault`:

```solidity
function currentPolicy() external view returns (bytes memory);

event VaultPolicyUpdated(bytes32 indexed key, bytes value);
```

This is a lightweight addition that enables pull-based policy enforcement without callbacks.
