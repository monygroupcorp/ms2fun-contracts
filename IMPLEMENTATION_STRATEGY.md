# MS2FUN Full Feature Implementation Strategy

**Status**: MVP Scope Definition
**Target**: Single production-ready release (no phase 1/phase 2 split)
**Date**: December 1, 2025

---

## Overview

The system ships with everything implemented. This document defines what "everything" means and the strategy for each feature.

Current state:
- ✅ Vault-hook architecture (completed)
- ✅ Basic governance structure (stubs in place)
- ⏳ **Features requiring strategy & implementation** (below)

---

## Feature 1: Vault Benefactor Staking & Fee Distribution

### Architectural Vision
Projects can voluntarily allow their ERC404 token holders to stake their position in the vault, making the token community collectively own the vault position instead of just the project creator. This creates a sustainable model where:

1. **Single Contributor** (simple): Project contributes ETH → converted to LP position → position value grows → project claims fees based on current position value
2. **Staked Contributors** (complex): ERC404 holders stake tokens → vault aggregates stakes → distributes fees based on current proportional LP position values

**Critical Detail**: Stake is NOT the initial ETH contribution. Stake is the **current value of the LP position** created from that ETH. If Project A contributed 2 ETH and their LP position is now worth 20 ETH (due to appreciation, fee accumulation, etc.), their stake is 20 ETH for fee distribution purposes.

### Current State
- SimpleBeneficiary.sol exists as Phase 1 placeholder
- Vault tracks benefactor contributions (but this is just the trigger, not the stake)
- Vault tracks LP positions with liquidity amounts
- No mechanism to value LP positions for distribution
- No proportional distribution logic
- Comment says "defer to Phase 2"

### Requirements
Vault needs to:
1. Track which benefactor owns which LP position(s)
2. Determine current value of each LP position (complex - requires pricing)
3. Distribute accumulated fees proportionally: `(benefactorPositionValue / totalPositionValue) × fees`
4. Handle multiple positions per benefactor (if they contribute multiple times)
5. Allow benefactors to claim their proportional share based on current LP values
6. Support both simple direct ETH contributions AND staked positions simultaneously

### Implementation Strategy (Option A: Simple Proportional) ✅ CHOSEN

**Mechanism** (The Math Is the Key):
```
1. Benefactor contributes ETH → vault receives it
   - ETH is converted to LP position via convertAndAddLiquidity()
   - Initial position value = contributed ETH amount
2. LP position APPRECIATES over time via:
   - Swap fees accumulating in pool
   - Token price appreciation
   - Any other value accrual
3. Stake for distribution = CURRENT LP position value
   - NOT the initial ETH contribution
   - Example: 2 ETH contributed → LP worth 2 ETH initially → LP worth 20 ETH later
             → Benefactor's stake is now 20 ETH for distribution purposes
4. Fee distribution based on current stakes:
   - Total Vault Value = sum of all LP position values
   - Benefactor Share = (benefactorLPValue / totalVaultValue) × accumulatedFees
   - Updates claimable[benefactor]
5. Benefactors call claim() to withdraw their share

Pros:
  - Simple proportional model
  - Automatically rewards long holders (their positions appreciate)
  - Clear accounting per position
  - Works for both direct ETH and staked tokens
  - No lock-up periods or artificial multipliers
  - Projects control whether to enable staking

Cons:
  - Requires LP position valuation mechanism (COMPLEX)
  - Need to query current position values from Uniswap
  - May require oracle for pricing accuracy
  (Worth the complexity for MVP)
```

