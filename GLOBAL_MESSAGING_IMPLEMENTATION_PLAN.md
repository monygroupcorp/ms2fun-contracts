# Global Messaging System Implementation Plan

## Overview
Replace isolated per-instance messaging with a centralized global message registry for protocol-wide activity tracking and frontend discoverability.

**Approach:** Complete replacement - no backward compatibility. Old messaging system will be fully removed.

## Performance Goals
- **Query Performance:** 1 RPC call vs 200+ for protocol activity feed
- **Gas Overhead:** ~5k gas per message (~18% increase, acceptable for massive UX win)
- **Frontend UX:** Enable trending/active project discovery without server infrastructure

---

## Phase 1: Core Infrastructure

### 1.1 GlobalMessageRegistry Contract

**File:** `src/registry/GlobalMessageRegistry.sol`

**Optimized Data Structure:**
```solidity
struct GlobalMessage {
    address instance;      // 20 bytes - which project (instance address)
    address sender;        // 20 bytes - who performed the action
    uint256 packedData;    // 32 bytes - packed metadata (see below)
    string message;        // dynamic - user-provided message
}

// packedData bit layout (176 bits used, 80 bits reserved):
// [0-31]    timestamp (uint32)      - Unix timestamp
// [32-39]   factoryType (uint8)     - 0=ERC404, 1=ERC1155, 2=future
// [40-47]   actionType (uint8)      - 0=buy, 1=sell, 2=mint, 3=withdraw, etc.
// [48-79]   contextId (uint32)      - editionId for ERC1155, 0 for ERC404
// [80-175]  amount (uint96)         - token/ETH amount involved
// [176-255] reserved (80 bits)      - future expansion
```

**Core Functions:**
```solidity
// Write functions
function addMessage(address instance, address sender, uint256 packedData, string calldata message)
    external
    onlyAuthorized
    returns (uint256 messageId);

// Query functions
function getRecentMessages(uint256 count)
    external view
    returns (GlobalMessage[] memory);

function getRecentMessagesPaginated(uint256 offset, uint256 limit)
    external view
    returns (GlobalMessage[] memory);

function getInstanceMessages(address instance, uint256 count)
    external view
    returns (GlobalMessage[] memory);

function getInstanceMessagesPaginated(address instance, uint256 offset, uint256 limit)
    external view
    returns (GlobalMessage[] memory);

function getMessage(uint256 messageId)
    external view
    returns (GlobalMessage memory);

function getMessageCount()
    external view
    returns (uint256);

function getMessageCountForInstance(address instance)
    external view
    returns (uint256);

// Authorization functions
function authorizeInstance(address instance) external onlyOwner;
function revokeInstance(address instance) external onlyOwner;
function isAuthorized(address instance) external view returns (bool);
```

**Storage Layout:**
```solidity
// Main message array (append-only)
GlobalMessage[] public messages;

// Index: instance => array of message IDs in main array
mapping(address => uint256[]) private instanceMessageIds;

// Authorization
mapping(address => bool) public authorizedInstances;
address public owner;
```

**Events:**
```solidity
event MessageAdded(
    uint256 indexed messageId,
    address indexed instance,
    address indexed sender,
    uint8 factoryType,
    uint8 actionType,
    uint32 contextId
);

event InstanceAuthorized(address indexed instance);
event InstanceRevoked(address indexed instance);
```

---

### 1.2 GlobalMessagePacking Library

**File:** `src/libraries/GlobalMessagePacking.sol`

```solidity
library GlobalMessagePacking {
    // Pack function
    function pack(
        uint32 timestamp,
        uint8 factoryType,
        uint8 actionType,
        uint32 contextId,
        uint96 amount
    ) internal pure returns (uint256 packed) {
        packed = uint256(timestamp);
        packed |= uint256(factoryType) << 32;
        packed |= uint256(actionType) << 40;
        packed |= uint256(contextId) << 48;
        packed |= uint256(amount) << 80;
    }

    // Unpack function
    function unpack(uint256 packed) internal pure returns (
        uint32 timestamp,
        uint8 factoryType,
        uint8 actionType,
        uint32 contextId,
        uint96 amount
    ) {
        timestamp = uint32(packed);
        factoryType = uint8(packed >> 32);
        actionType = uint8(packed >> 40);
        contextId = uint32(packed >> 48);
        amount = uint96(packed >> 80);
    }

    // Individual field extractors (gas-optimized for specific queries)
    function getTimestamp(uint256 packed) internal pure returns (uint32) {
        return uint32(packed);
    }

    function getFactoryType(uint256 packed) internal pure returns (uint8) {
        return uint8(packed >> 32);
    }

    function getActionType(uint256 packed) internal pure returns (uint8) {
        return uint8(packed >> 40);
    }

    function getContextId(uint256 packed) internal pure returns (uint32) {
        return uint32(packed >> 48);
    }

    function getAmount(uint256 packed) internal pure returns (uint96) {
        return uint96(packed >> 80);
    }
}
```

