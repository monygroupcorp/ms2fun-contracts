# Free Mints + GatingScope Design

**Date:** 2026-03-02
**Status:** Approved — ready for implementation planning

---

## Problem

ERC404 bonding instances (and ERC1155 editions) are common NFT launchpad primitives that
need two related features:

1. **Free mint allocation** — a zero-cost tranche of the total supply that artists can
   reserve for early supporters, team, or community.
2. **GatingScope** — control over *which* entry points the gating module guards, enabling
   patterns like "WL gets free mints, public can buy paid" without requiring two separate
   gating modules.

The existing `IGatingModule` slot gates paid purchases only. Free mints have no primitive.

---

## Deferred: Merkle Whitelist Module

A `MerkleWhitelistModule` was considered but deferred. The outstanding issue is the
**whitelist source problem**: artists must provide the full address list to generate proofs,
and proof distribution to end users is an unsolved UX problem for this launch. The existing
`PasswordTierGatingModule` covers the initial launch gating use case.

The `MerkleWhitelistModule` is a future component — same `IGatingModule` interface, same
ComponentRegistry slot, no design changes required to ship it later.

---

## Design

### 1. GatingScope

An immutable enum stored on the instance at deployment. Tells the instance which entry
points consult the gating module.

```solidity
enum GatingScope {
    BOTH,            // module gates free mint claims AND paid buys (default)
    FREE_MINT_ONLY,  // module gates free mint claims; paid buys are open
    PAID_ONLY        // module gates paid buys; free mint claims are open FCFS
}
```

**Call site rules:**
- `claimFreeMint()` — consults gating module if `scope != PAID_ONLY`
- `buyBonding()` — consults gating module if `scope != FREE_MINT_ONLY`

If no gating module is set, scope is irrelevant — both paths are open regardless.
`GatingScope` has no setter; it cannot change after deployment.

**Common patterns this enables:**

| Pattern | gatingModule | GatingScope |
|---------|-------------|-------------|
| WL free mints, public paid buys | PasswordTierGating | FREE_MINT_ONLY |
| WL-only sale + WL free mints | PasswordTierGating | BOTH |
| Password-gated sale, open free mints | PasswordTierGating | PAID_ONLY |
| Open FCFS free mints, open sale | none (address(0)) | any |

---

### 2. Free Mint Allocation

Free mints are a zero-cost tranche carved out of total supply at deployment. They are
**not** part of the bonding curve — they are minted directly at zero cost.

**Supply split:**
- Total supply = `nftCount × unit` tokens
- Free mint tranche = `freeMintAllocation × unit` tokens (minted via `claimFreeMint`)
- Bonding curve tranche = `(nftCount - freeMintAllocation) × unit` tokens

The factory subtracts `freeMintAllocation` from `nftCount` before computing curve params.
Graduation triggers when the bonding curve tranche is fully sold — free mints do not count
toward graduation.

**State added to ERC404BondingInstance:**

```solidity
uint256 public freeMintAllocation;               // NFT count reserved (0 = disabled)
uint256 public freeMintsClaimed;                 // running counter
mapping(address => bool) public freeMintClaimed; // per-wallet guard
GatingScope public gatingScope;
```

**Claim function:**

```solidity
function claimFreeMint(bytes calldata gatingData) external {
    require(freeMintAllocation > 0,            "No free mints");
    require(!freeMintClaimed[msg.sender],       "Already claimed");
    require(freeMintsClaimed < freeMintAllocation, "Allocation exhausted");

    if (address(gatingModule) != address(0) && gatingActive
        && gatingScope != GatingScope.PAID_ONLY) {
        (bool allowed, bool permanent) = gatingModule.canMint(msg.sender, unit, gatingData);
        require(allowed, "Not allowed");
        if (permanent) gatingActive = false;
        gatingModule.onMint(msg.sender, unit);
    }

    freeMintClaimed[msg.sender] = true;
    freeMintsClaimed++;
    _mint(msg.sender, unit);
}
```

`buyBonding` gets one added condition: skip the gating check when
`gatingScope == GatingScope.FREE_MINT_ONLY`.

---

### 3. Factory Changes

A `FreeMintParams` struct is passed to `createInstance` alongside the existing
`IdentityParams`. The factory:

1. Validates `freeMint.allocation < identity.nftCount`
2. Computes curve params against `identity.nftCount - freeMint.allocation`
3. Passes `freeMintAllocation` and `gatingScope` to the instance initializer

```solidity
struct FreeMintParams {
    uint256 allocation;   // NFTs to reserve for free claims (0 = disabled)
    GatingScope scope;    // which entry points the gating module guards
}
```

Setting `allocation = 0` disables free mints entirely — no code path changes, existing
behaviour preserved.

---

### 4. ERC1155 Free Mints

Same pattern, same field names:

```solidity
uint256 public freeMintAllocation;
uint256 public freeMintsClaimed;
mapping(address => bool) public freeMintClaimed;
GatingScope public gatingScope;

function claimFreeMint(bytes calldata gatingData) external { ... }
```

The underlying mint mechanic differs (ERC1155 `_mint` vs DN404 `_mint`) but the
allocation logic, wallet guard, and gating check are identical.

---

## What Is Not Changing

- `IGatingModule` interface — unchanged
- `PasswordTierGatingModule` — unchanged
- `ComponentRegistry` — unchanged
- `FeatureUtils` — no new feature tag needed (free mints are instance-level, not a
  pluggable component slot)

---

## Outstanding / Future

- **MerkleWhitelistModule** — deferred. Needs a decision on whitelist source and
  proof distribution UX before implementation.
- **ERC721 free mints** — auctions have a different lifecycle (reserve price, single
  winner); free mint concept does not apply.