**Design**:
```solidity
contract VaultBenefactorDistribution {
    // Track which LP positions each benefactor owns
    mapping(address => uint256[]) public benefactorPositions; // benefactor → [positionIds]

    // Track pending rewards per benefactor
    mapping(address => uint256) public pendingClaims;

    // Get current stake of a benefactor (sum of all their LP position values)
    function getBenefactorStake(address benefactor)
        public view returns (uint256) {
        uint256 totalValue = 0;
        uint256[] memory positions = benefactorPositions[benefactor];
        for (uint256 i = 0; i < positions.length; i++) {
            totalValue += getLPPositionValue(positions[i]);
        }
        return totalValue;
    }

    // Get total vault value (sum of all LP positions)
    function getTotalVaultValue()
        public view returns (uint256) {
        // Iterate all benefactors, sum all position values
        // Returns total value across entire vault
    }

    // CRITICAL: Get current value of an LP position
    // This is where most complexity lives
    function getLPPositionValue(uint256 positionId)
        public view returns (uint256) {
        // Query Uniswap PositionManager for position
        // Get token0 and token1 amounts
        // Price via oracle or pool pricing
        // Return (token0Value + token1Value) in ETH
        // Account for accumulated fees
    }

    // Called by vault when fees accumulate
    function onFeeAccumulated(uint256 amount) external {
        // Get total vault value at this moment
        uint256 totalValue = getTotalVaultValue();
        require(totalValue > 0, "No liquidity in vault");

        // Calculate and distribute proportionally
        // For each benefactor, calculate share = (stake / total) × fees
        // Updates pendingClaims[benefactor]
    }

    // Benefactors claim their accumulated fees
    function claimRewards() external returns (uint256) {
        uint256 amount = pendingClaims[msg.sender];
        require(amount > 0, "No rewards to claim");
        pendingClaims[msg.sender] = 0;
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");
        return amount;
    }
}
```

**The Valuation Challenge** (Key Requirement):
```
This is the critical piece that makes fee distribution work correctly.

getLPPositionValue() must return current USD-equivalent value of:
- Token0 amount in position (account for price changes)
- Token1 amount in position (account for price changes)
- Uncollected fees (user has earned)

Options for implementation:
1. Query Uniswap PositionManager + on-chain pool pricing
   - Complex: Requires decoding ticks, calculating sqrt prices
   - Accurate: Uses actual pool state

2. Oracle-based valuation
   - Chainlink: Get ETH/token prices, calculate position value
   - Simpler: Less on-chain computation
   - Risk: Oracle dependency, price staleness

3. Simple approximation (MVP)
   - Store position entry value
   - Track fee accumulation separately
   - Current value ≈ entry value + accumulated fees
   - Limitation: Doesn't account for token price appreciation/depreciation

Recommended for MVP: Start with option 3, upgrade to option 1/2 post-launch
```

**Scope**:
- [ ] Create VaultBenefactorDistribution contract
- [ ] Implement benefactor position tracking (benefactor → [positionIds])
- [ ] Implement LP position valuation mechanism
  - Query position from Uniswap PositionManager
  - Determine token0/token1 values
  - Price tokens (oracle or pool-based)
  - Sum fees + token values
- [ ] Implement total vault value calculation
- [ ] Implement proportional fee distribution logic
  - On fee accumulation: (benefactorStake / totalStake) × fees
  - Update pendingClaims for each benefactor
- [ ] Add claimRewards() function for benefactors
- [ ] Emit events for analytics
- [ ] Write comprehensive tests (20+ test cases)
  - LP position valuation accuracy
  - Single benefactor distribution
  - Multiple benefactors with different position values
  - Position value appreciation over time (simulated)
  - Edge cases (zero value, single position, many positions)
- [ ] Vault integration (plug into beneficiaryModule)

---

## Feature 2: Master Registry Featured Tier System

### Current State
- MasterRegistryV1.sol has tier state variables created
- `instanceFeaturedTier` mapping exists
- `tierPricing` mapping with 3 tiers
- Base price = 0.1 ETH, 2% increase per tier
- No purchase logic
- No tier enforcement in instance listing

