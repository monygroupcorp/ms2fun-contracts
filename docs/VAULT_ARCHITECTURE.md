# Ultra-Alignment Vault Architecture

## Vision

The Ultra-Alignment Vault captures upside from ms2fun platform projects and converts it into aligned liquidity positions, while allowing benefactors to participate in the upside through staking.

## Core Components

### 1. Fee Collection System

#### ERC404 Projects
- **Source**: V4 hook taxes on swap volume
- **Flow**: Hook accumulates taxes → sends to vault → vault converts to alignment target liquidity
- **Tracking**: Track volume per project instance

#### ERC1155 Projects  
- **Source**: 20% tithe on creator withdrawals
- **Flow**: Instance sends ETH directly to vault → vault converts to alignment target liquidity
- **Tracking**: Track withdrawal volume per project instance

### 2. Alignment Target Conversion

The vault converts collected fees into liquidity positions for an "alignment target" (e.g., CULT):

1. **Accumulate Fees**: Collect ETH/tokens from hooks and withdrawals
2. **Convert to Target**: Swap accumulated assets → buy alignment target token
3. **Provide Liquidity**: Add liquidity to alignment target pool (V3 or V4)
4. **Track Position**: Store liquidity position NFT ID and details

### 3. Benefactor System

Benefactors stake assets (e.g., EXEC tokens) to participate in fee distribution:

- **Staking**: Stake ERC20 tokens (typically alignment target or platform tokens)
- **Fee Distribution**: Claim fees proportional to stake
- **Fee Source**: Fees collected from liquidity positions (V3 position fees)
- **Competition**: Multiple projects can see their contribution percentage

### 4. Project Contribution Tracking

Track which projects contribute to the vault:

- **Per-Project Metrics**:
  - Total volume contributed (ERC404 swap volume)
  - Total withdrawals taxed (ERC1155)
  - Total value contributed (ETH equivalent)
  - Percentage of total vault value
- **Indexable Queries**:
  - `getProjectContribution(address projectInstance)`
  - `getTopContributors(uint256 limit)`
  - `getTotalVaultValue()`

### 5. Liquidity Position Management

- **V3 Positions**: Track NFT position IDs, collect fees, increase liquidity
- **V4 Positions**: Track salt-based positions, collect fees, manage ranges
- **Pool Creation**: Create V4 pools for alignment target if they don't exist
- **Fee Collection**: Collect fees from positions and distribute to benefactors

## Data Structures

```solidity
struct ProjectContribution {
    address projectInstance;
    address projectFactory; // ERC404 or ERC1155
    uint256 totalVolume;    // Swap volume (ERC404) or withdrawal volume (ERC1155)
    uint256 totalValue;     // ETH equivalent contributed
    uint256 lastUpdated;
}

struct BenefactorStake {
    address benefactor;
    address stakingToken;   // Token being staked (e.g., EXEC)
    uint256 amount;
    uint256 stakedAt;
    uint256 claimedFees;    // Total fees claimed
}

struct LiquidityPosition {
    bool isV3;
    uint256 positionId;     // NFT ID for V3, salt for V4
    address pool;
    uint256 liquidity;
    uint256 feesAccumulated;
    uint256 lastFeeCollection;
}

struct AlignmentTarget {
    address token;
    address v3Pool;         // Existing V3 pool (if any)
    address v4Pool;         // V4 pool (created if needed)
    uint256 totalLiquidity;
    uint256 totalFeesCollected;
}
```

## Key Functions

### Fee Collection
- `receiveERC404Tax(Currency currency, uint256 amount, address projectInstance)`
- `receiveERC1155Tithe(address projectInstance)` (payable)

### Conversion & Liquidity
- `convertToAlignmentTarget()` - Swap accumulated assets → buy target → add liquidity
- `addLiquidityV3(uint256 amount0, uint256 amount1)` - Add to existing V3 pool
- `createV4PoolAndAddLiquidity()` - Create V4 pool if needed, add liquidity

### Benefactor System
- `stake(address token, uint256 amount)` - Stake tokens to become benefactor
- `unstake(address token, uint256 amount)` - Unstake tokens
- `claimFees()` - Claim proportional share of collected fees

### Project Tracking
- `getProjectContribution(address projectInstance)` - Get project metrics
- `getTopContributors(uint256 limit)` - Get top N contributors
- `getProjectRank(address projectInstance)` - Get project's rank

### Liquidity Management
- `collectV3Fees(uint256 positionId)` - Collect fees from V3 position
- `collectV4Fees(bytes32 salt)` - Collect fees from V4 position
- `increaseLiquidity(uint256 amount0, uint256 amount1)` - Add more liquidity

## Integration Points

### ERC404 Hook Integration
```solidity
// In UltraAlignmentV4Hook.afterSwap()
if (taxAmount > 0) {
    vault.receiveERC404Tax(taxCurrency, taxAmount, projectInstance);
}
```

### ERC1155 Instance Integration
```solidity
// In ERC1155Instance.withdraw()
uint256 taxAmount = (amount * 20) / 100;
vault.receiveERC1155Tithe{value: taxAmount}(address(this));
```

## Fee Distribution Math

### Benefactor Share Calculation
```
totalStaked = sum of all benefactor stakes
benefactorShare = benefactorStake / totalStaked
claimableFees = totalFeesCollected * benefactorShare - alreadyClaimed
```

### Project Contribution Calculation
```
projectContribution% = (projectTotalValue / totalVaultValue) * 100
```

## Events

```solidity
event ERC404TaxReceived(address indexed projectInstance, Currency currency, uint256 amount);
event ERC1155TitheReceived(address indexed projectInstance, uint256 amount);
event AlignmentTargetConverted(uint256 ethAmount, uint256 targetAmount, uint256 liquidity);
event BenefactorStaked(address indexed benefactor, address token, uint256 amount);
event FeesClaimed(address indexed benefactor, uint256 amount);
event ProjectContributionUpdated(address indexed projectInstance, uint256 totalValue);
```

## Security Considerations

1. **Access Control**: Only hooks and instances can send fees
2. **Reentrancy**: All state-changing functions protected
3. **Slippage Protection**: Use min amounts in swaps
4. **Position Limits**: Prevent excessive liquidity concentration
5. **Fee Claim Limits**: Prevent front-running fee claims

## Gas Optimization

1. **Batch Operations**: Batch fee collections
2. **Lazy Evaluation**: Don't convert on every small fee
3. **Thresholds**: Only convert when threshold met
4. **Storage Packing**: Pack structs efficiently

