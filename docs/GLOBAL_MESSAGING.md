# Global Messaging System

**Version:** 1.0.0
**Last Updated:** 2025-01-01
**Status:** Production-Ready

---

## Overview

The Global Messaging System is a protocol-wide activity tracking and discovery mechanism that enables frontend clients to query all protocol activity with a single RPC call. This eliminates the need for 200+ individual queries to discover trending projects and recent activity.

### Key Benefits

- **Single-RPC Discovery**: Query all protocol activity in one call
- **Trending Detection**: Identify hot projects by message volume and frequency
- **User Engagement**: Messages create social proof and community interaction
- **Gas Efficient**: 176-bit packed metadata minimizes storage costs
- **Auto-Authorization**: Instances automatically authorized on registration
- **Scalable**: Append-only design with pagination supports unlimited growth

---

## Architecture

### Component Overview

```
┌──────────────────────────────────────────────────────────┐
│                 Global Messaging Stack                    │
└──────────────────────────────────────────────────────────┘

┌─────────────────────┐
│ MasterRegistry      │ ── Auto-authorizes instances
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│ GlobalMessage       │ ── Centralized message storage
│ Registry            │ ── Authorization system
└──────────┬──────────┘    ── Indexing & queries
           │
           ▼
┌─────────────────────┐
│ Message Packing     │ ── 176-bit optimization
│ Library             │ ── Type constants
└─────────────────────┘
```

### Data Flow

```
User Action (Buy/Mint/Sell)
    │
    ├─► Instance validates transaction
    │
    └─► If message provided:
            │
            ├─► Pack metadata (timestamp, factory, action, amount)
            │
            └─► GlobalMessageRegistry.addMessage(
                    instance,
                    sender,
                    packedData,
                    message
                )
                    │
                    ├─► Append to messages[]
                    ├─► Index in instanceMessageIds[]
                    └─► Emit MessageAdded event

Frontend Query
    │
    ├─► getRecentMessages(50)          // Protocol-wide
    ├─► getInstanceMessages(addr, 20)  // Instance-specific
    └─► getRecentMessagesPaginated()   // Large queries
```

---

## Core Contracts

### GlobalMessageRegistry.sol

**Location:** `src/registry/GlobalMessageRegistry.sol`

Centralized on-chain message storage with authorization and efficient querying.

#### Key Functions

```solidity
// Write Operations (authorized instances only)
function addMessage(
    address instance,
    address sender,
    uint256 packedData,
    string calldata message
) external returns (uint256 messageId)

// Authorization Management (owner only)
function authorizeInstance(address instance) external onlyOwner
function revokeInstance(address instance) external onlyOwner

// Query Operations (public)
function getMessage(uint256 messageId) external view returns (GlobalMessage)
function getMessageCount() external view returns (uint256)
function getRecentMessages(uint256 count) external view returns (GlobalMessage[])
function getInstanceMessages(address instance, uint256 count) external view returns (GlobalMessage[])
function getRecentMessagesPaginated(uint256 offset, uint256 limit) external view returns (GlobalMessage[])
function getInstanceMessagesPaginated(address instance, uint256 offset, uint256 limit) external view returns (GlobalMessage[])
```

#### Data Structure

```solidity
struct GlobalMessage {
    address instance;      // Which project emitted this message
    address sender;        // User who performed the action
    uint256 packedData;    // Packed metadata (176 bits used)
    string message;        // User-provided message text
}
```

#### Storage Layout

- `GlobalMessage[] public messages` - Append-only array (chronological)
- `mapping(address => uint256[]) private instanceMessageIds` - Instance indexing
- `mapping(address => bool) public authorizedInstances` - Authorization

---

### GlobalMessagePacking.sol

**Location:** `src/libraries/GlobalMessagePacking.sol`

Bit-packing library for efficient metadata storage.

#### Packed Data Layout

```
256-bit word:
┌─────────┬────────────┬────────────┬───────────┬──────────┬──────────┐
│  0-31   │   32-39    │   40-47    │   48-79   │  80-175  │ 176-255  │
├─────────┼────────────┼────────────┼───────────┼──────────┼──────────┤
│timestamp│factoryType │actionType  │ contextId │  amount  │ reserved │
│ uint32  │   uint8    │   uint8    │  uint32   │  uint96  │  80 bits │
└─────────┴────────────┴────────────┴───────────┴──────────┴──────────┘

Total: 176 bits used, 80 bits reserved for future expansion
```

#### Functions

```solidity
// Pack metadata into 256-bit word
function pack(
    uint32 timestamp,
    uint8 factoryType,
    uint8 actionType,
    uint32 contextId,
    uint96 amount
) internal pure returns (uint256 packed)

// Unpack 256-bit word into components
function unpack(uint256 packed) internal pure returns (
    uint32 timestamp,
    uint8 factoryType,
    uint8 actionType,
    uint32 contextId,
    uint96 amount
)

// Individual extractors
function getTimestamp(uint256 packed) internal pure returns (uint32)
function getFactoryType(uint256 packed) internal pure returns (uint8)
function getActionType(uint256 packed) internal pure returns (uint8)
function getContextId(uint256 packed) internal pure returns (uint32)
function getAmount(uint256 packed) internal pure returns (uint96)
```