### Requirements
Frontend depends on:
1. List instances ranked by: **tier DESC, registeredAt DESC**
2. Featured instances (tier >= 1) appear first
3. Non-featured (tier 0) below them, newest first
4. Support pagination (startIndex, endIndex)
5. Implemented in `getInstancesByTierAndDate()` ✅ (already done!)

### Implementation Strategy

**The Listing is Done** ✅
- `getInstancesByTierAndDate()` already implemented
- Separates featured vs non-featured
- Sorts by tier DESC then date DESC
- Returns paginated results

**What's Missing**: Tier Purchase Logic

**Tier System Design**:
```
Tier 0: Not featured (free, anyone can register)
Tier 1: Featured - 0.1 ETH → 0.102 ETH
Tier 2: Premium - 0.2 ETH → 0.204 ETH
Tier 3: Elite   - 0.3 ETH → 0.306 ETH

Purchase mechanism:
1. Instance owner calls purchaseFeaturedPromotion(tier)
2. Pays current price
3. Tier set to that level
4. Price increases for next buyer (2% utilization increase)
5. Time-based expiration (e.g., 30 days)
```

**Scope**:
- [ ] Implement `purchaseFeaturedPromotion(tier)` in MasterRegistryV1
  - Validate tier (1-3)
  - Check price
  - Update instance tier
  - Record purchase time
  - Emit event
- [ ] Implement tier expiration check
  - If expired, reset to tier 0
  - Check happens during listing
- [ ] Implement dynamic pricing
  - Each purchase increases price 2%
  - Track utilization rate
  - Update tierPricing state
- [ ] Write tests for:
  - Tier purchasing
  - Price increases
  - Expiration logic
  - Listing order verification
  - Edge cases (multiple purchases, overlaps, etc)

**Integration Point**: Already wired to `getInstancesByTierAndDate()` ✅

---

## Feature 3: EXEC Token Voting on Master Registry

### Current State
- FactoryApprovalGovernance contract exists (separate module)
- Handles factory application voting
- Uses EXEC token for voting power (1 token = 1 vote)
- Voting power = current balance (not delegated)
- Quorum = 1000 EXEC tokens
- Decision: approvalVotes > rejectionVotes AND quorum met

### Requirements (From notes.md)
- EXEC token holders vote on factory applications
- 1 EXEC = 1 vote
- Voting power = token balance at voting time
- Quorum: 1000 EXEC tokens required
- Approval: more votes for than against AND quorum met

### Implementation Strategy

**Status**: Architecture already implemented! ✅

**What's done**:
- FactoryApprovalGovernance contract
- Application submission with 0.1 ETH fee
- Vote casting with EXEC balance checks
- Quorum enforcement
- Application finalization
- Auto-registration in MasterRegistry

**What needs completion**:
- [ ] Test coverage for voting paths
  - Submit application
  - Vote (for/against)
  - Check voting power
  - Finalize (pass/fail scenarios)
- [ ] Hook up to MasterRegistry
  - applyForFactory() delegates to governance
  - finalizeApplication() checks governance
- [ ] Events and tracking
  - Ensure all votes tracked
  - Analytics endpoints

**Scope**:
- [ ] Write comprehensive voting tests
- [ ] Verify vote tallying logic
- [ ] Test edge cases (tie votes, no voters, expired voting)
- [ ] Integration tests with MasterRegistry
- [ ] Confirm auto-registration works

---

## Feature 4: Vault Registry & Hook Management

### Current State
- Vault registry state in MasterRegistryV1 (state vars exist)
- VaultRegistry.sol exists as module
- Hooks are now vault-owned (recent redesign)
- Immutable hook per vault (1:1 relationship)

### Requirements
- Register vaults with fee (0.05 ETH)
- Store vault metadata (name, URI)
- List vaults
- Query vault info
- Track hook associated with vault
- Active/inactive states

### Implementation Strategy

**Status**: Core architecture done, needs completion

**What's implemented**:
- Vault ownership model (hook created in constructor)
- Vault can call `getHook()` to retrieve its hook
- Hook receives taxes, sends benefactor info to vault