---

### 1.3 Action Type Constants

**File:** `src/libraries/GlobalMessageTypes.sol`

```solidity
library GlobalMessageTypes {
    // Factory Types
    uint8 constant FACTORY_ERC404 = 0;
    uint8 constant FACTORY_ERC1155 = 1;
    // Reserve 2-255 for future factory types

    // Action Types
    uint8 constant ACTION_BUY = 0;
    uint8 constant ACTION_SELL = 1;
    uint8 constant ACTION_MINT = 2;
    uint8 constant ACTION_WITHDRAW = 3;
    uint8 constant ACTION_STAKE = 4;
    uint8 constant ACTION_UNSTAKE = 5;
    uint8 constant ACTION_CLAIM_REWARDS = 6;
    uint8 constant ACTION_DEPLOY_LIQUIDITY = 7;
    // Reserve 8-255 for future action types
}
```

---

### 1.4 MasterRegistry Integration

**File:** `src/master/MasterRegistryV1.sol`

**Changes:**

1. Add state variable:
```solidity
GlobalMessageRegistry public globalMessageRegistry;
```

2. Add setter (owner only):
```solidity
function setGlobalMessageRegistry(address _registry) external onlyOwner {
    require(_registry != address(0), "Invalid registry");
    globalMessageRegistry = GlobalMessageRegistry(_registry);
}
```

3. Add getter:
```solidity
function getGlobalMessageRegistry() external view returns (address) {
    return address(globalMessageRegistry);
}
```

4. Update `registerInstance()` to authorize new instances:
```solidity
function registerInstance(
    address instance,
    address factory,
    address creator,
    string memory name,
    string memory metadataURI,
    address vault
) external override {
    // ... existing validation ...

    // Authorize instance to write to global message registry
    if (address(globalMessageRegistry) != address(0)) {
        globalMessageRegistry.authorizeInstance(instance);
    }

    // ... rest of existing logic ...
}
```

---

## Phase 2: Instance Contract Updates (Complete Replacement)

### 2.1 ERC404BondingInstance - Remove Old, Add New

**File:** `src/factories/erc404/ERC404BondingInstance.sol`

**REMOVE:**
```solidity
// DELETE these entirely:
struct BondingMessage { ... }
mapping(uint256 => BondingMessage) public bondingMessages;
uint256 public totalMessages;

function getMessageDetails(uint256 messageId) external view returns (...) { ... }
function getMessagesBatch(uint256 start, uint256 end) external view returns (...) { ... }
```

**ADD:**
```solidity
import { GlobalMessageRegistry } from "../../registry/GlobalMessageRegistry.sol";
import { GlobalMessagePacking } from "../../libraries/GlobalMessagePacking.sol";
import { GlobalMessageTypes } from "../../libraries/GlobalMessageTypes.sol";
import { IMasterRegistry } from "../../master/interfaces/IMasterRegistry.sol";

// State variables
IMasterRegistry public immutable masterRegistry;
GlobalMessageRegistry private cachedGlobalRegistry;

// Constructor addition
constructor(
    // ... existing params ...
    address _masterRegistry
) {
    // ... existing logic ...
    require(_masterRegistry != address(0), "Invalid master registry");
    masterRegistry = IMasterRegistry(_masterRegistry);
}

// Helper to lazy-load registry
function _getGlobalMessageRegistry() private returns (GlobalMessageRegistry) {
    if (address(cachedGlobalRegistry) == address(0)) {
        address registryAddr = masterRegistry.getGlobalMessageRegistry();
        require(registryAddr != address(0), "Global registry not set");
        cachedGlobalRegistry = GlobalMessageRegistry(registryAddr);
    }
    return cachedGlobalRegistry;
}

// Public getter for frontend
function getGlobalMessageRegistry() external view returns (address) {
    return masterRegistry.getGlobalMessageRegistry();
}
```

