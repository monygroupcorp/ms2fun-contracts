# Utilization-Based Pricing Demo

## Overview

The competitive queue now implements **utilization-based pricing** where the base price increases as the queue fills up. This captures value from the entire list appreciating as it becomes more popular.

## Pricing Formula

```
Adjusted Base Price = basePrice × (1 + utilization)

Where:
- basePrice = 0.001 ETH (configurable)
- utilization = queueLength / maxQueueSize
- maxQueueSize = 100 (default)
```

## Example Scenarios

### Scenario 1: Empty Queue (Just Starting)
```
Queue: 0/100 (0% utilization)
Utilization factor: 0%

Position 1 price: 0.001 × (1 + 0%) = 0.001 ETH
Position 2 price: 0.001 × (1 + 0%) = 0.001 ETH
Position 10 price: 0.001 × (1 + 0%) = 0.001 ETH

💡 Early adopters pay base price!
```

### Scenario 2: 10 Projects Listed
```
Queue: 10/100 (10% utilization)
Utilization factor: 10%

Adjusted base: 0.001 × (1 + 10%) = 0.0011 ETH

Position 1: 0.0011 ETH (or higher if competitive)
Position 5: 0.0011 ETH (or higher if competitive)
Position 10: 0.0011 ETH (or higher if competitive)

💰 10% appreciation across the board!
```

### Scenario 3: Half Full (50 Projects)
```
Queue: 50/100 (50% utilization)
Utilization factor: 50%

Adjusted base: 0.001 × (1 + 50%) = 0.0015 ETH

Now imagine position 1-3 have a bidding war:
- Position 1: 0.005 ETH (competitive battle)
- Position 2: max(0.0015, competitive) = 0.0015+ ETH
- Position 3: max(0.0015, competitive) = 0.0015+ ETH
- Position 20: 0.0015 ETH
- Position 50: 0.0015 ETH

💎 Even position 50 is now 50% more expensive!
```

### Scenario 4: Nearly Full (90 Projects)
```
Queue: 90/100 (90% utilization)
Utilization factor: 90%

Adjusted base: 0.001 × (1 + 90%) = 0.0019 ETH

Position 1: Likely in heated competition (>> 0.0019 ETH)
Position 10: 0.0019+ ETH
Position 50: 0.0019 ETH
Position 89: 0.0019 ETH
Position 90: 0.0019 ETH

🚀 Last position is 90% more expensive than base!
```

### Scenario 5: Full Queue (100 Projects)
```
Queue: 100/100 (100% utilization)
Utilization factor: 100%

Adjusted base: 0.001 × (1 + 100%) = 0.002 ETH

Every position: Minimum 0.002 ETH (2x original base!)

🔥 Maximum scarcity pricing - queue is full!
```

## Value Capture Comparison

### Old System (Flat Base Price)
```
Queue with 50 projects
Position 1: Competitive (e.g., 0.005 ETH)
Position 2-50: 0.001 ETH each

Total potential from positions 2-50: 49 × 0.001 = 0.049 ETH
```

### New System (Utilization-Based)
```
Queue with 50 projects (50% utilization)
Position 1: Competitive (e.g., 0.005 ETH)
Position 2-50: 0.0015 ETH each (50% premium from utilization)

Total potential from positions 2-50: 49 × 0.0015 = 0.0735 ETH

💰 Extra revenue captured: 0.0245 ETH (50% more!)
```

## Key Benefits

### 1. **Fair Value Capture**
- When the list is hot, ALL positions appreciate
- Reflects the true market value of being on a popular list
- No more underpriced back positions

### 2. **Early Adopter Friendly**
- Empty queue = base price (0.001 ETH)
- No penalty for being first
- Incentivizes early adoption

### 3. **Predictable Scaling**
- Linear relationship: utilization directly affects price
- Users can see exactly how prices will change
- Transparent formula

### 4. **Competitive Pricing Still Works**
- Utilization sets the floor price
- Position-specific battles can drive prices higher
- Both systems work together

