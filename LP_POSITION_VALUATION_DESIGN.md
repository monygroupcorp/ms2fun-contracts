# LP Position Valuation Design
**Date**: December 1, 2025
**Status**: Design Phase - Ready for Implementation

---

## Problem Statement

We need to track benefactor contributions and their LP position values to enable proportional fee distribution. The challenge:
- **Per-benefactor ETH tracking**: When ETH comes in, which benefactor owns it?
- **LP conversion**: When we convert ETH → target token → liquidity, how do we calculate position value?
- **Value varies by pool type**:
  - **V4**: Uses concentrated liquidity (tickLower, tickUpper) - position is NFT-like but stored in pool
  - **V3**: Uses concentrated liquidity (NFT-based positions managed by PositionManager)
  - **V2**: Uses constant product AMM (LP tokens represent share)
- **Per-benefactor LP tracking**: After conversion, which benefactor owns what LP value?

## Key Insight

The accounting must track three phases:

```
Phase 1: ETH Accumulation
  benefactor1 → 10 ETH
  benefactor2 → 5 ETH
  Total: 15 ETH (accumulatedETH)

Phase 2: Conversion (Anyone can trigger)
  convertAndAddLiquidity() called
  - Swap 15 ETH → 150 TARGET tokens
  - Add 150 TARGET + some WETH to pool
  - Get back LP position (V3/V4 NFT or V2 tokens)

Phase 3: Distribution Basis
  Calculate per-benefactor LP value
  benefactor1 stake: 10/15 = 66.67%
  benefactor2 stake: 5/15 = 33.33%

  accumulatedFees = 100 ETH
  benefactor1 gets: 66.67% × 100 = 66.67 ETH
  benefactor2 gets: 33.33% × 100 = 33.33 ETH
```

---

## Data Structures

### 1. Track ETH Contributions Per Benefactor

```solidity
struct BenefactorETHSnapshot {
    uint256 ethContributedThisRound;  // ETH before latest conversion
    uint256 lpValueShare;             // % of LP position value after conversion
}

mapping(address => BenefactorETHSnapshot) public benefactorSnapshots;
```

### 2. LP Position Valuation

Each pool type needs different valuation:

```solidity
enum PoolType { V4, V3, V2 }

struct LPPositionValue {
    PoolType poolType;
    uint256 positionId;      // V3 NFT ID or V4 salt
    address pool;
    uint256 amount0;         // Current amount of token0 in position
    uint256 amount1;         // Current amount of token1 in position
    uint256 feesFaccrued;    // Uncollected fees
    uint256 lastUpdated;     // Block number for freshness
}

// Track per pool type
mapping(address => LPPositionValue[]) public v3Positions;
mapping(bytes32 => LPPositionValue) public v4Positions;
mapping(address => LPPositionValue) public v2Positions;
```

---

## Valuation Method Per Pool Type

### V4 Liquidity Valuation

**Challenge**: V4 uses concentrated liquidity with specific tick ranges.

**Method**: Query pool state directly
```solidity
function getV4PositionValue(
    IPoolManager poolManager,
    bytes32 positionKey
) internal view returns (uint256 amount0, uint256 amount1, uint256 fees) {
    // Positions stored as: keccak256(abi.encode(poolId, owner, tickLower, tickUpper))
    // Query pool.positions[positionKey] to get:
    // - liquidity (amount of liquidity in ticks)
    // - feeGrowthInside0Last, feeGrowthInside1Last (fee tracking)

    // Calculate position value:
    // amount0 = liquidity * (sqrtPrice(tickCurrent) - sqrtPrice(tickLower)) / Q96
    // amount1 = liquidity / (sqrtPrice(tickCurrent) - sqrtPrice(tickLower)) * Q96
}
```

**Data needed**:
- Pool state (current tick, sqrtPrice)
- Position liquidity amount
- Tick boundaries (tickLower, tickUpper)

---

### V3 Liquidity Valuation

**Challenge**: Positions are NFTs managed by PositionManager. Need to query manager state.