**UPDATE buyBonding():**
```solidity
function buyBonding(
    uint256 amount,
    uint256 maxCost,
    bool mintNFT,
    bytes32 passwordHash,
    string calldata message
) external payable nonReentrant {
    // ... existing validation and transfer logic ...

    // REPLACE old message storage with global registry call
    if (bytes(message).length > 0) {
        GlobalMessageRegistry registry = _getGlobalMessageRegistry();

        uint256 packedData = GlobalMessagePacking.pack(
            uint32(block.timestamp),
            GlobalMessageTypes.FACTORY_ERC404,
            GlobalMessageTypes.ACTION_BUY,
            0, // contextId: 0 for ERC404 (no editions)
            uint96(amount / 1e18) // Normalize to whole tokens
        );

        registry.addMessage(address(this), msg.sender, packedData, message);
    }

    // ... rest of existing logic ...
}
```

**UPDATE sellBonding():**
```solidity
function sellBonding(
    uint256 amount,
    uint256 minRefund,
    bytes32 passwordHash,
    string calldata message
) external nonReentrant {
    // ... existing validation and transfer logic ...

    // REPLACE old message storage with global registry call
    if (bytes(message).length > 0) {
        GlobalMessageRegistry registry = _getGlobalMessageRegistry();

        uint256 packedData = GlobalMessagePacking.pack(
            uint32(block.timestamp),
            GlobalMessageTypes.FACTORY_ERC404,
            GlobalMessageTypes.ACTION_SELL,
            0, // contextId: 0 for ERC404
            uint96(amount / 1e18)
        );

        registry.addMessage(address(this), msg.sender, packedData, message);
    }

    // ... rest of existing logic ...
}
```

**REMOVE from metadata functions:**
```solidity
// DELETE getMessageCount() - use globalRegistry.getMessageCountForInstance(address(this)) instead
```

---

### 2.2 ERC1155Instance - Remove Old, Add New

**File:** `src/factories/erc1155/ERC1155Instance.sol`

**REMOVE:**
```solidity
// DELETE these entirely:
struct MintMessage { ... }
mapping(uint256 => MintMessage) public mintMessages;
uint256 public totalMessages;

function getMessageDetails(uint256 messageId) external view returns (...) { ... }
function getMessagesBatch(uint256 start, uint256 end) external view returns (...) { ... }
function getMessageCount() external view returns (uint256) { ... }
```

**ADD:**
```solidity
import { GlobalMessageRegistry } from "../../registry/GlobalMessageRegistry.sol";
import { GlobalMessagePacking } from "../../libraries/GlobalMessagePacking.sol";
import { GlobalMessageTypes } from "../../libraries/GlobalMessageTypes.sol";
import { IMasterRegistry } from "../../master/interfaces/IMasterRegistry.sol";

// State variables
IMasterRegistry public immutable masterRegistry;
GlobalMessageRegistry private cachedGlobalRegistry;

// Constructor addition
constructor(
    string memory _name,
    string memory /* metadataURI */,
    address _creator,
    address _factory,
    address _vault,
    string memory _styleUri,
    address _masterRegistry // NEW
) {
    // ... existing logic ...
    require(_masterRegistry != address(0), "Invalid master registry");
    masterRegistry = IMasterRegistry(_masterRegistry);
}

// Helper to lazy-load registry
function _getGlobalMessageRegistry() private returns (GlobalMessageRegistry) {
    if (address(cachedGlobalRegistry) == address(0)) {
        address registryAddr = masterRegistry.getGlobalMessageRegistry();
        require(registryAddr != address(0), "Global registry not set");
        cachedGlobalRegistry = GlobalMessageRegistry(registryAddr);
    }
    return cachedGlobalRegistry;
}

// Public getter
function getGlobalMessageRegistry() external view returns (address) {
    return masterRegistry.getGlobalMessageRegistry();
}
```

