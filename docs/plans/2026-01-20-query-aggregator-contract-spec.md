# QueryAggregator Contract Specification
**Date:** 2026-01-20
**Status:** Ready for Implementation
**Target:** Smart Contract Team

---

## Overview

We need a new read-only contract that aggregates data from multiple registry contracts into single calls. This dramatically reduces RPC overhead for the frontend - from 80+ calls per page to 1-3 calls.

### Why This Is Needed

Current frontend query pattern for home page (20 projects):

| Step | Calls |
|------|-------|
| `getFeaturedInstances(0, 20)` | 1 |
| `getInstanceInfo(addr)` × 20 | 20 |
| `getFactoryInfoByAddress(factory)` × 20 | 20 |
| `getVaultInfo(vault)` × 20 | 20 |
| Instance dynamic data × 20 | 20 |
| **Total** | **81 RPC calls** |

With QueryAggregator:

| Step | Calls |
|------|-------|
| `getHomePageData(0, 20)` | 1 |
| **Total** | **1 RPC call** |

---

## Contract Requirements

### 1. QueryAggregator.sol

A read-only aggregator contract that references existing registries.

#### Constructor

```solidity
constructor(
    address _masterRegistry,
    address _featuredQueueManager,
    address _globalMessageRegistry
)
```

#### Dependencies

The contract needs read access to:
- `MasterRegistry` - for `getInstanceInfo()`, `getFactoryInfoByAddress()`, `getVaultInfo()`
- `FeaturedQueueManager` - for `getFeaturedInstances()`, `getRentalInfo()`
- `GlobalMessageRegistry` - for `getRecentMessages()`
- Individual instance contracts - for `getCardData()` (new method, see below)

---

## Data Structures

### ProjectCard

All data needed to render a project card in the UI.

```solidity
struct ProjectCard {
    // From MasterRegistry.InstanceInfo
    address instance;
    string name;
    string metadataURI;
    address creator;
    uint256 registeredAt;

    // From MasterRegistry.FactoryInfo (denormalized)
    address factory;
    string contractType;     // "ERC404" or "ERC1155"
    string factoryTitle;

    // From MasterRegistry.VaultInfo (denormalized)
    address vault;
    string vaultName;

    // From instance.getCardData() (dynamic)
    uint256 currentPrice;
    uint256 totalSupply;
    uint256 maxSupply;       // 0 = unlimited
    bool isActive;

    // From FeaturedQueueManager
    uint256 featuredPosition; // 0 = not featured
    uint256 featuredExpires;
}
```

### VaultSummary

Compact vault info for leaderboards.

```solidity
struct VaultSummary {
    address vault;
    string name;
    uint256 tvl;             // From vault.accumulatedFees()
    uint256 instanceCount;   // From VaultInfo.instanceCount
}
```

### Portfolio Structures

For user portfolio page.

```solidity
struct ERC404Holding {
    address instance;
    string name;
    uint256 tokenBalance;
    uint256 nftBalance;
    uint256 stakedBalance;
    uint256 pendingRewards;
}

struct ERC1155Holding {
    address instance;
    string name;
    uint256[] editionIds;
    uint256[] balances;
}

struct VaultPosition {
    address vault;
    string name;
    uint256 contribution;
    uint256 shares;
    uint256 claimable;
}
```

---

## Required Methods

### getHomePageData

Single call for entire home page.

```solidity
/// @notice Fetches all data needed for the home page in one call
/// @param offset Starting index in featured queue
/// @param limit Number of projects to return
/// @return projects Fully populated ProjectCard array
/// @return totalFeatured Total count in featured queue (for pagination)
/// @return topVaults Top 3 vaults by TVL
/// @return recentActivity Last 5 global messages
function getHomePageData(uint256 offset, uint256 limit)
    external
    view
    returns (
        ProjectCard[] memory projects,
        uint256 totalFeatured,
        VaultSummary[] memory topVaults,
        GlobalMessage[] memory recentActivity
    );
```

