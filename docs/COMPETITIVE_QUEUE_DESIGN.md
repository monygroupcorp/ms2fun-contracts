# Competitive Featured Queue System - Design Document

## Overview

The MasterRegistry implements a **competitive rental-based queue system** for featured project listings. This system creates a dynamic marketplace where projects compete for visibility through position-based rentals with time-based expiration and competitive pricing.

## Core Principles

### 1. **Rental-Based Model**
- Positions are **rented, not owned**
- Each rental has a fixed **duration** (minimum 7 days)
- Positions **expire** when rental period ends
- **Incentivized public cleanup** removes expired positions

### 2. **Competitive Pricing**
- Base price starts cheap: **0.001 ETH**
- Each competitive action increases price by **20%** (120% multiplier)
- Prices apply **per-position** (position 1 has its own market)
- New entrants always pay **current market rate** (no discounts)

### 3. **Position Displacement**
- When someone takes your position, you **shift down one spot**
- Your rental time **continues** at the new position
- You can **bump back up** by paying the competitive rate
- This creates a **dynamic leaderboard** effect

### 4. **Fair Credit System**
- When displaced or bumping, you get **time-proportional credit**
- Credit = (original payment × time remaining) / total duration
- Bump cost = competitive price - your credit
- **Full competitive price tracked** regardless of discounts

## Architecture

### Data Structures

```solidity
struct RentalSlot {
    address instance;           // Project being promoted
    address renter;            // Who paid for this rental
    uint256 rentPaid;          // Total amount paid (including bumps)
    uint256 rentedAt;          // When rental started
    uint256 expiresAt;         // When rental expires
    uint256 originalPosition;  // Where they started (tracking)
    bool active;               // Still valid?
}

struct PositionDemand {
    uint256 lastRentalPrice;      // FULL competitive price (not discounted)
    uint256 lastRentalTime;       // Last activity timestamp
    uint256 totalRentalsAllTime;  // Total actions at this position
}

// State
RentalSlot[] public featuredQueue;                    // Ordered array (index 0 = front)
mapping(address => uint256) public instancePosition;  // Quick position lookup (1-indexed)
mapping(uint256 => PositionDemand) public positionDemand;  // Per-position pricing
mapping(address => uint256) public renewalDeposits;   // Auto-renewal funds
```

### Configuration Parameters

```solidity
uint256 public baseRentalPrice = 0.001 ether;       // Starting price
uint256 public minRentalDuration = 7 days;          // Minimum rental period
uint256 public maxRentalDuration = 365 days;        // Maximum rental period
uint256 public demandMultiplier = 120;              // 120% = 20% increase per action
uint256 public renewalDiscount = 90;                // 90% = 10% discount for renewals
uint256 public cleanupReward = 0.0001 ether;        // Reward per expired slot cleaned
uint256 public visibleThreshold = 20;               // Frontend shows top 20
```

## Key Features

### 1. Rent a Position

**Function**: `rentFeaturedPosition(instance, position, duration)`

**Behavior**:
- Pay to place your instance at a specific position
- Everyone at that position and below **shifts down by 1**
- Your rental is protected for the duration (unless displaced)
- Cost scales with position demand and duration

**Pricing**:
```
Base cost = positionDemand[position].lastRentalPrice × 120%
Duration multiplier = duration / minRentalDuration
Total cost = base cost × duration multiplier
```

**Optional bulk discounts**:
- 14+ days: 5% discount
- 30+ days: 10% discount

### 2. Bump Your Position

**Function**: `bumpPosition(instance, targetPosition, additionalDuration)`

**Behavior**:
- Move up from current position to higher position
- Everyone between you and target **shifts down by 1**
- Your remaining time credit is applied to the cost
- Can optionally extend duration while bumping

**Pricing**:
```
Full competitive price = positionDemand[targetPosition].lastRentalPrice × 120%
Your credit = (rentPaid × timeRemaining) / totalDuration
Actual cost = full price - your credit
Additional duration cost = (competitive price × additionalDuration) / minRentalDuration
```

**Critical**: `positionDemand` is updated with **full competitive price**, not the discounted amount you paid!

### 3. Renew Your Position

**Function**: `renewPosition(instance, additionalDuration)`

**Behavior**:
- Extend your current position before it expires
- Get 10% discount (90% of market rate)
- Position stays the same (no displacement)
- Can be called multiple times

**Pricing**:
```
Renewal cost = (competitive price × duration multiplier) × 90%
```

### 4. Auto-Renewal

**Functions**:
- `depositForAutoRenewal(instance)` - Add funds
- `withdrawRenewalDeposit(instance)` - Withdraw unused funds

**Behavior**:
- Deposit ETH for automatic renewal
- When rental expires, cleanup function attempts renewal
- If sufficient funds, extends for `minRentalDuration` (7 days)
- Gets renewal discount (10% off)
- Continues until funds depleted

### 5. Incentivized Cleanup

**Function**: `cleanupExpiredRentals(maxCleanup)`