**UPDATE _mintWithMessage():**
```solidity
function _mintWithMessage(
    uint256 editionId,
    uint256 amount,
    string memory message
) internal {
    // ... existing validation and minting logic ...

    // REPLACE old message storage with global registry call
    if (bytes(message).length > 0) {
        GlobalMessageRegistry registry = _getGlobalMessageRegistry();

        require(editionId <= type(uint32).max, "EditionId too large");
        require(amount <= type(uint96).max, "Amount too large");

        uint256 packedData = GlobalMessagePacking.pack(
            uint32(block.timestamp),
            GlobalMessageTypes.FACTORY_ERC1155,
            GlobalMessageTypes.ACTION_MINT,
            uint32(editionId), // contextId: edition being minted
            uint96(amount)
        );

        registry.addMessage(address(this), msg.sender, packedData, message);
    }

    // ... rest of existing logic ...
}
```

---

### 2.3 Factory Updates

**File:** `src/factories/erc404/ERC404Factory.sol`

**Changes:**
```solidity
// Add masterRegistry reference (should already exist)
// Update createInstance to pass masterRegistry to instance

function createInstance(
    // ... existing params ...
) external payable nonReentrant returns (address instance) {
    // ... existing logic ...

    instance = address(new ERC404BondingInstance(
        // ... existing params ...
        address(masterRegistry) // Pass masterRegistry
    ));

    // ... rest of existing logic ...
}
```

**File:** `src/factories/erc1155/ERC1155Factory.sol`

**Changes:**
```solidity
function createInstance(
    string memory name,
    string memory metadataURI,
    address creator,
    address vault,
    string memory styleUri
) external payable nonReentrant returns (address instance) {
    // ... existing validation ...

    instance = address(new ERC1155Instance(
        name,
        metadataURI,
        creator,
        address(this),
        vault,
        styleUri,
        address(masterRegistry) // NEW - pass masterRegistry
    ));

    // ... rest of existing logic ...
}
```

---

## Phase 3: Test Migration Strategy

### 3.1 Test Files Requiring Complete Rewrites

**ERC404 Tests:**
- `test/factories/erc404/ERC404Factory.t.sol` - 387 lines
- `test/factories/erc404/ERC404BondingInstance.t.sol` - ~500 lines (estimate from backup)
- `test/factories/erc404/ERC404Reroll.t.sol` - needs message query updates
- `test/factories/erc404/ERC404StakingAccounting.t.sol` - likely no message tests
- `test/factories/erc404/hooks/UltraAlignmentHookFactory.t.sol` - likely no message tests

**ERC1155 Tests:**
- `test/factories/erc1155/ERC1155Factory.t.sol` - 277 lines

**Integration Tests:**
- `test/integration/FullWorkflowIntegration.t.sol` - may have message tests
- `test/fork/VaultUniswapIntegration.t.sol` - likely no message tests
- `test/fork/integration/VaultMultiDeposit.t.sol` - likely no message tests

**Master Registry Tests:**
- `test/master/FactoryInstanceIndexing.t.sol` - needs registry integration tests

**Priority Order:**
1. Create GlobalMessageRegistry tests first (new file)
2. Update ERC404Factory.t.sol
3. Update ERC404BondingInstance.t.sol
4. Update ERC1155Factory.t.sol
5. Update integration tests
6. Update master registry tests

### 3.2 Base Test Setup Pattern

**Create:** `test/base/GlobalMessagingTestBase.sol`

```solidity
abstract contract GlobalMessagingTestBase is Test {
    GlobalMessageRegistry public globalRegistry;

    function _setUpGlobalMessaging() internal {
        // Deploy global registry
        globalRegistry = new GlobalMessageRegistry(address(this));

        // Set in master registry
        masterRegistry.setGlobalMessageRegistry(address(globalRegistry));
    }

    // Helper: Assert global message
    function _assertGlobalMessage(
        uint256 messageId,
        address expectedInstance,
        address expectedSender,
        uint8 expectedFactoryType,
        uint8 expectedActionType,
        uint32 expectedContextId,
        string memory expectedMessage
    ) internal {
        GlobalMessageRegistry.GlobalMessage memory msg = globalRegistry.getMessage(messageId);

        assertEq(msg.instance, expectedInstance, "Wrong instance");
        assertEq(msg.sender, expectedSender, "Wrong sender");
        assertEq(msg.message, expectedMessage, "Wrong message");

        (uint32 ts, uint8 factoryType, uint8 actionType, uint32 contextId, uint96 amount) =
            GlobalMessagePacking.unpack(msg.packedData);

        assertEq(factoryType, expectedFactoryType, "Wrong factory type");
        assertEq(actionType, expectedActionType, "Wrong action type");
        assertEq(contextId, expectedContextId, "Wrong context ID");
        assertTrue(ts > 0, "Invalid timestamp");
        assertTrue(amount > 0, "Invalid amount");
    }

    // Helper: Assert message count
    function _assertMessageCount(uint256 expected) internal {
        assertEq(globalRegistry.getMessageCount(), expected, "Wrong global message count");
    }

    // Helper: Assert instance message count
    function _assertInstanceMessageCount(address instance, uint256 expected) internal {
        assertEq(
            globalRegistry.getMessageCountForInstance(instance),
            expected,
            "Wrong instance message count"
        );
    }

    // Helper: Get recent messages
    function _getRecentMessages(uint256 count) internal view returns (
        GlobalMessageRegistry.GlobalMessage[] memory
    ) {
        return globalRegistry.getRecentMessages(count);
    }

    // Helper: Get instance messages
    function _getInstanceMessages(address instance, uint256 count) internal view returns (
        GlobalMessageRegistry.GlobalMessage[] memory
    ) {
        return globalRegistry.getInstanceMessages(instance, count);
    }
}
```

