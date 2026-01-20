# QueryAggregator Design Document

**Date:** 2026-01-20
**Status:** Approved for Implementation

---

## Overview

A read-only aggregator contract that reduces frontend RPC calls from 80+ per page to 1-3 calls by batching queries across MasterRegistry, FeaturedQueueManager, GlobalMessageRegistry, and instance contracts.

---

## Files to Create/Modify

### New Files
1. `src/interfaces/IInstance.sol` - Common interface for `getCardData()`
2. `src/query/QueryAggregator.sol` - Main aggregator contract (UUPS upgradeable)

### Modified Files
3. `src/master/interfaces/IMasterRegistry.sol` - Add instance enumeration methods
4. `src/master/MasterRegistryV1.sol` - Implement instance enumeration
5. `src/factories/erc404/ERC404BondingInstance.sol` - Add `getCardData()`
6. `src/factories/erc1155/ERC1155Instance.sol` - Add `getCardData()`

---

## Instance Enumeration (MasterRegistry)

Add to `IMasterRegistry.sol`:
```solidity
function getInstanceByIndex(uint256 index) external view returns (address);
function getInstanceAddresses(uint256 offset, uint256 limit) external view returns (address[] memory);
```

Add to `MasterRegistryV1.sol`:
```solidity
function getInstanceByIndex(uint256 index) external view returns (address) {
    require(index < allInstances.length, "Index out of bounds");
    return allInstances[index];
}

function getInstanceAddresses(uint256 offset, uint256 limit)
    external view returns (address[] memory instances)
{
    uint256 total = allInstances.length;
    if (offset >= total) return new address[](0);

    uint256 end = offset + limit;
    if (end > total) end = total;

    instances = new address[](end - offset);
    for (uint256 i = offset; i < end; i++) {
        instances[i - offset] = allInstances[i];
    }
}
```

---

## IInstance Interface

**File:** `src/interfaces/IInstance.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IInstance
/// @notice Common interface for instance card data across all factory types
interface IInstance {
    /// @notice Returns data needed for project card display
    /// @return price Current price (bonding price or floor price)
    /// @return supply Current supply (bonding supply or total minted)
    /// @return maxSupply Maximum supply (0 if unlimited)
    /// @return isActive Whether project is currently active/mintable
    /// @return extraData Factory-specific encoded data (decode based on contractType)
    function getCardData() external view returns (
        uint256 price,
        uint256 supply,
        uint256 maxSupply,
        bool isActive,
        bytes memory extraData
    );
}
```

### ERC404BondingInstance.getCardData()

```solidity
function getCardData() external view returns (
    uint256 currentPrice,
    uint256 totalSupply,
    uint256 maxSupply,
    bool isActive,
    bytes memory extraData
) {
    currentPrice = getCurrentPrice();
    totalSupply = totalBondingSupply;
    maxSupply = MAX_SUPPLY;
    isActive = bondingActive && block.timestamp >= bondingOpenTime;
    extraData = "";  // Reserved for future use
}
```

### ERC1155Instance.getCardData()

```solidity
function getCardData() external view returns (
    uint256 floorPrice,
    uint256 totalMinted,
    uint256 maxSupply,
    bool isActive,
    bytes memory extraData
) {
    floorPrice = type(uint256).max;
    totalMinted = 0;
    maxSupply = 0;
    isActive = false;
    bool hasUnlimited = false;

    for (uint256 i = 1; i <= editionCount; i++) {
        Edition storage ed = editions[i];

        if (ed.basePrice < floorPrice) {
            floorPrice = ed.basePrice;
        }

        totalMinted += ed.minted;

        if (ed.supply == 0) {
            hasUnlimited = true;
        } else {
            maxSupply += ed.supply;
            if (ed.minted < ed.supply) {
                isActive = true;
            }
        }
    }

    if (hasUnlimited) {
        maxSupply = 0;  // 0 signals unlimited
        isActive = true;
    }

    if (floorPrice == type(uint256).max) {
        floorPrice = 0;
    }

    extraData = "";  // Reserved for future use
}
```

---

## QueryAggregator Contract

**File:** `src/query/QueryAggregator.sol`

### Data Structures

