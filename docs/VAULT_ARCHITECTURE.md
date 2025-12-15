# Ultra-Alignment Vault V2 Architecture

## Vision

The Ultra-Alignment Vault V2 is a simplified, elegant share-based system that collects ETH contributions, converts them into liquidity positions for an alignment target token, and allows contributors to claim fees proportional to their share of the LP position.

## Core Design Principles

1. **Dragnet Accumulation**: Contributions accumulate in pending state until batch-converted to LP positions
2. **Share-Based Accounting**: Fee distribution uses simple share ratios instead of complex epoch tracking
3. **O(1) Operations**: Fee claims and calculations are constant-time using proportional sharing
4. **Minimal State**: Track only what's essential: total contributions (bragging rights) and LP stakes

## Core Components

### 1. Contribution Tracking

The vault receives ETH contributions from multiple sources:

#### Direct Contributions
- **Source**: `receive()` function accepts ETH from any address
- **Flow**: Sender becomes benefactor, ETH added to pending dragnet
- **Tracking**: `benefactorTotalETH[benefactor]` accumulates total historical contribution (for bragging rights)

#### Hook-Based Contributions
- **Source**: V4 hooks call `receiveHookTax()` with explicit benefactor attribution
- **Flow**: Hook specifies source project/hook, ETH added to pending dragnet
- **Tracking**: Same as direct, but with clear source attribution

#### Dragnet System
- **Pending Contributions**: `pendingETH[benefactor]` accumulates contributions until conversion
- **Active Benefactors**: `conversionParticipants[]` tracks all contributors in current round
- **Reset Pattern**: Pending state clears after each conversion, ready for next round

### 2. Conversion & Liquidity (Dragnet-to-LP)

The core operation batches pending contributions into a single LP position addition:

```
convertAndAddLiquidity(minOutTarget, tickLower, tickUpper)
├─ Calculate caller reward (0.05% of pending ETH)
├─ Check target asset price and vault's current LP position
├─ Determine optimal swap ratio (ETH to swap vs hold)
├─ Swap portion of ETH for alignment token
├─ Add liquidity to V4 pool with both ETH and target token
├─ Issue shares proportionally to all benefactors
│  ├─ For each benefactor: shares = (contribution / totalPending) × totalSharesIssued
│  └─ Update benefactorShares[benefactor]
├─ Clear pending contributions for next round
└─ Pay caller incentive reward
```

**Key Insight**: All benefactors receive shares in a single LP position addition, eliminating per-contribution tracking.

### 3. Share-Based Fee Distribution

Contributors claim fees based on their share of total LP liquidity:

```
calculateClaimable(benefactor) = (accumulatedFees × benefactorShares[benefactor]) / totalShares
claimFees(benefactor) = currentClaimable - shareValueAtLastClaim[benefactor]
```

**Delta Tracking**: Each benefactor tracks their last claim value to support multiple claims over time.

### 4. LP Position Management

The vault manages a single V4 LP position per alignment target:

- **Position Tracking**: `totalLPUnits` accumulates liquidity units across conversions
- **Fee Accumulation**: `accumulatedFees` tracks fees collected from the position
- **Pool Configuration**: `v4Pool` and `alignmentToken` specify the target pool
- **Tick Management**: Position uses specified tick range for concentrated liquidity

## Data Structures

```solidity
// Benefactor contribution and share tracking
mapping(address => uint256) public benefactorTotalETH;      // Historical total (bragging rights)
mapping(address => uint256) public benefactorShares;        // LP share units
mapping(address => uint256) public pendingETH;              // Dragnet accumulator

// Claim state for multi-claim support
mapping(address => uint256) public shareValueAtLastClaim;   // Last claim amount
mapping(address => uint256) public lastClaimTimestamp;      // Claim timestamp

// Global state
uint256 public totalShares;           // Total shares issued across all conversions
uint256 public totalPendingETH;        // Sum of all pending contributions
uint256 public accumulatedFees;        // Fees collected from LP position
uint256 public totalLPUnits;           // Liquidity units in vault's LP position

// Dragnet participants
address[] public conversionParticipants;           // Benefactors in current round
mapping(address => uint256) public lastConversionParticipantIndex;

// Configuration
address public immutable weth;         // WETH contract
address public immutable poolManager;  // V4 PoolManager
address public alignmentToken;         // Target token for liquidity position
address public v4Pool;                 // V4 pool address
uint256 public conversionRewardBps;    // Caller incentive (default 5 = 0.05%)
```

## Key Functions

### Contribution Functions

#### `receive() external payable`
- Direct ETH contributions without source attribution
- Adds to dragnet for next conversion

#### `receiveHookTax(Currency currency, uint256 amount, address benefactor) external payable`
- Explicit benefactor attribution for hook-based contributions
- Supports clear source project tracking

### Conversion Function

#### `convertAndAddLiquidity(uint256 minOutTarget, int24 tickLower, int24 tickUpper) external returns (uint256 lpPositionValue)`
- Batch-converts all pending ETH to LP position
- Distributes shares proportionally to all pending benefactors
- Returns total value of LP position added

**Process**:
1. Calculate caller reward (incentive for execution)
2. Check target asset price and vault's LP tick configuration
3. Calculate optimal swap ratio (what % of ETH to swap vs hold)
4. Swap calculated ETH for alignment target token
5. Add liquidity to V4 pool with swapped token and remaining ETH
6. Calculate new shares: `totalSharesIssued = liquidityUnitsAdded`
7. For each benefactor, issue: `shares = (contribution / ethToAdd) × totalSharesIssued`
8. Clear pending dragnet for next round
9. Pay caller reward