### 3.3 Test Update Pattern

**BEFORE (old local messaging):**
```solidity
function test_BuyWithMessage() public {
    string memory testMessage = "gm frens";

    instance.buyBonding{value: cost}(
        amount,
        cost,
        true,
        passwordHash,
        testMessage
    );

    // Query local storage
    (
        address sender,
        uint32 timestamp,
        uint96 amt,
        bool isBuy,
        string memory message
    ) = instance.getMessageDetails(0);

    assertEq(sender, address(this));
    assertEq(message, testMessage);
    assertTrue(isBuy);
    assertEq(instance.totalMessages(), 1);
}
```

**AFTER (global messaging):**
```solidity
function test_BuyWithMessage() public {
    string memory testMessage = "gm frens";

    instance.buyBonding{value: cost}(
        amount,
        cost,
        true,
        passwordHash,
        testMessage
    );

    // Query global registry
    _assertMessageCount(1);
    _assertInstanceMessageCount(address(instance), 1);

    _assertGlobalMessage({
        messageId: 0,
        expectedInstance: address(instance),
        expectedSender: address(this),
        expectedFactoryType: GlobalMessageTypes.FACTORY_ERC404,
        expectedActionType: GlobalMessageTypes.ACTION_BUY,
        expectedContextId: 0, // No edition for ERC404
        expectedMessage: testMessage
    });

    // Verify we can query instance-specific messages
    GlobalMessageRegistry.GlobalMessage[] memory instanceMsgs =
        _getInstanceMessages(address(instance), 10);
    assertEq(instanceMsgs.length, 1);
    assertEq(instanceMsgs[0].message, testMessage);
}
```

**NEW TEST: Cross-instance global feed:**
```solidity
function test_GlobalFeed_MultipleInstances() public {
    // Create two instances
    address instance1 = factory.createInstance{value: fee}(...);
    address instance2 = factory.createInstance{value: fee}(...);

    // Buy on instance1
    ERC404BondingInstance(instance1).buyBonding{value: cost1}(
        amount1, cost1, true, hash1, "Message from instance 1"
    );

    // Buy on instance2
    ERC404BondingInstance(instance2).buyBonding{value: cost2}(
        amount2, cost2, true, hash2, "Message from instance 2"
    );

    // Query global feed - should have both messages
    _assertMessageCount(2);

    GlobalMessageRegistry.GlobalMessage[] memory recentMsgs =
        _getRecentMessages(10);

    assertEq(recentMsgs.length, 2);
    assertEq(recentMsgs[0].instance, instance1);
    assertEq(recentMsgs[1].instance, instance2);

    // Query instance-specific - should filter correctly
    assertEq(_getInstanceMessages(instance1, 10).length, 1);
    assertEq(_getInstanceMessages(instance2, 10).length, 1);
}
```

### 3.4 Test Migration Checklist

For EACH test file:

**Setup Phase:**
- [ ] Import `GlobalMessageRegistry`
- [ ] Import `GlobalMessagePacking`
- [ ] Import `GlobalMessageTypes`
- [ ] Extend `GlobalMessagingTestBase` (or add to existing base)
- [ ] Call `_setUpGlobalMessaging()` in `setUp()`