**What needs completion**:
- [ ] Vault registration in MasterRegistry
  - Add `registerVault()` function
  - Track vault metadata
  - Store hook address reference
  - Emit VaultRegistered event
- [ ] Vault querying
  - `getVaultInfo(address vault)` - retrieve metadata
  - `getVaultsByCreator(address creator)` - list creator's vaults
  - `isVaultRegistered(address vault)` - check if valid
- [ ] Vault deactivation
  - `deactivateVault()` - mark inactive
  - Prevents registration of new instances
  - Retains historical data
- [ ] Hook reference tracking
  - Store canonical hook address in registry
  - Validate hook exists
  - Link vault → hook for discovery

**Scope**:
- [ ] Implement vault registration functions
- [ ] Add vault metadata storage
- [ ] Implement deactivation logic
- [ ] Write tests for all vault operations
- [ ] Verify hook lookup works

---

## Feature 5: Liquidity Pool Conversion (Vault Core)

### Current State
- Vault has LiquidityPosition struct
- Has AlignmentTarget struct with V3/V4 pool references
- Has `minConversionThreshold` and `minLiquidityThreshold`
- TODOs in code: "Implement actual conversion" and "Implement fee collection based on V3/V4 type"
- External contract references: v3PositionManager, v4PoolManager, router

### Requirements
Vault collects ETH → needs to convert to target token → add liquidity to pool

Flow:
1. ETH arrives in vault (from hooks, direct deposits)
2. Anyone can trigger conversion (permissionless, not just admin)
3. Swap ETH → target token (via UniswapV4)
4. Add liquidity to V3 or V4 pool
5. Track liquidity positions
6. Collect fees from positions
7. Reward the person who triggered the conversion (incentivize operation)

### Implementation Strategy (Option A: Public Rewarded Trigger) ✅ CHOSEN

**Mechanism**:
```
1. ETH accumulates in vault (from hooks, direct deposits)
2. When threshold reached, ANY address can call convertAndAddLiquidity()
3. Function swaps accumulated ETH → target token
4. Adds liquidity to pool
5. Caller gets rewarded (% of fees generated OR fixed amount)
6. Position tracked for fee collection

Pros:
  - Permissionless: Anyone can keep system running
  - Incentivized: Callers get paid for operation
  - Decentralized: No admin dependency
  - Clear control: Threshold-based execution
  - Can handle errors: Single operation, can retry

Cons:
  - Requires oracle for slippage protection
  - Need clear reward mechanism
  - Fork testing will be necessary for testing swaps
```

**Design**:
```solidity
function convertAndAddLiquidity(
    uint256 minTargetTokenAmount,  // Slippage protection
    uint256 minLiquidityOut
) external nonReentrant returns (uint256 positionId) {
    require(accumulatedETH >= minConversionThreshold, "Not enough ETH");

    // Swap ETH → target token via UniswapV4
    uint256 targetTokenAmount = swapETHForTargetToken(
        accumulatedETH,
        minTargetTokenAmount
    );

    // Add liquidity to pool
    positionId = addLiquidityToPool(
        targetTokenAmount,
        minLiquidityOut
    );

    // Calculate and transfer reward to caller
    uint256 reward = calculateReward(targetTokenAmount);
    transferRewardToCaller(msg.sender, reward);

    // Clear accumulated ETH
    accumulatedETH = 0;

    emit ConversionExecuted(msg.sender, targetTokenAmount, positionId, reward);

    return positionId;
}

// Calculate reward: % of fees or fixed amount
function calculateReward(uint256 targetTokenAmount) internal view returns (uint256) {
    // Example: 0.5% of swapped amount
    return (targetTokenAmount * 5) / 1000;
}
```

**Reward Strategy**:
- Option 1: Fixed amount per call (e.g., 0.1 ETH)
- Option 2: Percentage of swapped amount (e.g., 0.5%)
- Option 3: Percentage of fees generated (post-LP)