### Fee Claim Functions

#### `claimFees() external returns (uint256 ethClaimed)`
- O(1) calculation using share ratio
- Supports multiple claims (delta-based)
- Formula: `ethClaimed = (accumulatedFees × shares) / totalShares - lastClaimed`

#### `recordAccumulatedFees(uint256 feeAmount) external onlyOwner`
- Owner records fees collected from LP position
- Fees then available for benefactor claims

### Query Functions

#### `getBenefactorContribution(address) external view returns (uint256)`
- Total historical ETH contributed (for bragging rights/leaderboards)

#### `getBenefactorShares(address) external view returns (uint256)`
- Current share balance

#### `calculateClaimableAmount(address) external view returns (uint256)`
- Total claimable (not delta) for given benefactor

#### `getUnclaimedFees(address) external view returns (uint256)`
- Unclaimed fees since last claim (delta)

## Internal Helper Functions (Stubs for Integration)

```solidity
// Swap ETH for alignment target token (DEX integration)
_swapETHForTarget(ethAmount, minOutTarget) → tokenReceived

// Add to V4 LP position (V4 modifyLiquidity integration)
_addToLpPosition(amount0, amount1, tickLower, tickUpper) → liquidityUnits

// Check target asset price and purchase power (price oracle)
_checkTargetAssetPriceAndPurchasePower() → void

// Inspect vault's current LP position tick configuration
_checkCurrentVaultOwnedLpTickValues() → void

// Calculate optimal swap proportion based on LP position
_calculateProportionOfEthToSwapBasedOnVaultOwnedLpTickValues() → proportionToSwap
```

## Configuration Functions

#### `setAlignmentToken(address newToken) external onlyOwner`
- Set target token for liquidity positions

#### `setV4Pool(address newPool) external onlyOwner`
- Set target V4 pool address

#### `setConversionRewardBps(uint256 newBps) external onlyOwner`
- Adjust caller incentive (max 1%, default 0.05%)

#### `depositFees(uint256 amount) external payable onlyOwner`
- Owner can manually deposit fees (alternative to `recordAccumulatedFees`)

## Fee Distribution Math

### Share-Based Distribution
```
benefactorClaimable = (accumulatedFees × benefactorShares[benefactor]) / totalShares
```

### Share Issuance on Conversion
```
// For each benefactor in the dragnet:
sharePercent = (benefactorPendingETH / totalPendingETH) × 1e18
sharesToIssue = (totalSharesIssued × sharePercent) / 1e18
```

### Multi-Claim Support (Delta)
```
currentValue = (accumulatedFees × benefactorShares) / totalShares
unclaimedFees = currentValue - shareValueAtLastClaim[benefactor]
```

## Events

```solidity
event ContributionReceived(address indexed benefactor, uint256 amount);
event LiquidityAdded(
    uint256 ethSwapped,
    uint256 tokenReceived,
    uint256 lpPositionValue,
    uint256 sharesIssued,
    uint256 callerReward
);
event FeesClaimed(address indexed benefactor, uint256 ethAmount);
event FeesAccumulated(uint256 amount);
```

## Integration Points

### Direct Contribution (Any Address)
```solidity
// User sends ETH to vault
(bool success, ) = payable(address(vault)).call{value: ethAmount}("");
// Vault emits ContributionReceived and adds to dragnet
```

### V4 Hook Integration
```solidity
// In UltraAlignmentV4Hook.afterSwap()
if (taxAmount > 0) {
    vault.receiveHookTax(taxCurrency, taxAmount, msg.sender);  // msg.sender = project hook
}
```

### Conversion Incentive
```solidity
// Anyone can call to trigger conversion
vault.convertAndAddLiquidity(minOutTarget, tickLower, tickUpper);
// Caller receives 0.05% reward from pending ETH
```

## Security Considerations

1. **Reentrancy Protection**: All state-changing functions use `nonReentrant` guard
2. **Ownership Control**: Configuration functions restricted to owner
3. **Input Validation**: All amounts and addresses validated
4. **Slippage Protection**: Swap functions require minimum output
5. **Delta Tracking**: Prevents duplicate fee claims across multiple calls

## Performance Characteristics

| Operation | Complexity | Notes |
|-----------|-----------|-------|
| `receive()` | O(1) | Direct contribution, dragnet tracking |
| `convertAndAddLiquidity()` | O(n) | Linear in active benefactors (n = dragnet size) |
| `claimFees()` | O(1) | Share ratio calculation, no iteration |
| `recordAccumulatedFees()` | O(1) | Simple accumulator update |

## Comparison to V1

**Eliminated Complexity**:
- ❌ Epoch-based tracking → ✅ Simple share model
- ❌ Per-conversion per-benefactor tracking → ✅ Single dragnet per round
- ❌ Complex fee distribution loop → ✅ O(1) ratio calculation
- ❌ Accumulated state bloat → ✅ Minimal required storage

**Key Improvement**:
Share-based abstraction reduces fee distribution from O(m×n) (benefactors × conversions) to O(1) while simultaneously simplifying the conversion process from complex epoch management to a simple dragnet pattern.