---

### GlobalMessageTypes.sol

**Location:** `src/libraries/GlobalMessageTypes.sol`

Constants for factory and action types.

#### Factory Types

```solidity
uint8 internal constant FACTORY_ERC404 = 0;
uint8 internal constant FACTORY_ERC1155 = 1;
// Reserved: 2-255 for future factory types
```

#### Action Types

```solidity
uint8 internal constant ACTION_BUY = 0;
uint8 internal constant ACTION_SELL = 1;
uint8 internal constant ACTION_MINT = 2;
uint8 internal constant ACTION_WITHDRAW = 3;
uint8 internal constant ACTION_STAKE = 4;
uint8 internal constant ACTION_UNSTAKE = 5;
uint8 internal constant ACTION_CLAIM_REWARDS = 6;
uint8 internal constant ACTION_DEPLOY_LIQUIDITY = 7;
// Reserved: 8-255 for future action types
```

---

## Integration Guide

### Instance Integration

Instances integrate global messaging by calling `addMessage` after successful transactions:

```solidity
// ERC404BondingInstance.sol example
function buyBonding(
    uint256 amount,
    string calldata message
) external payable {
    // ... bonding curve logic ...

    // Add global message if provided
    if (bytes(message).length > 0) {
        GlobalMessageRegistry registry = _getGlobalMessageRegistry();

        uint256 packedData = GlobalMessagePacking.pack(
            uint32(block.timestamp),
            GlobalMessageTypes.FACTORY_ERC404,
            GlobalMessageTypes.ACTION_BUY,
            0,  // contextId (not used for buys)
            uint96(amount / 1e18)  // amount in whole tokens
        );

        registry.addMessage(
            address(this),  // instance
            msg.sender,     // sender
            packedData,
            message
        );
    }
}
```

### Lazy-Loaded Registry Pattern

Instances use lazy-loading to avoid repeated external calls:

```solidity
// Instance state
GlobalMessageRegistry private _cachedRegistry;

// Lazy-load helper
function _getGlobalMessageRegistry() private returns (GlobalMessageRegistry) {
    if (address(_cachedRegistry) == address(0)) {
        address registryAddr = IMasterRegistry(MASTER_REGISTRY)
            .getGlobalMessageRegistry();

        if (registryAddr != address(0)) {
            _cachedRegistry = GlobalMessageRegistry(registryAddr);
        }
    }
    return _cachedRegistry;
}
```

### Auto-Authorization

MasterRegistry automatically authorizes instances on registration:

```solidity
// MasterRegistryV1.sol
function registerInstance(
    address instance,
    uint256 factoryId,
    address creator
) external {
    // ... registration logic ...

    // Auto-authorize for global messaging
    if (globalMessageRegistry != address(0)) {
        GlobalMessageRegistry(globalMessageRegistry)
            .authorizeInstance(instance);
    }
}
```

---

## Frontend Integration

### Query Recent Activity (Protocol-Wide)

```javascript
const registry = new ethers.Contract(registryAddress, abi, provider);

// Get 50 most recent messages across all projects
const messages = await registry.getRecentMessages(50);

messages.forEach(msg => {
    const [timestamp, factoryType, actionType, contextId, amount] =
        unpackMessageData(msg.packedData);

    console.log({
        project: msg.instance,
        user: msg.sender,
        action: getActionName(actionType),
        amount: amount.toString(),
        message: msg.message,
        timestamp
    });
});
```

### Query Instance-Specific Activity

```javascript
// Get 20 most recent messages for a specific project
const projectMessages = await registry.getInstanceMessages(
    projectAddress,
    20
);

// Display project activity feed
projectMessages.forEach(msg => {
    // ... display logic ...
});
```

### Paginated Queries (Large Datasets)

```javascript
const BATCH_SIZE = 100;
let offset = 0;
let allMessages = [];

while (true) {
    const batch = await registry.getRecentMessagesPaginated(
        offset,
        BATCH_SIZE
    );

    if (batch.length === 0) break;

    allMessages = allMessages.concat(batch);
    offset += batch.length;

    if (batch.length < BATCH_SIZE) break;
}
```

### Trending Detection

```javascript
// Count messages per instance in last 100 messages
const messages = await registry.getRecentMessages(100);
const instanceCounts = {};

messages.forEach(msg => {
    instanceCounts[msg.instance] = (instanceCounts[msg.instance] || 0) + 1;
});

// Sort by activity
const trending = Object.entries(instanceCounts)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 10);  // Top 10 trending projects
```

---