**Recommended**: Option 2 (0.5% of swapped amount)
- Scales with activity
- Incentivizes larger conversions
- Clear and predictable

**Dependencies**:
- UniswapV3 PositionManager interface
- UniswapV4 PoolManager interface
- SwapRouter (or V4 equivalent)
- Price oracle for slippage protection (Chainlink or on-chain TWAP)

**Scope** (MVP):
- [ ] Implement permissionless conversion function
- [ ] Implement swap logic (ETH → target token)
- [ ] Add slippage protection (oracle-based)
- [ ] Implement V3 liquidity addition
- [ ] Implement V4 liquidity addition (if needed)
- [ ] Implement reward calculation & transfer
- [ ] Track positions in array
- [ ] Implement fee collection from positions
- [ ] Handle dust amounts
- [ ] Emit events for analytics
- [ ] Fork testing (high complexity, requires isolated test environment)
- [ ] Write integration tests with mock pools
- [ ] Gas optimization

**Fork Testing Note**:
Real swap testing requires forking mainnet because:
- Need actual Uniswap pool state
- Need actual WETH/token pair pricing
- Can't mock all the pool interactions
Recommend: Separate test suite using Foundry forking mode, possibly isolated from main build

---

## Feature 6: Hook Generalization & Receiving Functions

### Current State
- UltraAlignmentV4Hook has `afterSwap()` that taxes swaps
- Vault has `receiveERC404Tax()` and `receiveERC1155Tithe()` functions
- Comments say: "restrictive, we want open-ended platform"
- Requirement: Allow any contribution, not just specific types

### Requirements (From notes.md)
- Open-ended receiving (EOAs, projects, hooks all contribute)
- ETH receive function with benefactor tracking
- Pass through benefactor info from hook

### Implementation Strategy

**Status**: Mostly done ✅

**What's implemented**:
- Vault's `receive()` function for direct ETH
- Benefactor mapping tracks all contributors
- Generic `receiveERC404Tax()` that works with any sender
- Hook passes `sender` as benefactor (not hardcoded project)

**What's missing**:
- [ ] Verify receive() function works correctly
- [ ] Test benefactor tracking with multiple sources
- [ ] Ensure hook correctly passes sender as benefactor
- [ ] Handle edge cases (0 amount, duplicate benefactors)
- [ ] Query functions for benefactor analytics
  - `getBenefactorContribution(address benefactor)`
  - `getBenefactorList()`
  - `getBenefactorCount()`

**Scope**:
- [ ] Review and test receive() function
- [ ] Add benefactor query functions
- [ ] Write tests for multi-source contributions
- [ ] Verify hook integration

---

## Summary Table

| Feature | Status | Complexity | MVP? | Est. Effort |
|---------|--------|-----------|------|-------------|
| Vault-hook redesign | ✅ Done | Low | Yes | 0 |
| Vault & hook integration | ⏳ 95% | Low | Yes | 1 day (verify+test) |
| **Benefactor staking & distribution** | ⏳ Stub | **HIGH** | Yes | **3-4 days** (LP valuation is complex) |
| Featured tier system | ⏳ Partial | Low | Yes | 1 day |
| EXEC voting | ⏳ Implemented | Medium | Yes | 1 day (tests) |
| Vault registry | ⏳ Partial | Low | Yes | 1 day |
| **LP conversion (public+rewarded)** | ⏳ Stub | **HIGH** | **Yes (CRITICAL)** | **3-5 days** + fork testing |
| ERC404 reroll | ⏳ Stub | Medium | Yes | 1-2 days |
| Hook generalization | ✅ Done | Low | Yes | 0 |

