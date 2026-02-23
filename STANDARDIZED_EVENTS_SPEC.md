# Standardized Events Interface Specification

**Date:** 2026-02-19
**Status:** Proposed
**Author:** Architecture Team
**Target:** Contract Team Implementation

---

## Executive Summary

Introduce standardized lifecycle and activity events across all instance types (ERC404, ERC1155, ERC721) to enable unified indexing, rich discovery UX, and future-proof extensibility. Instances continue to emit specialized events for contract logic, but ALSO emit standardized events for off-chain indexing.

**Key Benefits:**
- Unified discovery/filtering across all instance types
- Future-proof: new instance types automatically supported
- Rich UX: search, sort, filter without instance-specific logic
- Minimal gas overhead: ~1,000 gas per state transition

---

## Problem Statement

### Current Architecture
Each instance type emits specialized events:

```solidity
// ERC404BondingInstance
event BondingCurveActivated(uint256 timestamp);
event TokensPurchased(address buyer, uint256 amount, uint256 cost);
event GraduationThresholdReached(uint256 totalSupply);

// ERC1155Instance
event EditionCreated(uint256 editionId, uint256 maxSupply);
event EditionMinted(uint256 editionId, address minter, uint256 quantity);

// ERC721AuctionInstance (future)
event BidPlaced(address bidder, uint256 amount);
event AuctionEnded(address winner, uint256 finalPrice);
```

### Problems
1. **No unified view** - Indexer must know every instance type's event signatures
2. **Brittle frontend** - Discovery page has instance-type-specific filtering logic
3. **Not extensible** - Adding new instance types requires frontend code changes
4. **Manual normalization** - Frontend guesses state from specialized events

### Example: Current Discovery Page Filtering

```javascript
// Frontend has to guess instance state from specialized data
const isBonding = project.state?.includes('bonding') || project.bondingProgress;
const isDeployed = !project.state || project.state === 'deployed';

// Vault filter breaks if ERC1155 doesn't have vault field
const matchesVault = project.vault === selectedVault; // undefined for some types
```

This is **brittle** and **doesn't scale** as we add more instance types.

---

## Proposed Solution

### Dual Event System

**Continue emitting specialized events** for contract logic:
```solidity
emit TokensPurchased(buyer, amount, cost); // Still needed for contract functionality
```

**Add standardized events** for indexing:
```solidity
emit StateChanged("bonding", block.timestamp);     // Standardized lifecycle
emit ActivityLogged("purchase", msg.sender, amount); // Standardized activity
```

### Interface Definitions

#### IInstanceLifecycle (Required)

All instances MUST implement this interface:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IInstanceLifecycle
 * @notice Standardized lifecycle events for all MS2 instances
 * @dev All instance types (ERC404, ERC1155, ERC721, future) MUST implement
 */
interface IInstanceLifecycle {
    /**
     * @notice Emitted when instance transitions between lifecycle states
     * @param newState Current state as bytes32 (see State Definitions below)
     * @param timestamp Block timestamp of transition
     */
    event StateChanged(
        bytes32 indexed newState,
        uint256 timestamp
    );

    /**
     * @notice Get current instance state
     * @return Current state as bytes32
     */
    function getState() external view returns (bytes32);

    /**
     * @notice Get instance metadata for discovery/indexing
     * @return vault Associated vault address (zero address if none)
     * @return instanceType Type identifier ("erc404", "erc1155", "erc721", etc.)
     * @return creator Creator address
     */
    function getMetadata() external view returns (
        address vault,
        bytes32 instanceType,
        address creator
    );
}
```

#### State Definitions (Standardized)

```solidity
// Standard lifecycle states (use keccak256 for gas efficiency)
bytes32 constant STATE_NOT_STARTED = keccak256("not-started");
bytes32 constant STATE_MINTING = keccak256("minting");
bytes32 constant STATE_BONDING = keccak256("bonding");
bytes32 constant STATE_ACTIVE = keccak256("active");
bytes32 constant STATE_GRADUATED = keccak256("graduated");
bytes32 constant STATE_PAUSED = keccak256("paused");
bytes32 constant STATE_ENDED = keccak256("ended");

// Instance types
bytes32 constant TYPE_ERC404 = keccak256("erc404");
bytes32 constant TYPE_ERC1155 = keccak256("erc1155");
bytes32 constant TYPE_ERC721 = keccak256("erc721");
```

#### IInstanceActivity (Optional)

Instances MAY implement activity logging for rich indexing:

```solidity
/**
 * @title IInstanceActivity
 * @notice Optional activity tracking for instances
 * @dev Instances can choose to emit these for important user actions
 */