## Performance Characteristics

### Gas Costs

- **addMessage**: ~30-35k gas (first message) + ~5k per additional
- **Packing overhead**: ~200 gas (in-memory operations)
- **Authorization check**: ~2.1k gas (cold SLOAD)
- **Indexing**: ~20k gas (array push to instanceMessageIds)

### Query Complexity

- **getRecentMessages(n)**: O(n) - Returns last n messages
- **getInstanceMessages(addr, n)**: O(n) - Returns last n for instance
- **getMessageCount()**: O(1) - Array length
- **getMessage(id)**: O(1) - Direct array access

### Scalability

- **Storage growth**: Linear with message count
- **Query performance**: Constant with pagination
- **Indexing overhead**: Minimal (single mapping update per message)
- **Supports**: Unlimited messages, unlimited instances

---

## Security Considerations

### Authorization

- Only authorized instances can write messages
- MasterRegistry owner controls authorization
- Auto-authorization on instance registration
- Revocation supported for compromised instances

### Input Validation

```solidity
function addMessage(...) external {
    require(authorizedInstances[msg.sender], "Not authorized");
    require(instance != address(0), "Invalid instance");
    require(sender != address(0), "Invalid sender");
    // ... message length checks handled by string type ...
}
```

### Message Content

- User-provided messages are stored on-chain
- No content filtering (caveat emptor)
- Frontend should implement content moderation
- Consider message length limits if spam becomes an issue

### Dos Protection

- Authorization prevents spam from non-instances
- Gas costs naturally limit message volume
- Pagination prevents unbounded queries
- No loops in critical paths (O(1) writes)

---

## Testing

### Unit Tests

Located in `test/base/GlobalMessagingTestBase.sol`:

```solidity
abstract contract GlobalMessagingTestBase is Test {
    GlobalMessageRegistry public globalRegistry;

    // Setup helper
    function _setUpGlobalMessaging(address masterRegistry) internal {
        globalRegistry = new GlobalMessageRegistry(address(this));
        // ... setup logic ...
    }

    // Assertion helpers
    function _assertGlobalMessage(...) internal { ... }
    function _assertGlobalMessageWithAmount(...) internal { ... }

    // Query helpers
    function _getRecentMessages(uint256 count) internal view { ... }
    function _getInstanceMessages(address instance, uint256 count) internal view { ... }
}
```

### Integration Tests

```solidity
// Example: ERC1155Factory.t.sol
contract ERC1155FactoryTest is GlobalMessagingTestBase {
    function setUp() public {
        // ... factory setup ...
        _setUpGlobalMessaging(mockRegistry);
    }

    function test_MintWithMessage() public {
        instance.mintWithMessage{value: 0.1 ether}(1, 1, "Hello!");

        _assertGlobalMessageWithAmount({
            messageId: 0,
            expectedInstance: address(instance),
            expectedSender: minter,
            expectedFactoryType: GlobalMessageTypes.FACTORY_ERC1155,
            expectedActionType: GlobalMessageTypes.ACTION_MINT,
            expectedContextId: 1,
            expectedAmount: 1,
            expectedMessage: "Hello!"
        });
    }
}
```

---

## Future Enhancements

### Reserved Bits

80 bits reserved in packed data for future expansion:

- **Metadata flags**: Featured, verified, flagged
- **Extended context**: Multiple context values
- **Version field**: Support schema evolution
- **Custom data**: Factory-specific metadata

### Potential Features

- **Message reactions**: On-chain likes/emojis via separate mapping
- **Message threads**: Reply references via reserved bits
- **Content filtering**: Optional spam detection heuristics
- **Batch operations**: Multi-message submissions
- **Event indexing**: Subgraph integration for advanced queries

---

## Deployment Checklist

1. Deploy GlobalMessageRegistry
   ```bash
   forge script script/DeployGlobalRegistry.s.sol --broadcast
   ```

2. Set registry in MasterRegistry
   ```solidity
   masterRegistry.setGlobalMessageRegistry(registryAddress);
   ```

3. Verify auto-authorization works
   ```solidity
   factory.createInstance(...);
   bool authorized = registry.authorizedInstances(instance);
   assert(authorized == true);
   ```

4. Test message flow
   ```solidity
   instance.buyBonding{value: 1 ether}(amount, "Test message");
   assert(registry.getMessageCount() == 1);
   ```

---

## References

- [GlobalMessageRegistry.sol](../src/registry/GlobalMessageRegistry.sol)
- [GlobalMessagePacking.sol](../src/libraries/GlobalMessagePacking.sol)
- [GlobalMessageTypes.sol](../src/libraries/GlobalMessageTypes.sol)
- [GlobalMessagingTestBase.sol](../test/base/GlobalMessagingTestBase.sol)
- [ARCHITECTURE.md](./ARCHITECTURE.md) - System architecture documentation

---

## License

MIT or AGPL-3.0