**Behavior**:
- Public function anyone can call
- Scans queue for expired rentals
- Attempts auto-renewal first (if funds available)
- Otherwise marks as inactive and removes
- Caller receives **0.0001 ETH per action** (cleanup or renewal)
- Compacts queue by removing trailing inactive slots

**Why this works**:
- Bots will call this automatically for profit
- Keeps queue clean without manual intervention
- Gas costs covered by reward
- Protocol benefits from fresh queue

## Economic Model

### Value Capture Through Competition

The system captures maximum value when projects compete for the same positions:

**Scenario: 2 Projects Fighting for Position 1**

| Day | Action | User Pays | Full Competitive Price | Total Revenue |
|-----|--------|-----------|------------------------|---------------|
| 1 | Alice rents pos 1 | 0.001 ETH | 0.001 ETH | 0.001 ETH |
| 2 | Bob takes pos 1 | 0.0012 ETH | 0.0012 ETH | 0.0022 ETH |
| 3 | Alice bumps to 1 | 0.000726 ETH | 0.00144 ETH | 0.002926 ETH |
| 4 | Bob bumps to 1 | 0.000871 ETH | 0.001728 ETH | 0.003797 ETH |
| 5 | Alice bumps to 1 | 0.001045 ETH | 0.002074 ETH | 0.004842 ETH |
| 6 | Bob bumps to 1 | 0.001254 ETH | 0.002489 ETH | 0.006096 ETH |

**Result**: 6 days of competition generates **6x more revenue** than a single rental!

**With 3rd entrant (Charlie on day 7)**:
- Charlie must pay: 0.002489 × 120% = **0.002987 ETH**
- This is **2.5x higher** than Bob's initial entry price
- Competition drives exponential growth

### Price Growth Formula

```
After N competitive actions:
Price = basePrice × (1.2)^N
```

Examples:
- After 5 actions: 0.001 × 1.2^5 = **0.002488 ETH** (2.5x)
- After 10 actions: 0.001 × 1.2^10 = **0.00619 ETH** (6.2x)
- After 20 actions: 0.001 × 1.2^20 = **0.0383 ETH** (38x)

### Visibility Cliff Effect

**Frontend displays**: Top 20 positions only

**Value proposition**:
- Positions 1-20: **High visibility** → Worth paying premium
- Positions 21+: **Zero visibility** → Cheap/free fallback

**Result**:
- Competition concentrates in top 20
- Natural price segmentation
- Positions 21+ stay at base price (no demand)

## Implementation Strategy

### Phase 1: Core Rental System
1. Implement `RentalSlot` and queue management
2. Add `rentFeaturedPosition()` with position shifting
3. Implement competitive pricing with `PositionDemand` tracking
4. Add duration-based cost calculation

### Phase 2: Competitive Features
1. Implement `bumpPosition()` with credit system
2. Ensure full competitive price tracking (not discounted bumps)
3. Add position shifting for bumps
4. Test multi-project competition scenarios

### Phase 3: Renewal & Maintenance
1. Add `renewPosition()` with discount
2. Implement auto-renewal deposit system
3. Create incentivized cleanup function with rewards
4. Add queue compaction logic

### Phase 4: Events & Observability
1. Emit events for all state changes
2. Add view functions for frontend integration
3. Create pricing preview functions
4. Add position history tracking (optional)

## Critical Implementation Details

### 1. Position Tracking Must Be Correct

```solidity
// When shifting positions, ALWAYS update the mapping
for (uint256 i = featuredQueue.length - 1; i > index; i--) {
    featuredQueue[i] = featuredQueue[i - 1];
    if (featuredQueue[i].active) {
        instancePosition[featuredQueue[i].instance] = i + 1;  // ✅ Critical!
    }
}
```

### 2. Full Competitive Price Tracking

```solidity
// In bumpPosition(), track FULL price, not discounted user payment
uint256 fullCompetitivePrice = getPositionRentalPrice(targetPosition);
uint256 userPays = calculateBumpCost(...);  // Includes credit

// Update with FULL price so next person pays competitive rate
positionDemand[targetPosition].lastRentalPrice = fullCompetitivePrice;  // ✅
// NOT: positionDemand[targetPosition].lastRentalPrice = userPays;  // ❌
```

### 3. Credit Calculation Must Be Time-Proportional

```solidity
uint256 timeRemaining = slot.expiresAt - block.timestamp;
uint256 totalDuration = slot.expiresAt - slot.rentedAt;
uint256 credit = (slot.rentPaid × timeRemaining) / totalDuration;
```

### 4. Array Compaction for Gas Efficiency

```solidity
// Remove trailing inactive slots to save gas
function _compactQueue() internal {
    while (featuredQueue.length > 0 && !featuredQueue[featuredQueue.length - 1].active) {
        featuredQueue.pop();
    }
}
```

## Gas Considerations

### Insertion at Position 1 (Worst Case)
- Queue length: 100
- Operations: Shift 100 elements + update 100 mappings
- Estimated gas: ~200k-300k gas
- At 200 gwei: ~0.04-0.06 ETH

**Economic impact**: If position 1 costs 10 ETH, gas is **0.4% overhead** → negligible!

