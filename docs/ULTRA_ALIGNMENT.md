# Ultra-Alignment System (V2)

## Overview

The Ultra-Alignment system V2 is an elegant, share-based fee collection and distribution architecture that captures value from ms2fun platform projects and converts it into aligned liquidity positions. It enables token holders and projects to participate in platform upside through a simple, gas-efficient contribution and fee claim mechanism.

## Core Concepts

### Dragnet Contribution Model
Contributions accumulate in a "dragnet" from multiple sources (direct transfers, hooks, project taxes) until a batch conversion is triggered. This defers expensive conversion logic to a single public function called by anyone with a small incentive reward.

### Share-Based Fee Distribution
Rather than tracking per-epoch per-benefactor state, the V2 vault issues shares proportional to contributions. All fee distributions are O(1) calculations using simple ratio math: `fee = (totalFees × benefactorShares) / totalShares`

### Delta Tracking for Multi-Claim
Benefactors can claim fees multiple times by tracking the value of their shares at each claim. New fees are the delta between current share value and last claim value.

## System Architecture

### Ultra-Alignment Vault V2 (Core)

The UltraAlignmentVaultV2 contract is the central hub for collecting contributions and managing fee distribution.

**Contribution Sources:**
- **Direct ETH**: Anyone can send ETH directly to the vault (via `receive()`)
- **Hook-Attributed ETH**: V4 hooks call `receiveHookTax()` with explicit benefactor attribution (for project source tracking)
- **Dragnet Accumulation**: All contributions accumulate in `pendingETH[benefactor]` until conversion

**Conversion Flow:**
```
Batch Convert (anyone can call)
├─ Check: totalPendingETH > 0
├─ Calculate: callerReward = (totalPendingETH × 0.05%) / 100
├─ Query: Current target asset price and vault's LP position
├─ Determine: Optimal swap ratio (how much ETH to swap vs hold)
├─ Swap: Portion of ETH → Alignment target token
├─ Add: Liquidity to V4 pool with swapped token + remaining ETH
├─ Issue: Shares to each benefactor proportional to contribution
├─ Clear: Pending dragnet for next round
└─ Reward: Caller with small ETH reward
```

**Fee Claim Flow:**
```
Claim Fees (benefactor calls)
├─ Calculate: Current share value = (accumulatedFees × myShares) / totalShares
├─ Delta: Unclaimed = currentValue - lastClaimValue
├─ Transfer: Unclaimed ETH to benefactor
└─ Update: lastClaimValue for next claim
```

### Ultra-Alignment V4 Hook

V4 hooks collect taxes from DEX swaps and direct them to the vault with explicit project attribution.

**Integration Points:**
- Hook executes in `afterSwap()` of ERC404 swap flow
- Calculates tax as % of swap amount
- Calls `vault.receiveHookTax(currency, amount, benefactor)` with project address

**Key Design:**
- Benefactor parameter = project/hook instance address
- Allows clear attribution of which project generated the fee
- Dragnet accumulation means vault doesn't swap immediately (deferred to batch conversion)

## Data Model

### Storage Variables (UltraAlignmentVaultV2)

```solidity
// Contribution tracking (per-benefactor)
benefactorTotalETH[address]         // Historical total (for leaderboards)
benefactorShares[address]            // Current LP share units
pendingETH[address]                  // Pending contribution in dragnet

// Fee claim state (supports multi-claim via delta)
shareValueAtLastClaim[address]       // Last claim amount
lastClaimTimestamp[address]          // Last claim block.timestamp

// Global state
totalShares                          // Total shares issued (all conversions)
totalPendingETH                      // Sum of pending contributions
accumulatedFees                      // Fees collected from LP
totalLPUnits                         // Liquidity units in vault's position

// Dragnet management
conversionParticipants[]             // Array of active benefactors
lastConversionParticipantIndex[addr] // Index tracking (optimization)

// Configuration
weth                                 // WETH contract (immutable)
poolManager                          // V4 PoolManager (immutable)
alignmentToken                       // Target token (configurable)
v4Pool                               // Target pool (configurable)
conversionRewardBps                  // Caller incentive % (default: 5 = 0.05%)
```

## Key Functions

### For Contributors (ETH Senders)

- **`receive() external payable`**: Send ETH directly, become benefactor automatically
- **`receiveHookTax(Currency currency, uint256 amount, address benefactor) external payable`**: Receive taxed ETH from V4 hooks with project attribution

### For Liquidators (Conversion Operators)

- **`convertAndAddLiquidity(uint256 minOutTarget, int24 tickLower, int24 tickUpper) external returns (uint256 lpPositionValue)`**: Batch-convert all pending ETH to LP position, receive reward

### For Benefactors (Claim Fees)

- **`claimFees() external returns (uint256 ethClaimed)`**: Claim accrued fees, supports multiple claims

### Configuration (Owner Only)

- **`setAlignmentToken(address newToken) external onlyOwner`**: Set target token
- **`setV4Pool(address newPool) external onlyOwner`**: Set target pool
- **`setConversionRewardBps(uint256 newBps) external onlyOwner`**: Set caller incentive (max 1%)
- **`recordAccumulatedFees(uint256 feeAmount) external onlyOwner`**: Record LP fees
- **`depositFees() external payable onlyOwner`**: Manual fee deposit