**Replacement Phase:**
- [ ] Find all `instance.getMessageDetails()` calls → Replace with `globalRegistry.getMessage()`
- [ ] Find all `instance.getMessagesBatch()` calls → Replace with `globalRegistry.getInstanceMessages()`
- [ ] Find all `instance.totalMessages()` calls → Replace with `globalRegistry.getMessageCountForInstance()`
- [ ] Find all message struct field assertions → Replace with `_assertGlobalMessage()` helper
- [ ] Delete all imports of old message packing libraries (`MessagePacking`, `EditionMessagePacking`)

**Enhancement Phase:**
- [ ] Add cross-instance global feed tests
- [ ] Add pagination tests
- [ ] Add authorization tests
- [ ] Add gas benchmark tests (compare before/after)

**Validation Phase:**
- [ ] Run full test suite: `forge test`
- [ ] Verify gas usage: `forge test --gas-report`
- [ ] Check coverage: `forge coverage`
- [ ] Ensure no regressions

---

## Phase 4: Removal of Old Code

### 4.1 Files to Delete Entirely

These files are no longer needed:

- `src/factories/erc404/libraries/MessagePacking.sol`
- `src/factories/erc1155/libraries/EditionMessagePacking.sol`

### 4.2 Code Sections to Delete

**In ERC404BondingInstance.sol:**
```solidity
// DELETE:
struct BondingMessage { ... }
mapping(uint256 => BondingMessage) public bondingMessages;
uint256 public totalMessages;

function getMessageDetails(uint256 messageId) external view returns (...) { ... }
function getMessagesBatch(uint256 start, uint256 end) external view returns (...) { ... }
```

**In ERC1155Instance.sol:**
```solidity
// DELETE:
struct MintMessage { ... }
mapping(uint256 => MintMessage) public mintMessages;
uint256 public totalMessages;

function getMessageDetails(uint256 messageId) external view returns (...) { ... }
function getMessagesBatch(uint256 start, uint256 end) external view returns (...) { ... }
function getMessageCount() external view returns (uint256 count) { ... }
```

### 4.3 Verification Checklist

After deletion:
- [ ] No compiler errors
- [ ] No references to deleted structs/mappings
- [ ] All tests pass
- [ ] Gas report shows reduced deployment costs (removed storage)
- [ ] Contract size reduced (verify with `forge build --sizes`)

---

## Phase 5: Gas Optimization & Benchmarking

### 5.1 Gas Comparison Tests

**Create:** `test/gas/GlobalMessagingGas.t.sol`

```solidity
contract GlobalMessagingGasTest is Test {
    function test_Gas_BuyWithMessage_ERC404() public {
        // Measure gas for buy with message
        uint256 gasBefore = gasleft();
        instance.buyBonding{value: cost}(amount, cost, true, hash, "test message");
        uint256 gasUsed = gasBefore - gasleft();

        // Assert reasonable gas usage (~27-30k for message)
        assertTrue(gasUsed < 500_000, "Excessive gas");
        emit log_named_uint("Gas used for buyBonding with message", gasUsed);
    }

    function test_Gas_MintWithMessage_ERC1155() public {
        uint256 gasBefore = gasleft();
        instance.mintWithMessage{value: cost}(editionId, amount, "test message");
        uint256 gasUsed = gasBefore - gasleft();

        assertTrue(gasUsed < 400_000, "Excessive gas");
        emit log_named_uint("Gas used for mint with message", gasUsed);
    }

    function test_Gas_QueryRecentMessages() public {
        // Add 100 messages
        for (uint256 i = 0; i < 100; i++) {
            instance.buyBonding{value: cost}(amount, cost, true, hash, "msg");
        }

        // Measure query gas
        uint256 gasBefore = gasleft();
        GlobalMessageRegistry.GlobalMessage[] memory msgs =
            globalRegistry.getRecentMessages(50);
        uint256 gasUsed = gasBefore - gasleft();

        assertEq(msgs.length, 50);
        emit log_named_uint("Gas used to query 50 recent messages", gasUsed);
    }
}
```

### 5.2 Expected Gas Metrics

| Operation | Target Gas | Max Gas | Notes |
|-----------|-----------|---------|-------|
| Buy with message (ERC404) | 280k | 320k | Includes bonding + global write |
| Sell with message (ERC404) | 250k | 290k | Includes bonding + global write |
| Mint with message (ERC1155) | 180k | 220k | Includes mint + global write |
| Query 10 recent messages | 50k | 80k | View function, client-side gas |
| Query 100 instance messages | 150k | 250k | View function, larger dataset |