**Method**: Query PositionManager contract
```solidity
function getV3PositionValue(
    address positionManager,
    uint256 tokenId
) internal view returns (uint256 amount0, uint256 amount1, uint256 fees) {
    // PositionManager stores in positions[tokenId]:
    // - nonce, operator, token0, token1, fee, tickLower, tickUpper
    // - liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128
    // - tokensOwed0, tokensOwed1

    // Calculate position value from pool state + position data:
    // Similar to V4 but need to account for fee tier
}
```

**Data needed**:
- Position NFT metadata (from PositionManager)
- Pool state (from pool contract)
- Token0/Token1 addresses and current prices

---

### V2 Liquidity Valuation

**Challenge**: Simpler but need total reserves and user's LP token balance.

**Method**: Direct pool query
```solidity
function getV2PositionValue(
    address v2Pool,
    address lpTokenHolder
) internal view returns (uint256 amount0, uint256 amount1) {
    // V2 pool state:
    uint256 reserve0 = IERC20(pool.token0()).balanceOf(v2Pool);
    uint256 reserve1 = IERC20(pool.token1()).balanceOf(v2Pool);
    uint256 totalSupply = IERC20(v2Pool).totalSupply();
    uint256 userLPBalance = IERC20(v2Pool).balanceOf(lpTokenHolder);

    // User's share of each token:
    // amount0 = (userLPBalance / totalSupply) * reserve0
    // amount1 = (userLPBalance / totalSupply) * reserve1
}
```

**Data needed**:
- LP token balance
- Pool reserves
- Total LP supply

---

## Implementation Flow

### Step 1: ETH Accumulation (Already Implemented)

```solidity
benefactorContributions[benefactor] += ethAmount
accumulatedETH += ethAmount
```

### Step 2: Conversion Trigger (Public, Rewarded)

```solidity
function convertAndAddLiquidity(
    uint256 minOut,
    PoolType poolType
) external nonReentrant returns (uint256 lpValue) {
    require(accumulatedETH >= minConversionThreshold, "Insufficient ETH");

    // Take snapshot of current contributions BEFORE conversion
    _createContributionSnapshot();

    // Convert accumulated ETH
    uint256 swappedAmount = _swapETHToTarget();

    // Add liquidity (returns position value)
    lpValue = _addLiquidityToPool(poolType);

    // Reward caller (0.5% of swapped amount)
    uint256 reward = (swappedAmount * 5) / 1000;
    payable(msg.sender).transfer(reward);

    // Clear accumulation
    accumulatedETH = 0;

    emit LiquidityConverted(swappedAmount, lpValue);
    return lpValue;
}
```

### Step 3: Snapshot Benefactor Stakes

```solidity
function _createContributionSnapshot() internal {
    uint256 totalETH = _calculateTotalETHWithdrawn(); // Sum of all withdrawals to LP

    for (uint256 i = 0; i < registeredBenefactors.length; i++) {
        address benefactor = registeredBenefactors[i];
        BenefactorContribution memory contrib = benefactorContributions[benefactor];

        // Calculate this benefactor's stake as % of total
        uint256 stakePercent = (contrib.totalETHContributed * 1e18) / totalETH;

        benefactorSnapshots[benefactor] = BenefactorETHSnapshot({
            ethContributedThisRound: contrib.totalETHContributed,
            lpValueShare: stakePercent
        });
    }
}
```

### Step 4: Value Calculation Per Pool Type