interface IInstanceActivity {
    /**
     * @notice Emitted when significant user activity occurs
     * @param activityType Type of activity (see Activity Type Definitions)
     * @param actor Address performing the action
     * @param value Numeric value associated with activity (amount, price, etc.)
     */
    event ActivityLogged(
        bytes32 indexed activityType,
        address indexed actor,
        uint256 value
    );
}
```

#### Activity Type Definitions (Recommended)

```solidity
// Standard activity types (instances can define custom ones too)
bytes32 constant ACTIVITY_PURCHASE = keccak256("purchase");
bytes32 constant ACTIVITY_MINT = keccak256("mint");
bytes32 constant ACTIVITY_TRADE = keccak256("trade");
bytes32 constant ACTIVITY_BID = keccak256("bid");
bytes32 constant ACTIVITY_CLAIM = keccak256("claim");
bytes32 constant ACTIVITY_BURN = keccak256("burn");
```

---

## Implementation Guidelines

### 1. Factory Enforcement

Factories MUST verify instances implement `IInstanceLifecycle`:

```solidity
// In ERC404Factory.createInstance()
function createInstance(...) external returns (address) {
    address instance = address(new ERC404BondingInstance(...));

    // Verify interface support
    require(
        IERC165(instance).supportsInterface(type(IInstanceLifecycle).interfaceId),
        "Instance must implement IInstanceLifecycle"
    );

    // Register in MasterRegistry
    masterRegistry.registerInstance(instance, msg.sender);

    return instance;
}
```

### 2. Instance Implementation Pattern

```solidity
contract ERC404BondingInstance is IInstanceLifecycle, ERC404, Ownable {
    bytes32 private currentState = STATE_NOT_STARTED;
    address private immutable vault;
    address private immutable creator;

    constructor(address _vault, address _creator) {
        vault = _vault;
        creator = _creator;
    }

    // IInstanceLifecycle implementation
    function getState() external view returns (bytes32) {
        return currentState;
    }

    function getMetadata() external view returns (
        address,
        bytes32,
        address
    ) {
        return (vault, TYPE_ERC404, creator);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IInstanceLifecycle).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // Internal state transition helper
    function _transitionState(bytes32 newState) internal {
        if (currentState != newState) {
            currentState = newState;
            emit StateChanged(newState, block.timestamp);
        }
    }

    // Example: Activate bonding curve
    function activateBondingCurve() external onlyOwner {
        require(currentState == STATE_NOT_STARTED, "Already started");

        // ... bonding curve logic ...

        // Emit specialized event (for contract logic)
        emit BondingCurveActivated(block.timestamp);

        // Emit standardized event (for indexing)
        _transitionState(STATE_BONDING);
    }

    // Example: Purchase tokens
    function purchaseTokens(uint256 amount) external payable {
        require(currentState == STATE_BONDING, "Not in bonding phase");

        // ... purchase logic ...

        // Emit specialized event (for contract logic)
        emit TokensPurchased(msg.sender, amount, msg.value);

        // Check if graduated
        if (totalSupply() >= graduationThreshold) {
            emit GraduationThresholdReached(totalSupply());
            _transitionState(STATE_GRADUATED);
        }
    }
}
```

### 3. State Mapping Examples

**ERC404 Bonding Instance:**
- `not-started` → Before bonding curve activated
- `bonding` → Active bonding curve phase
- `graduated` → Reached graduation threshold, liquidity deployed
- `paused` → Admin paused (if applicable)

**ERC1155 Gallery Instance:**
- `minting` → Editions being minted
- `active` → All editions created, trading open
- `ended` → Gallery closed (if applicable)

**ERC721 Auction Instance:**
- `not-started` → Before auction starts
- `active` → Auction accepting bids
- `ended` → Auction concluded

Instances can define custom states if needed, but should use standard ones when applicable.

---

## Gas Cost Analysis

### Event Emission Costs

```
Base event emission:            375 gas
Each indexed parameter:         375 gas
Non-indexed uint256:           ~256 gas (32 bytes × 8 gas/byte)
```

**StateChanged event:**
```solidity
event StateChanged(bytes32 indexed newState, uint256 timestamp);
// Cost: 375 + 375 + 256 = ~1,006 gas
```

**ActivityLogged event:**
```solidity
event ActivityLogged(bytes32 indexed activityType, address indexed actor, uint256 value);
// Cost: 375 + 375 + 375 + 256 = ~1,381 gas
```

### Impact on Operations

| Operation | Base Gas | +StateChanged | % Overhead |
|-----------|----------|---------------|------------|
| NFT Mint | 50,000 | +1,006 | +2.0% |
| Bonding Purchase | 200,000 | +1,006 | +0.5% |
| Instance Creation | 2,000,000 | +1,006 | +0.05% |

### Lifetime Gas Impact

**ERC404 Bonding Instance Lifecycle:**
1. Activate bonding: `StateChanged(STATE_BONDING)` → +1,006 gas
2. Graduate: `StateChanged(STATE_GRADUATED)` → +1,006 gas
3. Optionally pause/resume: +1,006 gas each

**Total added over lifetime: ~2,000-4,000 gas**

For a 200 ETH bonding curve instance, this is **negligible** (<0.01% of total gas).

### Optimization: Selective Emission

Emit `ActivityLogged` only for significant events:

```solidity
// Option 1: Threshold-based
if (msg.value >= 1 ether) {
    emit ActivityLogged(ACTIVITY_PURCHASE, msg.sender, amount);
}

