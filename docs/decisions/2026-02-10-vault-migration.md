# Vault Migration Protocol Design Decision

## Status: Proposed

## Context

Vault references across the codebase have different mutability:

| Contract | Vault Reference | Mutable? |
|---|---|---|
| ERC404BondingInstance | `IAlignmentVault public vault` | Yes — `setVault()` exists |
| ERC1155Instance | `IAlignmentVault public vault` | No — set once in constructor |
| UltraAlignmentV4Hook | `IAlignmentVault public immutable vault` | No — immutable |

When a vault is set, the vault begins tracking the instance as a benefactor. The vault holds:
- `benefactorTotalETH[instance]` — lifetime contribution
- `benefactorShares[instance]` — fee claim shares
- `pendingETH[instance]` — ETH awaiting conversion
- `shareValueAtLastClaim[instance]` — claim watermark

## Problem

Changing the vault address on an instance doesn't migrate any of this state. The old vault retains all value. The instance starts from zero on the new vault. This matters for:

- **Vault upgrades:** V4 LP vault to V5 LP vault when Uniswap upgrades
- **Strategy changes:** Moving from LP yield to lending yield
- **Bug fixes:** If a vault has a vulnerability, instances need to move

## Options

### Option A: No Migration (Vault is Permanent)

Make vault immutable everywhere. Projects pick a vault at creation time and live with it forever.

**Pros:**
- Simplest possible design
- No migration attack surface
- Predictable — vault never changes
- Matches the hook constraint (hook's vault is already immutable)

**Cons:**
- No upgrade path — if the vault strategy becomes obsolete, the project is stuck
- Protocol evolution requires deploying new projects, not upgrading existing ones

### Option B: Vault-Level Migration

Add `migrateToVault(address newVault)` on `IAlignmentVault`. The old vault transfers all ETH, shares, and state to the new vault.

**Pros:**
- Preserves all historical state
- Transparent to instances — they don't need to know migration happened

**Cons:**
- Extremely complex — new vault must accept arbitrary migrated state
- Trust assumption — who authorizes migration? Owner? Governance?
- State format must be standardized across vault types (a V4 LP vault's state is meaningless to an Aave vault)
- Attack surface — migration function could drain the vault if compromised

### Option C: Instance-Level Migration

Instance claims all fees from old vault, owner calls `setVault(newVault)`, future contributions go to new vault. Historical state stays in old vault.

**Pros:**
- Simple to implement — already possible today for ERC404 (setVault exists)
- No vault-to-vault trust needed
- Instance controls the timing

**Cons:**
- Loses historical state (contribution records, share history)
- Pending ETH in old vault that hasn't been converted to shares is lost unless manually claimed first
- Requires careful sequencing (claim everything then set new vault)
- ERC1155Instance can't do this today (vault set in constructor)

## Hook Constraint

The V4 hook's vault reference is `immutable` — hardcoded at deployment via CREATE2. The hook's address encodes its permissions in the low bits, computed from the CREATE2 salt. Changing the vault means:

1. Deploy a new hook with the new vault
2. The new hook has a different address
3. V4 pools are identified by their hook address
4. This effectively creates a NEW pool — all liquidity must migrate

This is the fundamental constraint. Even if instances can change their vault, the hook cannot. Any "migration" for V4-integrated projects means deploying a completely new hook and pool.

## Recommendation

**Option A: No Migration (Vault is Permanent)** for now, with the following nuances:

1. Make vault immutable in ERC1155Instance (it already is, set in constructor)
2. Keep `setVault()` on ERC404BondingInstance but ONLY for initial setup (vault can only be set once, not changed). Add a guard: `require(address(vault) == address(0), "Vault already set")`
3. Accept that vault upgrades = new project deployments. This is consistent with how V4 hooks work (immutable vault) and avoids the massive complexity of migration

The hook constraint makes full migration impractical anyway. If the hook can't migrate, the pool can't migrate, and the project might as well be new.

Future consideration: If the protocol matures and vault migration becomes critical, Option C (instance-level) is the path of least resistance, but it should be designed holistically with hook migration at that point.

## Interface Changes Required

None for the interface. Consider adding to ERC404BondingInstance:

```solidity
function setVault(address _vault) external onlyOwner {
    require(address(vault) == address(0), "Vault already set");
    vault = IAlignmentVault(payable(_vault));
}
```