**All features ship in MVP** (fork testing in separate suite, doesn't block launch)
**Critical Path**: LP position valuation (required for both LP conversion AND fee distribution)

---

## Recommended MVP Implementation Order

1. **Fix compilation error** (1 hour)
   - Remove HookInfo references from tests
   - Get build to 0 errors
   - Unblocks full test suite

2. **LP Position Valuation Foundation** (2 days) ⚠️ **CRITICAL PATH**
   - Analyze Uniswap PositionManager interface
   - Implement position data queries
   - Implement token pricing mechanism (oracle or pool-based)
   - Create position valuation utilities
   - Test position value calculations
   - *This is prerequisite for both Feature 1 AND Feature 5*

3. **Featured tier purchasing** (1 day)
   - Add purchaseFeaturedPromotion() logic
   - Implement dynamic pricing
   - Test tier ordering

4. **Benefactor distribution** (3 days) *depends on step 2*
   - Create VaultBenefactorDistribution contract
   - Implement LP position tracking (benefactor → [positionIds])
   - Integrate position valuation mechanism
   - Implement proportional fee distribution
   - Write comprehensive tests (valuation accuracy, distribution math)
   - Plug into vault

5. **Vault registry** (1 day)
   - Add registerVault() functions
   - Implement vault queries
   - Add deactivation logic
   - Test all paths

6. **Voting tests & integration** (1 day)
   - Add voting tests
   - Verify MasterRegistry integration
   - End-to-end factory application → registration

7. **LP conversion (public+rewarded)** (3-5 days) *depends on step 2*
   - Implement convertAndAddLiquidity() public function
   - Implement ETH → target token swap
   - Implement V3/V4 liquidity addition
   - Use position valuation for tracking positions
   - Implement reward calculation & transfer
   - Set up separate fork testing suite

8. **Hook + Vault verification** (1 day)
   - Test hook creation in vault constructor
   - Test benefactor tracking
   - Test receive() function
   - Verify end-to-end flow

9. **ERC404 Reroll Feature** (1-2 days)
   - Implement token escrow mechanism
   - Implement selective reroll with NFT exemption
   - Write tests

10. **Full integration tests** (2-3 days)
    - Test all features working together
    - Scenario: Create vault → deploy hook → collect taxes → convert to LP → distribute fees → purchase tier
    - Scenario: Community-staked project → multiple stakeholders claiming fees
    - Edge cases

**Total: ~2-3 weeks of implementation work** (increased from 1 week due to LP valuation complexity)
- Critical path: LP valuation (blocks progress on 2 major features)
- Parallel work: Featured tiers, voting tests, reroll while valuation work is underway

Then: Code review, security audit, testnet deployment

---

## Deferred Features (Post-MVP)

These are nice-to-haves, can be added after launch. NOT shipping in MVP:

1. **Vote delegation** - Simple voting works, delegation is enhancement
2. **Advanced pricing** - 2% dynamic increase is sufficient for MVP
3. **Multi-token voting** - Single EXEC token voting works
4. **Weighted fee distribution** - Simple proportional is sufficient
5. **Advanced position strategies** - Basic LP is enough for MVP
6. **Automated conversion triggers** - Manual trigger only for MVP

**Shipping in MVP** (all features together):
- ✅ LP Conversion - PUBLIC and REWARDED, critical feature
- ✅ ERC404 Reroll - Token escrow mechanism
- ✅ Benefactor staking & distribution with LP position valuation
- ✅ V2 pool support - Vault accommodates legacy V2 pools for target tokens

---

## Key Decisions

1. **No phased rollout**: Everything ships together in single deploy
2. **Simple over complex**: Proportional distribution vs weighted
3. **Manual over automatic**: Async conversions vs auto-triggers
4. **Modular architecture**: Features plug into vault, can be upgraded
5. **Clear separation**: Registry ≠ Vault ≠ Governance ≠ Distribution

---

## Success Criteria

- [ ] 0 compilation errors
- [ ] 100% of tests passing
- [ ] All features have integration tests
- [ ] Code reviewed
- [ ] Security audit passed
- [ ] Deployment scripts ready
- [ ] Documentation complete
