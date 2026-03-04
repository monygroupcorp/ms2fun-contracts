# MEV & Transaction-Ordering Analysis

Front-running, sandwich attacks, and transaction-ordering risks across ms2.fun contracts. Each section describes the attack surface, existing protections, and residual risk.

---

## 1. Bonding Curve (ERC404BondingInstance)

**Surface:** `buyBonding` / `sellBonding` execute against a deterministic curve whose price moves with every trade. A frontrunner can buy ahead of a large buy (or sell ahead of a large sell) to profit from the price movement.

**Protections:**

| Parameter | Purpose |
|-----------|---------|
| `maxCost` | Buy reverts if total cost (including fee) exceeds caller's limit |
| `minRefund` | Sell reverts if refund falls below caller's floor |
| `deadline` | Reverts if `block.timestamp > deadline` (opt-in; `0` disables) |

Fee rounding is floor-division (`totalCost * bondingFeeBps / 10000`), favoring the buyer. Excess `msg.value` is refunded atomically.

**Residual risk:**
- Deadline is opt-in (`0` disables). Callers who omit it can have transactions sit in the mempool indefinitely. Frontend should always set a deadline.
- Slippage tolerance is caller-chosen. A loose `maxCost` still allows profitable sandwiching within the tolerance band.

---

## 2. Post-Graduation V4 Hook (UniAlignmentV4Hook)

**Surface:** After graduation, trading moves to a Uniswap V4 pool with a custom hook that collects alignment fees and overrides the LP fee.

**Protections:**

| Parameter | Mutability | Bound |
|-----------|-----------|-------|
| `hookFeeBips` | **Immutable** | `<= 10000` (enforced at construction) |
| `lpFeeRate` | Owner-adjustable | `<= LPFeeLibrary.MAX_LP_FEE` (enforced at set) |

`hookFeeBips` cannot be front-run adjusted — it is set once at deployment and baked into bytecode. Only `onlyPoolManager` can invoke `beforeSwap`/`afterSwap`.

**Residual risk:**
- `lpFeeRate` is owner-adjustable. An owner (or compromised owner key) could front-run a large swap by raising `lpFeeRate` to `MAX_LP_FEE`, capturing most of the swap value as fees, then lowering it. The bound prevents exceeding `MAX_LP_FEE` but does not prevent fee manipulation within that range.
- Mitigation: owner is expected to be the DAO timelock, making same-block fee changes infeasible. If owner is an EOA, this is a real risk.

---

## 3. Vault Conversions

### 3a. UniAlignmentVault — `convertAndAddLiquidity`

**Surface:** Converts accumulated ETH to alignment tokens and deposits into V4 LP. The ETH→token swap is sandwichable.

**Protections:**

| Parameter | Purpose |
|-----------|---------|
| `minOutTarget` | Minimum alignment tokens from the swap (passed to zRouter `amountLimit`) |
| `priceValidator.validatePrice()` | Reverts if spot price deviates > `maxPriceDeviationBps` from reference (default 5%, max 20%) |

**Residual risk:**
- No explicit deadline on vault conversion — `type(uint256).max` is passed to the router. The reward incentive drives timely execution, but a stale conversion tx in the mempool could execute at an unfavorable price (bounded by `minOutTarget`).
- Internal `_convertVaultFeesToEth` passes `0` as `amountLimit` for the token→ETH fee sweep, meaning **no slippage protection on the fee conversion path**. A sandwich attacker could extract value from this swap.

### 3b. ZAMMAlignmentVault — `convertAndAddLiquidity`

**Surface:** Same pattern as UniVault but for ZAMM pools. Three-parameter slippage.

**Protections:**

| Parameter | Purpose |
|-----------|---------|
| `minTokenOut` | Minimum alignment tokens from swap |
| `minEth` | Minimum ETH contributed to LP |
| `minToken` | Minimum token contributed to LP |

All three flow through to the ZAMM router and `addLiquidity` call.

**Residual risk:**
- `type(uint256).max` deadline on both the swap and LP deposit — same stale-tx concern as UniVault.
- LP removal in `_removeFeeLP` passes `0, 0` as min amounts — **no slippage on fee LP removal**.