```solidity
function _addLiquidityToPool(PoolType poolType)
    internal
    returns (uint256 totalValue)
{
    if (poolType == PoolType.V4) {
        return _addLiquidityV4();
    } else if (poolType == PoolType.V3) {
        return _addLiquidityV3();
    } else {
        return _addLiquidityV2();
    }
}

// For V4:
function _addLiquidityV4() internal returns (uint256 totalValue) {
    // 1. Call router to add liquidity
    // 2. Query pool state after liquidity added
    // 3. Calculate position value using V4 formula
    // 4. Store position metadata
    // 5. Return total value
}

// For V3:
function _addLiquidityV3() internal returns (uint256 totalValue) {
    // 1. Call PositionManager.mint()
    // 2. Query PositionManager for position data
    // 3. Query pool for price/tick data
    // 4. Calculate position value using V3 formula
    // 5. Store position metadata
    // 6. Return total value
}

// For V2:
function _addLiquidityV2() internal returns (uint256 totalValue) {
    // 1. Call router02 to add liquidity
    // 2. Get LP tokens minted
    // 3. Calculate position value (amount0 + amount1 in ETH terms)
    // 4. Store LP token tracking
    // 5. Return total value
}
```

---

## State Management Strategy

After conversion, we need to answer: "What's the current LP value per benefactor?"

**Option A: Static Snapshot (Simpler)**
- Capture LP value at conversion time
- Each benefactor's stake is fixed until next conversion
- Use for initial fee distribution
- Pro: Simple math, gas efficient
- Con: Doesn't reflect current LP value changes

**Option B: Dynamic Recalculation (More Complex)**
- Store position metadata
- Recalculate values on-demand from current pool state
- Each call queries current prices/liquidity
- Pro: Always accurate
- Con: More gas, requires external queries

**Recommendation**: Start with Option A for MVP, extend to B later.

---

## Required Uniswap Interfaces

### For V4 Operations
```solidity
// Need these from v4-core:
interface IPoolManager {
    function getPoolTickInfo(PoolId id, int24 tick)
        external view returns (TickInfo memory);

    function getPoolState(PoolId id)
        external view returns (Slot0 memory, uint256, uint256);

    struct PoolId {...}  // Pool identifier
}
```

### For V3 Operations
```solidity
// From Uniswap V3 interfaces:
interface INonfungiblePositionManager {
    function positions(uint256 tokenId)
        external view returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

interface IUniswapV3Pool {
    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        uint8 feeProtocol,
        bool unlocked
    );

    function liquidity() external view returns (uint128);
    function tickBitmap(int16) external view returns (uint256);
}
```

### For V2 Operations
```solidity
// From Uniswap V2:
interface IUniswapV2Pair {
    function getReserves()
        external view returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );

    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
}
```

---

## Implementation Order

1. **Create base data structures**
   - LPPositionValue struct
   - BenefactorETHSnapshot struct
   - Update UltraAlignmentVault state

2. **Implement V2 valuation** (Simplest)
   - Query pool reserves
   - Calculate per-benefactor share

3. **Implement V3 valuation**
   - Query PositionManager for position data
   - Query pool for price/tick
   - Calculate concentrated liquidity value

4. **Implement V4 valuation** (Most Complex)
   - Query pool for position data
   - Query pool state (sqrtPrice, ticks)
   - Calculate concentrated liquidity value

5. **Integration**: Make convertAndAddLiquidity work for all types

6. **Testing**: Unit tests for each valuation method

---

## Questions for User

Before we code, clarify:

1. **Pool Type Priority**: Which pool type should we prioritize first? (V2 → V3 → V4 or different order?)

2. **Initial LP Conversion**: For initial MVP, do we target one specific pool type, or support all three?

3. **Benefactor Tracking**:
   - Should each benefactor own their own LP position, OR
   - Should all ETH be pooled and converted together, with ownership split by %.

4. **Reward Mechanism**: Confirm 0.5% of swapped amount goes to conversion caller?

5. **Uniswap Dependency**: Do we already have V3 and V2 interfaces available, or do we need to add foundry remappings?

---

## Testing Strategy

Once clarified, we'll need:

1. **Unit Tests** (per pool type)
   - V2 position valuation
   - V3 position valuation
   - V4 position valuation

2. **Integration Tests**
   - ETH accumulation → conversion → distribution
   - Multiple benefactors
   - Fee collection post-conversion

3. **Fork Tests** (separate suite)
   - Real Uniswap pools
   - Real price discovery
   - Actual LP value changes

