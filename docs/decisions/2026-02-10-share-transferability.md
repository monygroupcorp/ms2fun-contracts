# Share Transferability Design Decision

## Status: Proposed

## Context

Vault shares are currently internal accounting — `mapping(address => uint256) public benefactorShares` in `UltraAlignmentVault.sol`. Shares are issued proportionally when `convertAndAddLiquidity()` runs and are used solely to calculate fee claim entitlement: `(accumulatedFees * benefactorShares[caller]) / totalShares`. There is no mechanism to transfer, delegate, or trade shares.

Benefactors are project instances (contract addresses), not individual users. An ERC404BondingInstance or ERC1155Instance is the benefactor, and it internally redistributes fees to its owner or stakers.

## Problem

Future vault types need transferable shares:

- **DAO Vault:** Shares = voting tickets. Holders need to delegate votes, participate in Snapshot/Governor proposals, or trade governance power.
- **Composability:** ERC20 shares can be used in other DeFi protocols (lending, yield farming, LP).
- **Secondary markets:** Project creators may want to sell their vault position.

Without transferability, DAO vaults are dead on arrival — governance tooling (OpenZeppelin Governor, Snapshot, Tally) all expect ERC20 or ERC20Votes tokens.

## Options

### Option A: ERC20 Share Tokens

Every vault deploys or wraps an ERC20 token representing shares. Share issuance mints tokens, claiming burns or transfers.

**Pros:**
- Full composability with existing governance frameworks (Governor, Snapshot)
- Can be listed, traded, used as collateral
- Standard tooling, wallets, block explorers all understand ERC20

**Cons:**
- Every vault needs its own token — more deployment gas, more complexity
- Share/fee accounting must be synchronized with token transfers (transfer hooks or checkpoints)
- Potential for shares to trade at a disconnect from underlying vault value

### Option B: Interface Method transferShares(from, to, amount)

Add a lightweight transfer function to `IAlignmentVault`. No separate token.

**Pros:**
- Simple — one function addition
- No extra contract deployment

**Cons:**
- Not composable with ANY existing governance/DeFi tooling
- Custom delegation system needed from scratch
- No wallet/explorer visibility of share balances
- Essentially building a bad ERC20 from scratch

### Option C: Optional via sharesToken() Query

Leave shares non-transferable by default. Vaults that need transferability implement an ERC20 internally and expose it via a `sharesToken()` getter on the interface.

- `sharesToken()` returns `address(0)` for non-transferable vaults (UltraAlignmentVault, MockVault)
- `sharesToken()` returns the ERC20 address for transferable vaults (future DAO vault)
- The ERC20 is the source of truth for share balances in transferable vaults
- Non-transferable vaults continue using internal mappings unchanged

**Pros:**
- Backwards compatible — existing vaults untouched
- Opt-in complexity — only vaults that need it pay the cost
- Full composability when needed (the ERC20 works with Governor, Snapshot, etc.)
- Clean capability detection: `sharesToken() != address(0)` means transferable

**Cons:**
- Two code paths for share accounting (mapping vs ERC20)
- Future vaults must choose at deployment time

## Recommendation

**Option C: Optional via sharesToken()**

This is the right balance. The current vault (UltraAlignmentVault) doesn't need transferability — its benefactors are contract addresses, not humans. Forcing ERC20 overhead on every vault is wasteful. But DAO vaults absolutely need it, and building a custom transfer system (Option B) when ERC20 already exists is foolish.

The `supportsCapability(keccak256("SHARE_TRANSFER"))` flag already exists to signal this. The `sharesToken()` getter provides the concrete token address.

## Interface Changes Required

Add to `IAlignmentVault`:

```solidity
/**
 * @notice Get the ERC20 token representing vault shares, if transferable
 * @dev Returns address(0) if shares are non-transferable (internal accounting only).
 *      Returns the ERC20 token address if shares are transferable.
 *      When transferable, the ERC20 balance IS the share balance (source of truth).
 */
function sharesToken() external view returns (address);
```

## Impact on Existing Contracts

- **UltraAlignmentVault:** Add `function sharesToken() returns (address) { return address(0); }` — no behavior change
- **MockVault:** Same — return `address(0)`
- **Future DAO Vault:** Deploy an ERC20Votes token, mint on share issuance, return its address from `sharesToken()`