---

## Phase 6: Deployment Strategy

### 6.1 Deployment Order

**Step 1: Deploy GlobalMessageRegistry**
```solidity
GlobalMessageRegistry registry = new GlobalMessageRegistry(MULTISIG_ADDRESS);
```

**Step 2: Update MasterRegistry**
```solidity
masterRegistry.setGlobalMessageRegistry(address(registry));
```

**Step 3: Deploy New Factory Implementations**
```solidity
// Factories now pass masterRegistry to instances
ERC404Factory factoryV2 = new ERC404Factory(...);
ERC1155Factory factoryV2 = new ERC1155Factory(...);
```

**Step 4: Governance Approval**
```solidity
// Approve new factory versions through governance
governance.approveFactory(address(factoryV2), true);
```

**Step 5: Deprecate Old Factories**
```solidity
// Optionally revoke old factories
governance.approveFactory(address(oldFactory), false);
```

### 6.2 Testnet Deployment Checklist

- [ ] Deploy to Sepolia/Goerli
- [ ] Deploy GlobalMessageRegistry
- [ ] Update MasterRegistry with registry address
- [ ] Deploy new ERC404Factory
- [ ] Deploy new ERC1155Factory
- [ ] Create test instances
- [ ] Perform test buy/sell/mint with messages
- [ ] Verify global registry contains messages
- [ ] Query messages via frontend RPC calls
- [ ] Measure query performance (latency)
- [ ] Verify gas costs match estimates

### 6.3 Mainnet Deployment Checklist

- [ ] Security audit of GlobalMessageRegistry
- [ ] Deploy GlobalMessageRegistry (timelock or multisig owner)
- [ ] Update MasterRegistryV1 via governance
- [ ] Deploy new factory implementations
- [ ] Governance proposal to approve new factories
- [ ] Monitor first instances for issues
- [ ] Gradually migrate traffic to new factories
- [ ] Document breaking changes for integrators

---

## Phase 7: Documentation Updates

### 7.1 Architecture Documentation

**Update:** `docs/ARCHITECTURE.md`

Add section:
```markdown
## Global Messaging System

The protocol uses a centralized message registry to track all user actions across instances:

- **Registry Contract:** GlobalMessageRegistry
- **Message Types:** Buy, Sell, Mint, Withdraw, Stake, Unstake, Claim
- **Query Pattern:** Single RPC call for protocol-wide activity feed
- **Authorization:** Only MasterRegistry-approved instances can write

### Data Structure

Messages are stored with optimized bit-packing:
- Timestamp (32 bits)
- Factory type (8 bits)
- Action type (8 bits)
- Context ID (32 bits) - edition ID for ERC1155, 0 for ERC404
- Amount (96 bits)

Total: 176 bits in a single uint256 (80 bits reserved for future use)

### Frontend Integration

```javascript
// Get recent protocol activity (1 RPC call)
const messages = await globalRegistry.getRecentMessages(100);

// Get instance-specific messages
const projectMessages = await globalRegistry.getInstanceMessages(instanceAddress, 50);

// Parse packed data
const [timestamp, factoryType, actionType, contextId, amount] =
    await packing.unpack(message.packedData);
```
```

### 7.2 Integration Guide

**Create:** `docs/GLOBAL_MESSAGING.md`

Full guide covering:
- Why global messaging (performance benefits)
- Data structures and packing format
- Query patterns for frontends
- Gas costs and optimization tips
- Authorization model
- Example frontend code
- Migration notes for existing integrations

### 7.3 Frontend Examples

**Create:** `examples/frontend/query-global-messages.js`