**Implementation logic:**
1. Call `featuredQueueManager.getFeaturedInstances(offset, limit)` → addresses
2. For each address, hydrate into ProjectCard (see `_hydrateProject` below)
3. Call `_getTopVaults(3)` for vault leaderboard
4. Call `globalMessageRegistry.getRecentMessages(5)` for activity

### getProjectCardsBatch

Batch query for arbitrary project addresses.

```solidity
/// @notice Fetches ProjectCard data for multiple instances
/// @param instances Array of instance addresses
/// @return Fully populated ProjectCard array
function getProjectCardsBatch(address[] calldata instances)
    external
    view
    returns (ProjectCard[] memory);
```

**Use case:** Frontend has addresses from search/filter, needs full data.

### getPortfolioData

Single call for user's complete portfolio.

```solidity
/// @notice Fetches all holdings for a user across all projects and vaults
/// @param user User address to query
/// @return erc404Holdings All ERC404 token/NFT holdings
/// @return erc1155Holdings All ERC1155 edition holdings
/// @return vaultPositions All vault benefactor positions
/// @return totalClaimable Sum of all claimable rewards (ETH)
function getPortfolioData(address user)
    external
    view
    returns (
        ERC404Holding[] memory erc404Holdings,
        ERC1155Holding[] memory erc1155Holdings,
        VaultPosition[] memory vaultPositions,
        uint256 totalClaimable
    );
```

**Implementation logic:**
1. Get all instances from `masterRegistry.allInstances` (or iterate)
2. For each instance, check user balance
3. If balance > 0, add to appropriate holdings array
4. Get all vaults, check `getBenefactorShares(user)`
5. If shares > 0, add to vaultPositions
6. Sum all claimable amounts

**Note:** This may need pagination for very large user portfolios or many instances.

### getVaultLeaderboard

Vault rankings for vault explorer page.

```solidity
/// @notice Fetches ranked vault list
/// @param sortBy 0 = by TVL, 1 = by popularity (instance count)
/// @param limit Number of vaults to return
/// @return Sorted VaultSummary array
function getVaultLeaderboard(uint8 sortBy, uint256 limit)
    external
    view
    returns (VaultSummary[] memory);
```

---

## Internal Helper: _hydrateProject

Logic to convert an instance address into a full ProjectCard.

```solidity
function _hydrateProject(address instance)
    internal
    view
    returns (ProjectCard memory card)
{
    // 1. Get registry info
    IMasterRegistry.InstanceInfo memory info =
        masterRegistry.getInstanceInfo(instance);

    // 2. Get factory info
    IMasterRegistry.FactoryInfo memory factoryInfo =
        masterRegistry.getFactoryInfoByAddress(info.factory);

    // 3. Get vault info
    IMasterRegistry.VaultInfo memory vaultInfo =
        masterRegistry.getVaultInfo(info.vault);

    // 4. Get dynamic data from instance
    (uint256 price, uint256 supply, uint256 maxSupply, bool active) =
        IInstance(instance).getCardData();

    // 5. Get featured status
    (, uint256 position, , bool expired) =
        featuredQueueManager.getRentalInfo(instance);

    // 6. Assemble card
    card = ProjectCard({
        instance: instance,
        name: info.name,
        metadataURI: info.metadataURI,
        creator: info.creator,
        registeredAt: info.registeredAt,
        factory: info.factory,
        contractType: factoryInfo.contractType,
        factoryTitle: factoryInfo.title,
        vault: info.vault,
        vaultName: vaultInfo.name,
        currentPrice: price,
        totalSupply: supply,
        maxSupply: maxSupply,
        isActive: active,
        featuredPosition: expired ? 0 : position,
        featuredExpires: 0  // Can populate if needed
    });
}
```

---

## Instance Contract Changes

Each instance type needs a new `getCardData()` method.