// Option 2: Sampling (every Nth event)
if (purchaseCount % 10 == 0) {
    emit ActivityLogged(ACTIVITY_PURCHASE, msg.sender, amount);
}

// Option 3: Don't emit at all
// StateChanged is enough for most discovery needs
```

---

## Indexer Integration

### Off-Chain Indexer (Node.js Example)

```javascript
// Listen to all instances via standardized events
provider.on({
    address: null, // All contracts
    topics: [ethers.id("StateChanged(bytes32,uint256)")]
}, async (log) => {
    const event = instanceInterface.parseLog(log);
    const instanceAddress = log.address;
    const newState = event.args.newState;
    const timestamp = event.args.timestamp;

    // Update database
    await db.instances.update(instanceAddress, {
        state: ethers.toUtf8String(newState),
        lastStateChange: timestamp,
        updatedAt: Date.now()
    });
});

// Fetch metadata on first discovery
async function indexNewInstance(address) {
    const instance = new ethers.Contract(address, IInstanceLifecycle.abi, provider);
    const [vault, instanceType, creator] = await instance.getMetadata();

    await db.instances.insert({
        address,
        vault,
        type: ethers.toUtf8String(instanceType),
        creator,
        state: ethers.toUtf8String(await instance.getState()),
        discoveredAt: Date.now()
    });
}
```

### Frontend Query Example

```javascript
// Rich filtering across ALL instance types
const instances = await indexerAPI.query({
    state: "bonding",                    // Only bonding instances
    vault: "0x1234...",                  // Specific vault
    type: ["erc404", "erc721"],         // Multiple types
    orderBy: "lastStateChange",         // Sort by recent activity
    limit: 20
});

// Returns normalized data:
// [
//   {
//     address: "0xabc...",
//     name: "Cool Project",
//     type: "erc404",
//     state: "bonding",
//     vault: "0x1234...",
//     creator: "0x5678...",
//     lastStateChange: 1709251200,
//     tvl: "1250000",
//     volume24h: "50000"
//   },
//   ...
// ]
```

---

## Migration Strategy

### Phase 1: New Instances Only (Recommended Start)

**Week 1-2:**
- Define interfaces in `src/shared/interfaces/`
- Update ONE factory (ERC404Factory) to require `IInstanceLifecycle`
- Deploy updated factory to testnet
- Test with new instances

**Week 3:**
- Deploy to production
- New ERC404 instances automatically support standardized events
- Old instances continue working (no breaking changes)

### Phase 2: Indexer Prototype

**Week 4-6:**
- Build simple Node.js indexer (watches events → SQLite)
- Deploy indexer for testnet
- Expose REST API for frontend queries
- Test Discovery page with indexed data

### Phase 3: Remaining Factories

**Week 7-8:**
- Update ERC1155Factory
- Update ERC721Factory (when ready)
- All new instances across all types support standardized events

### Phase 4: Production Indexer

**Week 9-12:**
- Migrate to production-grade indexer (The Graph subgraph or custom backend)
- Add computed fields (TVL, volume, trending)
- Update frontend to use indexed data exclusively
- Deprecate direct RPC queries for discovery

### Legacy Instances

**Option A: Leave as-is**
- Legacy instances don't emit standardized events
- Indexer has special handlers for known legacy instances
- Manually populate their state/metadata in database

**Option B: Upgrade path**
- If instances are upgradeable, deploy new implementation with standardized events
- If not upgradeable, create migration script to populate indexer from specialized events

---

## Testing Requirements

### Unit Tests

```solidity
// Test state transitions emit events correctly
function testStateTransitionEmitsEvent() public {
    vm.expectEmit(true, false, false, true);
    emit StateChanged(STATE_BONDING, block.timestamp);

    instance.activateBondingCurve();

    assertEq(instance.getState(), STATE_BONDING);
}

