# Vault-Factory Compatibility Validation Design Decision

## Status: Proposed

## Context

Factories currently accept any address as a vault with minimal validation. In ERC404Factory and ERC1155Factory, the only check is `vault.code.length > 0` — confirming it's a contract, nothing more.

The `IAlignmentVault` interface now includes `supportsCapability(bytes32)` which can be used to query vault features.

## Problem

Not all vault + factory combinations make sense:

| Factory | Vault Type | Makes Sense? | Why |
|---|---|---|---|
| ERC404 | UniswapV4LP | Yes | Yield from LP fees, staking for holders |
| ERC404 | DAO Vault | Maybe | Shares = votes, but the instance contract is the benefactor, not individual holders |
| ERC1155 | UniswapV4LP | Yes | Artist gets yield from LP fees |
| ERC1155 | DAO Vault | No | Edition minting has no governance relationship |
| ERC1155 | Treasury | Maybe | Simple ETH holding, creator claims |

The risk isn't catastrophic — a bad pairing just means the vault does nothing useful for that project. But it's confusing UX and wasted gas.

## Options

### Option A: Vault-Side acceptsFactoryType(bytes32)

Vault declares which factory types it's compatible with. Factory calls `vault.acceptsFactoryType("ERC404")` before deploying.

**Pros:**
- Vault controls its own compatibility
- Clear, explicit validation

**Cons:**
- Vault must know about all factory types — coupling in the wrong direction
- New factory types require vault upgrades
- Rigid — doesn't adapt to new factory types

### Option B: Registry-Level Compatibility Matrix

MasterRegistry stores a mapping of vault type to approved factory types. Governance manages the matrix.

**Pros:**
- Centralized, governable
- Factories and vaults don't need to know about each other

**Cons:**
- Governance overhead for every new pairing
- Slows permissionless innovation
- Another contract to maintain and govern

### Option C: No Enforcement (Market Decides)

Any vault + any factory. Bad combinations simply don't attract users.

**Pros:**
- Maximally permissionless
- Simple — no validation code
- The market self-corrects (no one uses bad pairings)

**Cons:**
- Confusing UX — users might pick incompatible pairings
- Wasted gas deploying projects that don't work well
- Support burden

### Option D: Capability-Based (Use supportsCapability)

Factory checks specific capabilities it needs using the existing supportsCapability infrastructure.

```solidity
// In ERC404Factory.createInstance():
if (!IAlignmentVault(vault).supportsCapability(keccak256("YIELD_GENERATION"))) {
    emit VaultCapabilityWarning(vault, "YIELD_GENERATION");
}
```

**Pros:**
- Composable — uses existing supportsCapability infrastructure
- Factory-driven — each factory defines its own requirements
- No compatibility matrix to govern
- New vault types automatically work if they have the right capabilities
- Soft (events) or hard (require) enforcement — factory author chooses

**Cons:**
- Need to define which capabilities each factory needs
- Could be overly restrictive if factory requires capabilities that aren't strictly necessary
- Capability granularity must be right

## Recommendation

**Option D: Capability-based, with soft enforcement (warnings, not reverts).**

Rationale:
1. We already built supportsCapability — using it here is free
2. Factory-driven validation scales naturally with new factory types
3. Soft enforcement (emit warning events) preserves permissionlessness while giving frontends data to warn users
4. Hard enforcement can be added later per-factory if needed

Implementation approach:
- Each factory checks capabilities and emits `VaultCapabilityWarning` for missing ones
- Frontend reads these events and shows warnings to users
- No reverts — the user can proceed anyway if they know what they're doing

This keeps the protocol permissionless while protecting users from confusion.

## Interface Changes Required

None to `IAlignmentVault` — supportsCapability already exists.

Factory-side additions:

```solidity
event VaultCapabilityWarning(address indexed vault, string capability);
```