### IInstance Interface

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Common interface for instance card data
interface IInstance {
    /// @notice Returns data needed for project card display
    /// @return price Current price (bonding price or floor price)
    /// @return supply Current supply (bonding supply or total minted)
    /// @return maxSupply Maximum supply (0 if unlimited)
    /// @return isActive Whether project is currently active/mintable
    function getCardData()
        external
        view
        returns (
            uint256 price,
            uint256 supply,
            uint256 maxSupply,
            bool isActive
        );
}
```

### ERC404BondingInstance.getCardData()

```solidity
/// @notice Returns data needed for project card display
function getCardData()
    external
    view
    returns (
        uint256 currentPrice,
        uint256 totalSupply,
        uint256 maxSupply,
        bool isActive
    )
{
    currentPrice = getCurrentPrice();
    totalSupply = totalBondingSupply;
    maxSupply = MAX_SUPPLY;
    isActive = bondingActive && block.timestamp >= bondingOpenTime;
}
```

### ERC1155Instance.getCardData()

```solidity
/// @notice Returns data needed for project card display
function getCardData()
    external
    view
    returns (
        uint256 floorPrice,
        uint256 totalMinted,
        uint256 maxSupply,
        bool isActive
    )
{
    floorPrice = type(uint256).max;
    totalMinted = 0;
    maxSupply = 0;
    isActive = false;
    bool hasUnlimited = false;

    for (uint256 i = 1; i <= editionCount; i++) {
        Edition storage ed = editions[i];

        // Track lowest price
        if (ed.basePrice < floorPrice) {
            floorPrice = ed.basePrice;
        }

        // Sum minted
        totalMinted += ed.minted;

        // Track supply
        if (ed.supply == 0) {
            hasUnlimited = true;
        } else {
            maxSupply += ed.supply;
            if (ed.minted < ed.supply) {
                isActive = true;
            }
        }
    }

    // Handle unlimited editions
    if (hasUnlimited) {
        maxSupply = 0;  // 0 signals unlimited
        isActive = true;
    }

    // Handle no editions case
    if (floorPrice == type(uint256).max) {
        floorPrice = 0;
    }
}
```

---

## Gas Considerations

### getHomePageData

For 20 projects, this function will:
- Make ~60 internal STATICCALL operations
- Return ~20 structs with strings

**Estimated gas:** This is a view function, so no on-chain gas cost. However, RPC providers may timeout on very large responses.

**Recommendation:** Cap `limit` parameter at 50 to prevent timeout issues.

```solidity
require(limit <= 50, "Limit too high");
```

### getPortfolioData

This iterates over all instances, which could be expensive.

**Recommendations:**
1. Add pagination parameters: `offset`, `limit`
2. Or: Accept an array of instance addresses to check (frontend provides from local index)

```solidity
// Option A: Paginated
function getPortfolioData(address user, uint256 offset, uint256 limit)

// Option B: Explicit instances
function getPortfolioData(address user, address[] calldata instancesToCheck)
```

---

## Deployment Notes

1. Deploy QueryAggregator with addresses of:
   - MasterRegistry
   - FeaturedQueueManager
   - GlobalMessageRegistry

2. QueryAggregator needs no special permissions - it only makes view calls

3. Instance contracts need `getCardData()` added before QueryAggregator can call them

4. Consider deploying behind a proxy for upgradeability (new query methods may be needed)

---

## Summary Checklist

### New Contract
- [ ] `QueryAggregator.sol` with all methods above

### Instance Changes
- [ ] Add `getCardData()` to `ERC404BondingInstance.sol`
- [ ] Add `getCardData()` to `ERC1155Instance.sol`

### Interface
- [ ] Create `IInstance.sol` interface

### Deployment
- [ ] Deploy QueryAggregator
- [ ] Provide deployed address to frontend team

---

## Questions for Contract Team

1. **Portfolio pagination:** Should `getPortfolioData` be paginated, or should frontend pass specific addresses?

2. **Instance iteration:** Is `masterRegistry.allInstances` directly accessible, or do we need to iterate via `getTotalInstances()` + `getInstanceByIndex()`?

3. **Upgradeability:** Should QueryAggregator be behind a proxy for future method additions?

4. **Gas limits:** Any concerns about view function complexity for large datasets?