// Test metadata returns correct values
function testGetMetadata() public {
    (address vault, bytes32 instanceType, address creator) = instance.getMetadata();

    assertEq(vault, expectedVault);
    assertEq(instanceType, TYPE_ERC404);
    assertEq(creator, expectedCreator);
}

// Test interface support
function testSupportsInterface() public {
    assertTrue(instance.supportsInterface(type(IInstanceLifecycle).interfaceId));
}
```

### Integration Tests

```solidity
// Test factory rejects instances without interface
function testFactoryRejectsNonCompliantInstance() public {
    // Deploy instance without IInstanceLifecycle
    BadInstance bad = new BadInstance();

    vm.expectRevert("Instance must implement IInstanceLifecycle");
    factory.registerInstance(address(bad));
}

// Test state transitions through full lifecycle
function testFullLifecycle() public {
    assertEq(instance.getState(), STATE_NOT_STARTED);

    instance.activateBondingCurve();
    assertEq(instance.getState(), STATE_BONDING);

    // Purchase until graduation
    instance.purchaseTokens{value: 200 ether}(graduationAmount);
    assertEq(instance.getState(), STATE_GRADUATED);
}
```

### Indexer Tests

```javascript
// Test indexer captures state changes
it('should index StateChanged events', async () => {
    await instance.activateBondingCurve();
    await indexer.sync();

    const dbInstance = await db.instances.findOne({ address: instance.address });
    expect(dbInstance.state).to.equal('bonding');
});

// Test metadata fetching
it('should fetch and store metadata', async () => {
    await indexer.indexNewInstance(instance.address);

    const dbInstance = await db.instances.findOne({ address: instance.address });
    expect(dbInstance.type).to.equal('erc404');
    expect(dbInstance.vault).to.equal(vaultAddress);
});
```

---

## Security Considerations

### 1. State Manipulation
**Risk:** Malicious instance emits fake `StateChanged` events
**Mitigation:** Indexer verifies state by calling `getState()` after receiving event

```javascript
// Don't blindly trust events
const eventState = event.args.newState;
const actualState = await instance.getState(); // Verify on-chain

if (eventState !== actualState) {
    logger.warn(`State mismatch for ${instance.address}`);
    // Use actual state, log for investigation
}
```

### 2. Interface Spoofing
**Risk:** Malicious contract claims to support `IInstanceLifecycle` but doesn't
**Mitigation:** Factory verifies via ERC165 AND calls `getState()` to confirm

```solidity
require(
    IERC165(instance).supportsInterface(type(IInstanceLifecycle).interfaceId),
    "Must support IInstanceLifecycle"
);

// Also verify it actually works
try IInstanceLifecycle(instance).getState() returns (bytes32) {
    // OK
} catch {
    revert("IInstanceLifecycle not functional");
}
```

### 3. Event Spam
**Risk:** Malicious instance emits thousands of events to bloat indexer
**Mitigation:** Rate limiting + indexer monitoring

```javascript
// Track event rate per instance
const eventsPerHour = await db.eventCounts.get(instance.address, lastHour);