```solidity
struct ProjectCard {
    // From MasterRegistry.InstanceInfo
    address instance;
    string name;
    string metadataURI;
    address creator;
    uint256 registeredAt;

    // From MasterRegistry.FactoryInfo
    address factory;
    string contractType;
    string factoryTitle;

    // From MasterRegistry.VaultInfo
    address vault;
    string vaultName;

    // From instance.getCardData()
    uint256 currentPrice;
    uint256 totalSupply;
    uint256 maxSupply;
    bool isActive;
    bytes extraData;

    // From FeaturedQueueManager
    uint256 featuredPosition;  // 0 = not featured
    uint256 featuredExpires;
}

struct VaultSummary {
    address vault;
    string name;
    uint256 tvl;
    uint256 instanceCount;
}

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

### Contract Structure

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract QueryAggregator is UUPSUpgradeable, Ownable {
    IMasterRegistry public masterRegistry;
    IFeaturedQueueManager public featuredQueueManager;
    IGlobalMessageRegistry public globalMessageRegistry;

    uint256 public constant MAX_QUERY_LIMIT = 50;

    function initialize(
        address _masterRegistry,
        address _featuredQueueManager,
        address _globalMessageRegistry,
        address _owner
    ) external;

    // === Main Query Methods ===

    function getHomePageData(uint256 offset, uint256 limit) external view returns (
        ProjectCard[] memory projects,
        uint256 totalFeatured,
        VaultSummary[] memory topVaults,
        GlobalMessage[] memory recentActivity
    );

    function getProjectCardsBatch(address[] calldata instances) external view returns (
        ProjectCard[] memory
    );

    function getPortfolioData(address user, address[] calldata instances) external view returns (
        ERC404Holding[] memory erc404Holdings,
        ERC1155Holding[] memory erc1155Holdings,
        VaultPosition[] memory vaultPositions,
        uint256 totalClaimable
    );

    function getVaultLeaderboard(uint8 sortBy, uint256 limit) external view returns (
        VaultSummary[] memory
    );

    // === Internal Helpers ===

    function _hydrateProject(address instance) internal view returns (ProjectCard memory);
}
```

### Method: getHomePageData

```solidity
function getHomePageData(uint256 offset, uint256 limit) external view returns (
    ProjectCard[] memory projects,
    uint256 totalFeatured,
    VaultSummary[] memory topVaults,
    GlobalMessage[] memory recentActivity
) {
    require(limit <= MAX_QUERY_LIMIT, "Limit too high");

    // 1. Get featured instances from queue
    (address[] memory featuredAddresses, uint256 total) =
        featuredQueueManager.getFeaturedInstances(offset, offset + limit);
    totalFeatured = total;

    // 2. Hydrate each into ProjectCard
    projects = new ProjectCard[](featuredAddresses.length);
    for (uint256 i = 0; i < featuredAddresses.length; i++) {
        projects[i] = _hydrateProject(featuredAddresses[i]);
    }

    // 3. Get top 3 vaults by TVL
    topVaults = _getTopVaults(3);

    // 4. Get recent activity
    recentActivity = globalMessageRegistry.getRecentMessages(5);
}
```

### Method: getVaultLeaderboard

```solidity
function getVaultLeaderboard(uint8 sortBy, uint256 limit) external view returns (
    VaultSummary[] memory vaults
) {
    require(limit <= MAX_QUERY_LIMIT, "Limit too high");

    if (sortBy == 0) {
        // Sort by TVL - delegate to existing method
        (address[] memory addrs, uint256[] memory tvls, string[] memory names) =
            masterRegistry.getVaultsByTVL(limit);

        vaults = new VaultSummary[](addrs.length);
        for (uint256 i = 0; i < addrs.length; i++) {
            IMasterRegistry.VaultInfo memory info = masterRegistry.getVaultInfo(addrs[i]);
            vaults[i] = VaultSummary({
                vault: addrs[i],
                name: names[i],
                tvl: tvls[i],
                instanceCount: info.instanceCount
            });
        }
    } else {
        // Sort by popularity - delegate to existing method
        (address[] memory addrs, uint256[] memory counts, string[] memory names) =
            masterRegistry.getVaultsByPopularity(limit);

        vaults = new VaultSummary[](addrs.length);
        for (uint256 i = 0; i < addrs.length; i++) {
            // Need to fetch TVL separately
            uint256 tvl = 0;
            try IAlignmentVault(payable(addrs[i])).accumulatedFees() returns (uint256 fees) {
                tvl = fees;
            } catch {}

            vaults[i] = VaultSummary({
                vault: addrs[i],
                name: names[i],
                tvl: tvl,
                instanceCount: counts[i]
            });
        }
    }
}
```

---

## Implementation Order

### Phase 1: Foundation (must be first)
1. Add `getInstanceByIndex()` and `getInstanceAddresses()` to IMasterRegistry
2. Implement in MasterRegistryV1
3. Create `IInstance.sol` interface

### Phase 2: Instance Changes (can be parallel)
4. Add `getCardData()` to ERC404BondingInstance
5. Add `getCardData()` to ERC1155Instance

### Phase 3: QueryAggregator (depends on Phase 1 & 2)
6. Create QueryAggregator.sol with all methods and structs

---

## Gas/Limit Considerations

- `getHomePageData`: Capped at 50 projects to prevent RPC timeouts
- `getProjectCardsBatch`: Same 50 cap
- `getPortfolioData`: Frontend responsible for passing reasonable instance list size
- All methods are `view` functions - no on-chain gas cost, but RPC providers may timeout on large responses

---

## Deployment

1. Deploy QueryAggregator implementation
2. Deploy ERC1967 proxy pointing to implementation
3. Call `initialize()` with:
   - MasterRegistry address
   - FeaturedQueueManager address
   - GlobalMessageRegistry address
   - Owner address
4. Provide proxy address to frontend team

QueryAggregator requires no special permissions - it only makes view calls to other contracts.