### Optimization: Users Naturally Self-Select
- Front positions: High value → gas cost acceptable
- Middle positions: Moderate gas, moderate cost
- Back positions: Low gas, cheap

Gas cost scales with value, creating natural equilibrium.

## Frontend Integration

### Key View Functions

```solidity
// Get queue slice for pagination
getFeaturedInstances(startIndex, endIndex) → (address[] instances, uint256 total)

// Get position details
getPromotionInfo(instance) → (RentalSlot, position, renewalDeposit, isExpired)

// Preview pricing
getPositionRentalPrice(position) → uint256 price
calculateRentalCost(position, duration) → uint256 totalCost
calculateBumpCost(currentPos, targetPos, additionalDuration) → uint256 cost

// Position history
positionDemand[position] → (lastPrice, lastTime, totalRentals)
```

### Display Strategy

**Leaderboard view**:
```
🥇 Position 1: ProjectA (expires: 2 days)
   Current price: 0.005 ETH | Your credit: 0.003 ETH | Bump cost: 0.002 ETH

🥈 Position 2: ProjectB (expires: 5 days) ← You are here
   Bump to #1: 0.002 ETH | Renew 7d: 0.0018 ETH

🥉 Position 3: ProjectC (expires: 1 day)
   Likely to expire soon! Position will open up.
```

**Competitive pricing indicator**:
- Green: "Low competition - base price"
- Yellow: "Moderate competition - 2-5x base"
- Red: "High competition - 5x+ base"

## Success Metrics

### Protocol Health
- **Total revenue**: Sum of all rentals + bumps
- **Revenue per position**: Track hot spots
- **Average rental duration**: Longer = more stable
- **Bump frequency**: Higher = more competitive

### User Engagement
- **Unique renters**: How many projects participating
- **Repeat actions**: Bumps indicate engagement
- **Auto-renewal rate**: % using deposits
- **Cleanup frequency**: Bot participation

### Economic Efficiency
- **Price discovery speed**: Time to equilibrium
- **Position utilization**: % of queue actively rented
- **Competitive intensity**: Average actions per position
- **Revenue concentration**: Top 10 vs bottom 10 positions

## Future Enhancements (Optional)

### 1. Dutch Auction Decay
- Prices slowly decay over time without activity
- Brings "hot" positions back to base after cooling
- Formula: `price × (0.95)^(daysSinceLastAction)`

### 2. Position Swapping
- Allow two renters to swap positions
- Useful for negotiated arrangements
- Requires both parties' consent

### 3. Bulk Position Purchase
- Buy multiple positions at once (e.g., positions 1-5)
- Discount for bulk purchase
- Locks out competition for entire tier

### 4. Time-of-Day Pricing
- Higher prices during peak traffic hours
- Lower prices at night
- Maximize revenue extraction

### 5. Referral System
- Projects can refer others to join queue
- Referrer gets % of referred project's rental fees
- Viral growth mechanism

## Security Considerations

### Reentrancy Protection
- All state-changing functions use `nonReentrant` modifier
- ETH transfers happen AFTER state updates
- Use checks-effects-interactions pattern

### Overflow Protection
- Solidity 0.8+ has built-in overflow checks
- Use `require()` for boundary conditions
- Cap maximum prices to prevent runaway growth

### Front-Running Mitigation
- Prices are deterministic (no hidden state)
- Users can see exact cost before transaction
- No MEV opportunity besides standard priority fees

### Access Control
- Position ownership verified by `renter` field
- Only renter can bump/renew their position
- Only owner can force-remove (emergency only)

## Testing Strategy

### Unit Tests
- ✅ Rental at each position type (front, middle, back)
- ✅ Position shifting correctness
- ✅ Credit calculation accuracy
- ✅ Competitive price progression (1.2x per action)
- ✅ Renewal with discount
- ✅ Auto-renewal with deposits
- ✅ Cleanup with rewards
- ✅ Queue compaction

### Integration Tests
- ✅ 2-project competition scenario
- ✅ 3-project scenario (verify Charlie pays more than Bob)
- ✅ Multi-day bumping battle
- ✅ Mixed actions (rentals + bumps + renewals)
- ✅ Full queue cleanup cycle

### Edge Cases
- ✅ Empty queue rental
- ✅ Single-item queue operations
- ✅ Max queue size reached
- ✅ Expired rental cleanup
- ✅ Insufficient funds for auto-renewal
- ✅ Attempting to bump to invalid position
- ✅ Multiple cleanups in succession

## Conclusion

This competitive queue system creates a **dynamic marketplace** for visibility where:

1. ✅ **Early adopters pay pennies** (0.001 ETH base)
2. ✅ **Competition drives prices up** (20% per action)
3. ✅ **Even 2 projects create value** (through bumping battles)
4. ✅ **Fair credit system** (time-proportional refunds)
5. ✅ **Self-maintaining** (incentivized cleanup)
6. ✅ **Scalable economics** (gas cost negligible for high-value positions)

The system captures maximum value from competitive demand while remaining fair to early adopters and providing clear price discovery mechanisms.