if (eventsPerHour > 1000) {
    logger.warn(`High event rate from ${instance.address}`);
    // Pause indexing, flag for review
}
```

---

## Open Questions for Contract Team

1. **Interface versioning:** Should we version the interface (`IInstanceLifecycleV1`)? How do we handle future changes?

2. **MasterRegistry integration:** Should MasterRegistry also store instance metadata (vault, type, creator) for redundancy, or rely solely on instance contracts?

3. **Custom states:** Should we allow instances to define custom states beyond the standard set? How to handle in indexer?

4. **Activity logging:** Should we make `IInstanceActivity` required or keep it optional? What's the gas trade-off policy?

5. **State validation:** Should factories validate that initial state is `STATE_NOT_STARTED`, or allow instances to start in any state?

6. **Upgrade path for legacy instances:** Should we provide upgrade mechanism for existing instances, or accept they won't have standardized events?

---

## Success Metrics

**Phase 1 (Factory Update):**
- ✅ New instances emit `StateChanged` on lifecycle transitions
- ✅ `getState()` returns correct state at all times
- ✅ `getMetadata()` returns accurate vault/type/creator
- ✅ Factory rejects non-compliant instances
- ✅ Gas overhead <2% on typical operations

**Phase 2 (Indexer Prototype):**
- ✅ Indexer captures all state changes within 1 block
- ✅ Indexer API query response time <100ms
- ✅ 100% uptime over 1-week test period

**Phase 3 (Frontend Integration):**
- ✅ Discovery page filtering works across all instance types
- ✅ No instance-type-specific logic in frontend filters
- ✅ Search/filter/sort response time <500ms (vs 5-10s with RPC)

**Phase 4 (Production):**
- ✅ Handles 1,000+ instances
- ✅ <1s discovery page load time
- ✅ Support for new instance types with zero frontend changes

---

## Appendix A: Complete Interface Code

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title IInstanceLifecycle
 * @notice Standardized lifecycle events and metadata for all MS2 instances
 * @dev All instance types MUST implement this interface
 */
interface IInstanceLifecycle is IERC165 {
    /**
     * @notice Emitted when instance transitions between lifecycle states
     * @param newState Current state as bytes32 (see Constants below)
     * @param timestamp Block timestamp of transition
     */
    event StateChanged(
        bytes32 indexed newState,
        uint256 timestamp
    );

    /**
     * @notice Get current instance lifecycle state
     * @return Current state as bytes32
     */
    function getState() external view returns (bytes32);

    /**
     * @notice Get instance metadata for discovery and indexing
     * @return vault Associated vault address (zero address if none)
     * @return instanceType Type identifier (see TYPE_* constants)
     * @return creator Creator/deployer address
     */
    function getMetadata() external view returns (
        address vault,
        bytes32 instanceType,
        address creator
    );
}

/**
 * @title IInstanceActivity
 * @notice Optional activity tracking for rich indexing
 * @dev Instances MAY implement this for detailed activity logs
 */
interface IInstanceActivity {
    /**
     * @notice Emitted when significant user activity occurs
     * @param activityType Type of activity (see ACTIVITY_* constants)
     * @param actor Address performing the action
     * @param value Numeric value associated with activity
     */
    event ActivityLogged(
        bytes32 indexed activityType,
        address indexed actor,
        uint256 value
    );
}

/**
 * @title InstanceConstants
 * @notice Standard state and type constants
 */
library InstanceConstants {
    // Lifecycle States
    bytes32 public constant STATE_NOT_STARTED = keccak256("not-started");
    bytes32 public constant STATE_MINTING = keccak256("minting");
    bytes32 public constant STATE_BONDING = keccak256("bonding");
    bytes32 public constant STATE_ACTIVE = keccak256("active");
    bytes32 public constant STATE_GRADUATED = keccak256("graduated");
    bytes32 public constant STATE_PAUSED = keccak256("paused");
    bytes32 public constant STATE_ENDED = keccak256("ended");

    // Instance Types
    bytes32 public constant TYPE_ERC404 = keccak256("erc404");
    bytes32 public constant TYPE_ERC1155 = keccak256("erc1155");
    bytes32 public constant TYPE_ERC721 = keccak256("erc721");

    // Activity Types
    bytes32 public constant ACTIVITY_PURCHASE = keccak256("purchase");
    bytes32 public constant ACTIVITY_MINT = keccak256("mint");
    bytes32 public constant ACTIVITY_TRADE = keccak256("trade");
    bytes32 public constant ACTIVITY_BID = keccak256("bid");
    bytes32 public constant ACTIVITY_CLAIM = keccak256("claim");
    bytes32 public constant ACTIVITY_BURN = keccak256("burn");
}
```

---

## Appendix B: Reference Implementation

See `contracts/src/shared/interfaces/IInstanceLifecycle.sol` for production interface.

See `contracts/src/factories/erc404/ERC404BondingInstance.sol` for reference implementation.

---

## Questions?

Contact: Architecture Team
Slack: #contract-dev
Document Version: 1.0
