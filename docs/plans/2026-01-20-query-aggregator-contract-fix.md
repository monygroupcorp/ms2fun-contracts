# QueryAggregator Contract Fix: Bounds Checking

**Date:** 2026-01-20
**Status:** Pending contract fix
**Priority:** High - blocking QueryAggregator usage

## Issue

When calling `getHomePageData(offset, limit)` on the QueryAggregator contract, it throws "End index out of bounds" if `offset + limit` exceeds the total number of items in the featured queue.

### Current Behavior
```
offset = 0, limit = 20, queueLength = 5
→ Error: "End index out of bounds"
```

### Expected Behavior
```
offset = 0, limit = 20, queueLength = 5
→ Returns 5 items (clamped to available)
```

## Required Fix

In the QueryAggregator contract, add bounds clamping logic:

```solidity
// Before fetching from FeaturedQueueManager
uint256 queueLength = queueManager.queueLength();

// Clamp offset to queue bounds
if (offset >= queueLength) {
    // Return empty result if offset is past end
    return HomePageData({
        projects: new ProjectCard[](0),
        totalFeatured: queueLength,
        topVaults: topVaults,
        recentActivity: recentActivity
    });
}

// Clamp limit to remaining items
uint256 endIndex = offset + limit;
if (endIndex > queueLength) {
    endIndex = queueLength;
}
uint256 actualLimit = endIndex - offset;
```

## Affected Methods

1. **`getHomePageData(uint256 offset, uint256 limit)`** - Primary issue
2. **`getVaultLeaderboard(uint8 sortBy, uint256 limit)`** - May have similar issue with vault count

## Workaround

The client-side QueryService now has try-catch fallback that gracefully degrades to individual adapter calls when QueryAggregator fails:

```javascript
// From QueryService.js
async getHomePageData(offset = 0, limit = 20) {
    await this.initialize();
    const key = `home:${offset}:${limit}`;

    if (this.aggregatorAvailable) {
        try {
            return await this._cachedQuery(key, 'homePageData', () =>
                this.aggregator.getHomePageData(offset, limit)
            );
        } catch (error) {
            console.warn('[QueryService] QueryAggregator.getHomePageData failed, using fallback:', error.message);
            // Fall through to fallback
        }
    }

    // Fallback: use individual services
    return this._cachedQuery(key, 'homePageData', () =>
        this._fallbackGetHomePageData(offset, limit)
    );
}
```

## Testing

After contract fix, verify:
1. `getHomePageData(0, 100)` with 5 items returns 5 items
2. `getHomePageData(10, 20)` with 5 items returns empty array
3. `getHomePageData(3, 10)` with 5 items returns 2 items (indices 3,4)
4. `getVaultLeaderboard(0, 100)` with 2 vaults returns 2 vaults

## Related Files

- Contract: `contracts/src/query/QueryAggregator.sol`
- Client: `src/services/QueryService.js`
- Client: `src/services/contracts/QueryAggregatorAdapter.js`