### 3c. CypherAlignmentVault — `harvest`

**Surface:** Collects LP fees and swaps alignment tokens to WETH via Algebra V2 router.

**Protections:**

| Parameter | Purpose |
|-----------|---------|
| `minAmountOut` | Minimum WETH from the token→WETH swap |
| `deadline: block.timestamp` | Swap must execute in the current block |

**Residual risk:**
- `block.timestamp` as deadline means "this block" — no mempool staleness, but also no protection beyond the block the tx is included in (miners/builders choose inclusion).
- The `minAmountOut` value is caller-supplied. A keeper calling `harvest` with `minAmountOut = 0` gets no protection.

---

## 4. ERC721 Auctions (ERC721AuctionInstance)

**Surface:** English auction with ETH bids. Last-second sniping and bid-increment griefing are the primary MEV vectors.

**Protections:**

| Parameter | Mutability | Purpose |
|-----------|-----------|---------|
| `timeBuffer` | Immutable | Bids within `timeBuffer` seconds of end extend the auction |
| `bidIncrement` | Immutable | Each bid must exceed the previous by at least this amount |
| `baseDuration` | Immutable | Initial auction length |

Anti-snipe: if `auction.endTime - block.timestamp < timeBuffer`, the end is pushed to `block.timestamp + timeBuffer`. A sniper must keep outbidding by `bidIncrement` each extension, making last-second attacks expensive. Pattern matches Nouns DAO.

Previous bidder refund uses `SafeTransferLib.forceSafeTransferETH` (Solady), preventing griefing via reverting fallback.

**Residual risk:**
- `bidIncrement` is an absolute amount (not percentage-based). For high-value auctions, the increment may be trivially small relative to the final price. This is a design choice, not a bug — percentage-based minimums introduce rounding complexity.
- Block builders can still order bids within a block. However, since each bid must exceed the previous by `bidIncrement`, ordering within a block only affects which bidder wins when multiple valid bids arrive — there is no price manipulation vector.

---

## 5. Governance (GrandCentral)

**Surface:** Share-weighted voting. An attacker could buy shares to influence a vote, then sell after.

**Protections:**

| Mechanism | Purpose |
|-----------|---------|
| Checkpoint snapshots at `votingStarts` | Vote weight = shares held when voting opened, not current balance |
| `minRetentionPercent` | Proposal fails if totalShares drops below threshold (blocks ragequit-after-vote dilution) |
| `quorumPercent` | Absolute participation floor prevents low-turnout capture |
| Grace period | Dissenting members can ragequit before proposal executes |
| Processing order | Proposals process in sponsor-order via linked list; no out-of-order execution |

`getSharesAt(msg.sender, prop.votingStarts)` uses binary search over checkpoint history. Multiple share mutations within a block coalesce into one checkpoint entry.

**Residual risk:**
- Flash-loan voting is blocked (snapshot is at `votingStarts`, not at vote time). However, an attacker who accumulates shares *before* a proposal is sponsored can vote with full weight. This is standard for snapshot-based governance and is not unique to this system.
- `votingStarts` is set to `block.timestamp` at sponsor time. A proposer who sponsors and votes in the same transaction votes with shares as of that block — this is by design (self-sponsoring path).

---

## Summary of Residual Risks

| Risk | Severity | Location | Notes |
|------|----------|----------|-------|
| Bonding deadline opt-in (0 disables) | Low | ERC404BondingInstance | Frontend should enforce nonzero deadline |
| `lpFeeRate` front-run by owner | Medium | UniAlignmentV4Hook | Mitigated if owner is DAO timelock |
| No slippage on fee-sweep swap | Medium | UniAlignmentVault `_convertVaultFeesToEth` | Passes `0` as amountLimit |
| No slippage on fee LP removal | Medium | ZAMMAlignmentVault `_removeFeeLP` | Passes `0, 0` as min amounts |
| No deadline on vault conversions | Low | Uni/ZAMMAlignmentVault | `type(uint256).max` deadline |
| Keeper-supplied `minAmountOut = 0` | Low | CypherAlignmentVault `harvest` | Keeper's responsibility |
| Absolute bidIncrement on high-value auctions | Low | ERC721AuctionInstance | Design choice |