### 5. **Natural Scarcity Signal**
- Full queue (100%) = 2x base price
- Clear indication of popularity
- Encourages higher-value projects as list fills

## Frontend Display Example

```
🏆 Featured Projects Queue

Utilization: 45/100 (45% full)
Base Price: 0.00145 ETH (45% premium)

┌─────────────────────────────────────────────┐
│ #1  ProjectA  (expires in 5 days)          │
│     💰 Current: 0.008 ETH                   │
│     🔄 Bump cost: 0.0096 ETH                │
├─────────────────────────────────────────────┤
│ #2  ProjectB  (expires in 3 days)          │
│     💰 Current: 0.0017 ETH                  │
│     🔄 Bump to #1: 0.0064 ETH               │
├─────────────────────────────────────────────┤
│ #3  ProjectC  (expires in 6 days)          │
│     💰 Current: 0.00145 ETH (base)          │
│     🔄 Bump to #1: 0.0072 ETH               │
└─────────────────────────────────────────────┘

💡 Tip: Queue is 45% full - prices 45% above minimum!
```

## API Usage

### Check Current Utilization
```solidity
(
    uint256 utilization,  // 4500 (45%)
    uint256 adjustedBase, // 0.00145 ETH
    uint256 queueLen,     // 45
    uint256 maxSize       // 100
) = masterRegistry.getQueueUtilization();

console.log("Queue is %s% full", utilization / 100);
console.log("Base price is now %s ETH", adjustedBase);
```

### Get Position Price
```solidity
uint256 pos1Price = masterRegistry.getPositionRentalPrice(1);
uint256 pos10Price = masterRegistry.getPositionRentalPrice(10);
uint256 pos50Price = masterRegistry.getPositionRentalPrice(50);

// All prices include utilization adjustment + competitive premiums
```

### Calculate Rental Cost
```solidity
uint256 cost = masterRegistry.calculateRentalCost(
    10,      // position
    7 days   // duration
);

// Returns: utilization-adjusted price × duration multiplier × bulk discount
```

## Economic Impact

### Revenue Projections

**Scenario: Popular queue with 70% utilization**

| Metric | Old System | New System | Improvement |
|--------|-----------|------------|-------------|
| Base price | 0.001 ETH | 0.0017 ETH | +70% |
| 10 non-competitive slots | 0.01 ETH | 0.017 ETH | +70% |
| 50 non-competitive slots | 0.05 ETH | 0.085 ETH | +70% |
| **Total extra revenue** | - | **+0.035 ETH per 50 slots** | **+70%** |

### Break-Even Analysis

**When does utilization pricing matter most?**

- **0-20% utilization**: Minimal impact (1-20% premium)
- **20-50% utilization**: Moderate impact (20-50% premium) ✅ Sweet spot
- **50-80% utilization**: High impact (50-80% premium) ✅✅ Major value
- **80-100% utilization**: Maximum impact (80-100% premium) ✅✅✅ Peak value

## Testing

Run integration tests to verify:

```bash
forge test --match-contract FullWorkflowIntegration -vv
```

All tests pass with utilization pricing enabled! ✅

## Configuration

Adjust these parameters to tune the pricing model:

```solidity
baseRentalPrice = 0.001 ether;  // Starting point
maxQueueSize = 100;              // Affects utilization calculation
demandMultiplier = 120;          // Competitive bidding factor (20%)
```

## Conclusion

Utilization-based pricing ensures that as the featured list becomes more valuable (more projects = more visibility), **all positions appreciate proportionally**. This captures the true market value of the real estate and prevents the value leak where back positions stayed flat while front positions heated up.

**Result**:
- ✅ Fair value capture
- ✅ Early adopter friendly
- ✅ Predictable and transparent
- ✅ Works with competitive pricing
- ✅ Natural scarcity signal

The queue is now a true dynamic marketplace! 🚀