### Query Functions (View)

- **`getBenefactorContribution(address) returns (uint256)`**: Total historical ETH
- **`getBenefactorShares(address) returns (uint256)`**: Current share balance
- **`calculateClaimableAmount(address) returns (uint256)`**: Total claimable (not delta)
- **`getUnclaimedFees(address) returns (uint256)`**: Delta since last claim

## Integration Points

### ERC404 Hook → Vault Integration
```solidity
// In V4 Hook afterSwap()
uint256 taxAmount = (swapAmount * taxBps) / 10000;
if (taxAmount > 0) {
    vault.receiveHookTax(taxCurrency, taxAmount, msg.sender);
}
// msg.sender = hook instance = project identifier
```

### Manual Contribution (Frontend/Scripts)
```solidity
// User sends ETH to vault
(bool success, ) = payable(vault).call{value: ethAmount}("");
require(success, "Send failed");
// Vault tracks sender as benefactor
```

### Conversion Incentive (Anyone)
```solidity
// Anyone can trigger conversion
vault.convertAndAddLiquidity(minOutTarget, tickLower, tickUpper);
// Caller receives 0.05% of pending ETH as reward
```

### Fee Claim (Benefactor)
```solidity
// Any benefactor can claim their share
uint256 claimed = vault.claimFees();
// Can be called multiple times, only new fees claimed
```

## Fee Distribution Examples

### Example 1: Simple Two-Benefactor Scenario

```
Initial state:
- benefactorA: 0 shares, 0 pending
- benefactorB: 0 shares, 0 pending
- accumulatedFees: 0

Step 1: Contributions arrive
- benefactorA: 1 ETH → pendingETH[A] = 1
- benefactorB: 2 ETH → pendingETH[B] = 2
- totalPendingETH = 3

Step 2: Conversion triggered
- callerReward = 3 * 0.05% = 0.0015 ETH
- ethToAdd = 3 - 0.0015 = 2.9985 ETH
- Swap + LP add: receives 100 LP units
- Share issuance:
  - A gets: (1 / 2.9985) × 100 = 33.35 shares
  - B gets: (2 / 2.9985) × 100 = 66.69 shares
  - totalShares = 99.99

Step 3: Fees accumulate
- LP position generates fees, vault receives 1 ETH
- accumulatedFees = 1 ETH

Step 4: Benefactor A claims
- A's claimable = (1 × 33.35) / 99.99 = 0.3335 ETH
- A receives 0.3335 ETH
- shareValueAtLastClaim[A] = 0.3335

Step 5: More fees, B claims
- LP generates 0.5 ETH more
- accumulatedFees = 1.5 ETH
- B's claimable = (1.5 × 66.69) / 99.99 = 1.0004 ETH
- B receives 1.0004 ETH (first claim)
- shareValueAtLastClaim[B] = 1.0004

Step 6: A claims again (delta)
- accumulatedFees = 1.5 ETH (no new fees yet)
- A's new claimable = (1.5 × 33.35) / 99.99 = 0.5003 ETH
- A's delta = 0.5003 - 0.3335 = 0.1668 ETH
- A receives 0.1668 ETH (second claim)
```

## Performance Characteristics

| Operation | Complexity | Gas | Notes |
|-----------|-----------|-----|-------|
| `receive()` | O(1) | ~2500 | Add to dragnet |
| `receiveHookTax()` | O(1) | ~2500 | Hook-attributed contribution |
| `convertAndAddLiquidity()` | O(n) | ~50k + swap costs | n = active benefactors in dragnet |
| `claimFees()` | O(1) | ~5000 | Share ratio calc, no loops |
| `recordAccumulatedFees()` | O(1) | ~3000 | Simple counter update |

## Comparison to V1

**What Improved:**
- ✅ **Eliminated complex epoch-based tracking** → Simple dragnet model
- ✅ **O(1) fee claims** instead of O(n) loop over conversion history
- ✅ **Single dragnet per round** instead of per-conversion per-benefactor state
- ✅ **Minimal storage overhead** → Only essential state tracked
- ✅ **Delta-based multi-claim** → No duplicate claim issues
- ✅ **Clear project attribution** → Hook-based contributions tagged with source

**Key Architecture Shift:**
V1 tried to track per-conversion per-benefactor state, leading to complexity and gas waste. V2 recognizes that all shares derive from a single unified LP position, so benefactors simply own a percentage of that position. Fee distribution becomes trivial: `fee = (totalFees × benefactorShares) / totalShares`.

## Security Features

1. **Reentrancy Guard**: All state-changing functions protected with `nonReentrant`
2. **Owner Access Control**: Configuration restricted to contract owner
3. **Input Validation**: All amounts and addresses validated
4. **Slippage Protection**: Swap functions require minimum output
5. **Delta Tracking**: Prevents duplicate fee claims
6. **Immutable Contracts**: WETH and PoolManager cannot be changed