```javascript
// Example: Query recent protocol activity
async function getProtocolActivity(count = 100) {
    const registry = new ethers.Contract(
        GLOBAL_REGISTRY_ADDRESS,
        GLOBAL_REGISTRY_ABI,
        provider
    );

    const messages = await registry.getRecentMessages(count);

    return messages.map(msg => ({
        instance: msg.instance,
        sender: msg.sender,
        timestamp: unpackTimestamp(msg.packedData),
        factoryType: unpackFactoryType(msg.packedData),
        actionType: unpackActionType(msg.packedData),
        contextId: unpackContextId(msg.packedData),
        amount: unpackAmount(msg.packedData),
        message: msg.message
    }));
}

// Example: Find trending projects (most messages in last hour)
async function getTrendingProjects(timeWindow = 3600) {
    const messages = await getProtocolActivity(1000);
    const now = Math.floor(Date.now() / 1000);
    const cutoff = now - timeWindow;

    const recentMessages = messages.filter(m => m.timestamp >= cutoff);

    const instanceCounts = {};
    for (const msg of recentMessages) {
        instanceCounts[msg.instance] = (instanceCounts[msg.instance] || 0) + 1;
    }

    return Object.entries(instanceCounts)
        .sort((a, b) => b[1] - a[1])
        .slice(0, 10)
        .map(([instance, count]) => ({ instance, count }));
}
```

---

## Success Criteria

### Performance Metrics
- [ ] Protocol activity query: 1 RPC call (down from 200+)
- [ ] Query latency: <200ms for 100 messages
- [ ] Gas overhead: ≤20% vs old system (~5k gas per message)
- [ ] Contract deployment size: Reduced (removed local message storage)

### Functionality
- [ ] All existing tests pass with global messaging
- [ ] New global-specific tests cover edge cases
- [ ] Cross-instance message querying works correctly
- [ ] Authorization prevents unauthorized writes
- [ ] Pagination handles large message sets

### Code Quality
- [ ] Zero compiler warnings
- [ ] All old messaging code removed
- [ ] No dead code or unused imports
- [ ] Documentation complete and accurate
- [ ] Gas report shows expected costs

### Frontend Compatibility
- [ ] Can discover trending projects in 1 RPC call
- [ ] Can filter messages by instance
- [ ] Can filter messages by action type
- [ ] Can display protocol-wide activity feed
- [ ] Performance acceptable on slow connections

---

## Implementation Timeline

**Phase 1 (Core Infrastructure):** 2-3 days
- GlobalMessageRegistry contract
- GlobalMessagePacking library
- GlobalMessageTypes constants
- MasterRegistry integration

**Phase 2 (Instance Updates):** 2-3 days
- Remove old message code from ERC404BondingInstance
- Remove old message code from ERC1155Instance
- Add global registry integration
- Update factories

**Phase 3 (Test Migration):** 5-7 days ← LARGEST EFFORT
- Create GlobalMessagingTestBase
- Update ERC404Factory tests
- Update ERC404BondingInstance tests
- Update ERC1155Factory tests
- Update integration tests
- Create gas benchmark tests

**Phase 4 (Code Cleanup):** 1 day
- Delete old packing libraries
- Remove all dead code
- Verify no regressions

**Phase 5 (Gas Optimization):** 1-2 days
- Gas benchmarking
- Optimization passes
- Final gas report

**Phase 6 (Deployment):** 1-2 days
- Testnet deployment
- Integration testing
- Mainnet deployment

**Phase 7 (Documentation):** 2-3 days
- Architecture updates
- Integration guide
- Frontend examples
- Migration notes

**Total: 14-21 days** (3-4 weeks with dedicated focus)

**Critical Path:** Test migration (Phase 3) is the bottleneck

---

## Risk Assessment

### High Risks
1. **Test Suite Breakage**
   - Mitigation: Methodical file-by-file migration, helper functions

2. **Gas Cost Regression**
   - Mitigation: Benchmark early, optimize before deployment

3. **Authorization Bug**
   - Mitigation: Comprehensive auth tests, audit before mainnet

### Medium Risks
1. **Frontend Breaking Changes**
   - Mitigation: Document API changes, provide migration examples

2. **Registry Downtime**
   - Mitigation: Make registry upgradeable, test thoroughly

3. **Message Ordering Issues**
   - Mitigation: Timestamp-based sorting, test cross-instance scenarios

### Low Risks
1. **Storage Growth**
   - Mitigation: Millions of messages needed to hit limits

2. **Query Performance**
   - Mitigation: Pagination prevents oversized responses

---

## Next Steps

1. **Review & Sign Off:** Approve this plan
2. **Create Branch:** `feature/global-messaging-system`
3. **Phase 1:** Implement GlobalMessageRegistry + libraries
4. **Test:** Unit tests for registry before proceeding
5. **Phase 2:** Update instances and factories
6. **Phase 3:** Migrate test suite (largest effort)
7. **Deploy:** Testnet validation, then mainnet

**Ready to start implementation?**
