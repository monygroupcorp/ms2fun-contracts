# Contract State Trimming Specification

**Purpose:** Remove on-chain state that duplicates event data. With EventIndexer, this state can be derived from events, saving gas and reducing contract complexity.

**Target:** Hand to contract team for immediate execution.

---

## Priority Legend
- **P0** = High impact, easy removal
- **P1** = High impact, moderate effort
- **P2** = Medium impact
- **P3** = Low impact / optional

---

## 1. MasterRegistryV1.sol (Highest Priority)

### P0: Remove Instance Enumeration Arrays

**Current State (Lines 51-55):**
```solidity
mapping(address => address[]) public creatorInstances; // creator => instances[]
address[] public allInstances; // Array of all registered instances
mapping(address => uint256) public instanceIndex; // instance address => index in allInstances
```

**Events Already Exist:**
```solidity
event InstanceRegistered(address indexed instance, address indexed factory, address indexed creator, string name);
event CreatorInstanceAdded(address indexed creator, address indexed instance);
```

**Action:** DELETE these 3 state variables. Frontend derives from `InstanceRegistered` events.

**Code to Remove in `registerInstance()` (Lines 320-324):**
```solidity
// DELETE THIS BLOCK:
creatorInstances[creator].push(instance);
instanceIndex[instance] = allInstances.length;
allInstances.push(instance);
```

**Functions to Remove:**
- `getTotalInstances()` (Line 408)
- `getInstanceByIndex()` (Line 417)
- `getInstanceAddresses()` (Line 428)
- `getCreatorInstances()` (Line 364)

**Gas Savings:** ~60k gas per instance registration (3 SSTORE operations removed)

---

### P0: Remove Vault-Instance Tracking

**Current State (Line 72):**
```solidity
mapping(address => address[]) public vaultInstances; // vault => instances using it
```

**Event Already Exists:**
```solidity
event InstanceRegistered(..., address vault); // vault is in the event
```

**Action:** DELETE `vaultInstances` mapping.

**Code to Remove in `registerInstance()` (Lines 327-330):**
```solidity
// DELETE THIS BLOCK:
if (vault != address(0) && registeredVaults[vault]) {
    vaultInstances[vault].push(instance);
    vaultInfo[vault].instanceCount++;
}
```

**Functions to Remove:**
- `getInstancesByVault()` (Line 523)

**Note:** Also remove `instanceCount` from `VaultInfo` struct if not needed elsewhere.

---

### P1: Remove Vault Enumeration

**Current State (Line 68):**
```solidity
address[] public vaultList;
```

**Events Already Exist:**
```solidity
event VaultRegistered(address indexed vault, address indexed creator, string name, uint256 fee);
```

**Action:** DELETE `vaultList` array.

**Code to Remove in `registerVault()` (Line 468):**
```solidity
vaultList.push(vault); // DELETE
```

**Functions to Remove:**
- `getVaultList()` (Line 494)
- `getTotalVaults()` (Line 514)
- `getVaults()` (Line 536) - entire pagination function
- `getVaultsByPopularity()` (Line 567) - entire sorting function
- `getVaultsByTVL()` (Line 627) - entire sorting function (this does O(n^2) bubble sort on-chain!)

**Gas Savings:** ~20k gas per vault registration + eliminates expensive view functions

---

## 2. GlobalMessageRegistry.sol (High Priority)

### P0: Remove Instance Message Index

**Current State (Line 36):**
```solidity
mapping(address => uint256[]) private instanceMessageIds;
```

**Event Already Exists:**
```solidity
event MessageAdded(
    uint256 indexed messageId,
    address indexed instance,  // <-- INDEXED, can filter by instance
    address indexed sender,
    uint8 factoryType,
    uint8 actionType,
    uint32 contextId,
    uint256 timestamp
);
```

**Action:** DELETE `instanceMessageIds` mapping.

**Code to Remove in `addMessage()` (Line 105):**
```solidity
instanceMessageIds[instance].push(messageId); // DELETE
```

**Functions to Remove:**
- `getMessageCountForInstance()` (Line 217)
- `getInstanceMessages()` (Line 227)
- `getInstanceMessagesPaginated()` (Line 254)
- `getInstanceMessageIds()` (Line 282)

**Gas Savings:** ~20k gas per message (1 array push removed)

---

### P1: Consider Messages Array

**Current State (Line 33):**
```solidity
GlobalMessage[] public messages;
```

**Discussion:** The `messages` array is append-only and could grow to millions of entries. However, the event contains all data needed:

```solidity
event MessageAdded(
    uint256 indexed messageId,
    address indexed instance,
    address indexed sender,
    uint8 factoryType,
    uint8 actionType,
    uint32 contextId,
    uint256 timestamp
);
```

**Missing from event:** `string message` (the actual message text)

**Options:**
1. Add `message` string to event → DELETE array entirely
2. Keep array for message text lookup only (but remove index mapping)

**Recommendation:** Add message text to event, then remove array. Event logs are cheaper than storage.

**Modified Event:**
```solidity
event MessageAdded(
    uint256 indexed messageId,
    address indexed instance,
    address indexed sender,
    uint8 factoryType,
    uint8 actionType,
    uint32 contextId,
    uint256 timestamp,
    string message  // ADD THIS
);
```

---

## 3. FeaturedQueueManager.sol (Medium Priority)

### P1: Remove Position Demand History

**Current State (Line 33):**
```solidity
mapping(uint256 => IMasterRegistry.PositionDemand) public positionDemand;
```

**Struct:**
```solidity
struct PositionDemand {
    uint256 lastRentalPrice;
    uint256 lastRentalTime;
    uint256 totalRentalsAllTime;
}
```

**Events Already Exist:**
```solidity
event PositionRented(address indexed instance, address indexed renter, uint256 position, uint256 cost, uint256 duration, uint256 expiresAt);
event PositionBumped(address indexed instance, uint256 oldPosition, uint256 newPosition, uint256 cost, uint256 additionalDuration);
event PositionRenewed(address indexed instance, uint256 position, uint256 additionalDuration, uint256 cost, uint256 newExpiration);
```

**Action:** DELETE `positionDemand` mapping.

**Code to Remove:**
- Lines 399-403 in `bumpPosition()`
- Lines 549-554 in `_insertAtPositionWithShift()`

**Impact:** `getPositionRentalPrice()` currently uses `positionDemand` for pricing. Refactor to calculate from `featuredQueue[position-1].rentPaid` only (current slot), or accept that historical demand pricing requires event indexing.

---

### P2: Remove Instance Position Lookup

**Current State (Line 30):**
```solidity
mapping(address => uint256) public instancePosition;
```

**This is a reverse lookup:** Given an instance, what position is it in?

**Alternative:** Iterate `featuredQueue` to find position (O(n) but queue is capped at 100).

**Recommendation:** KEEP for now. Queue is bounded, and this lookup is used in multiple places. Low gas savings vs refactoring effort.

---

## 4. VaultRegistry.sol (Medium Priority)

### P0: Remove Duplicate Lists

**Current State (Lines 59-60):**
```solidity
address[] public vaultList;
address[] public hookList;
```

**Events Already Exist:**
```solidity
event VaultRegistered(address indexed vault, address indexed creator, string name, uint256 fee);
event HookRegistered(address indexed hook, address indexed creator, address indexed vault, string name, uint256 fee);
```

**Action:** DELETE both arrays.

**Code to Remove:**
- `vaultList.push(vault)` in `registerVault()` (Line 101)
- `hookList.push(hook)` in `registerHook()` (Line 146)

**Functions to Remove:**
- `getVaultList()` (Line 188)
- `getHookList()` (Line 195)
- `getVaultCount()` (Line 285)
- `getHookCount()` (Line 292)

---

### P1: Remove Hooks-By-Vault Mapping

**Current State (Line 58):**
```solidity
mapping(address => address[]) public hooksByVault;
```

**Event Contains Vault:**
```solidity
event HookRegistered(address indexed hook, address indexed creator, address indexed vault, string name, uint256 fee);
```

**Action:** DELETE `hooksByVault` mapping.

**Code to Remove:**
- `hooksByVault[vault].push(hook)` in `registerHook()` (Line 147)

**Functions to Remove:**
- `getHooksByVault()` (Line 202)

---

### P2: Remove Instance Count Fields

**Current State (in structs):**
```solidity
struct VaultInfo {
    ...
    uint256 instanceCount; // For tracking usage
}

struct HookInfo {
    ...
    uint256 instanceCount; // For tracking usage
}
```

**Alternative:** Count `InstanceRegistered` events filtered by vault.

**Action:** DELETE `instanceCount` from both structs.

**Functions to Remove:**
- `incrementVaultInstanceCount()` (Line 242)
- `incrementHookInstanceCount()` (Line 250)

---

## 5. ERC404Factory.sol (Low Priority)

### P2: Remove Instance-to-Vault/Hook Mappings

**Current State (Lines 34-36):**
```solidity
mapping(address => address) public instanceToVault;
mapping(address => address) public instanceToHook;
```

**Event Contains This Data:**
```solidity
event InstanceCreated(
    address indexed instance,
    address indexed creator,
    string name,
    string symbol,
    address indexed vault,
    address hook  // <-- hook is here
);
```

**Action:** DELETE both mappings.

**Code to Remove (Lines 124-126):**
```solidity
instanceToVault[instance] = vault;
instanceToHook[instance] = hook;
```

**Functions to Remove:**
- `getVaultForInstance()` (Line 151)
- `getHookForInstance()` (Line 160)

---

## 6. ERC1155Factory.sol (Low Priority)

### P2: Remove Instance-to-Vault Mapping

**Current State (Line 21):**
```solidity
mapping(address => address) public instanceToVault;
```

**Event Contains Vault:**
```solidity
event InstanceCreated(
    address indexed instance,
    address indexed creator,
    string name,
    address indexed vault
);
```

**Action:** DELETE `instanceToVault` mapping.

**Code to Remove (Line 89):**
```solidity
instanceToVault[instance] = vault;
```

**Functions to Remove:**
- `getVaultForInstance()` (Line 158)

---

## 7. ERC404BondingInstance.sol (Low Priority)

### P3: Consider Removing `userPurchaseVolume`

**Current State (Line 106):**
```solidity
mapping(address => uint256) public userPurchaseVolume;
```

**Events Contain Purchase Amounts:**
```solidity
event BondingSale(address indexed user, uint256 amount, uint256 cost, bool isBuy);
```

**Discussion:** This is used for tier volume caps. Could be derived from events, but requires summing all user purchases. On-chain enforcement is cleaner here.

**Recommendation:** KEEP. Volume cap enforcement needs on-chain state for atomic validation.

---

## Summary Table

| Contract | State Variable | Priority | Gas Savings | Action |
|----------|---------------|----------|-------------|--------|
| MasterRegistryV1 | `allInstances[]` | P0 | ~20k/reg | DELETE |
| MasterRegistryV1 | `instanceIndex` | P0 | ~20k/reg | DELETE |
| MasterRegistryV1 | `creatorInstances` | P0 | ~20k/reg | DELETE |
| MasterRegistryV1 | `vaultInstances` | P0 | ~20k/reg | DELETE |
| MasterRegistryV1 | `vaultList[]` | P1 | ~20k/reg | DELETE |
| GlobalMessageRegistry | `instanceMessageIds` | P0 | ~20k/msg | DELETE |
| GlobalMessageRegistry | `messages[]` | P1 | ~20k/msg | ADD msg to event, then DELETE |
| FeaturedQueueManager | `positionDemand` | P1 | ~20k/rental | DELETE |
| VaultRegistry | `vaultList[]` | P0 | ~20k/reg | DELETE |
| VaultRegistry | `hookList[]` | P0 | ~20k/reg | DELETE |
| VaultRegistry | `hooksByVault` | P1 | ~20k/reg | DELETE |
| VaultRegistry | `instanceCount` fields | P2 | ~5k/reg | DELETE |
| ERC404Factory | `instanceToVault` | P2 | ~20k/create | DELETE |
| ERC404Factory | `instanceToHook` | P2 | ~20k/create | DELETE |
| ERC1155Factory | `instanceToVault` | P2 | ~20k/create | DELETE |

---

## Estimated Total Gas Savings

Per operation type:
- **Instance Registration:** ~80k gas saved (4 mappings/arrays removed)
- **Message Creation:** ~20-40k gas saved (1-2 structures removed)
- **Vault Registration:** ~40k gas saved (2 arrays removed)
- **Featured Rental:** ~20k gas saved (1 mapping removed)

**Cumulative:** At scale with thousands of instances, this represents significant gas savings.

---

## Migration Notes

1. **Deploy EventIndexer first** - Frontend must be ready to query events before removing state
2. **Version bump** - These are breaking changes to view functions
3. **ABI updates** - Remove deleted function signatures from ABIs
4. **Frontend updates** - Replace direct contract calls with EventIndexer queries

---

## Events to Verify/Enhance

Before removing state, verify these events have all necessary indexed fields:

| Event | Required Indexes | Status |
|-------|-----------------|--------|
| `InstanceRegistered` | instance, factory, creator | OK |
| `MessageAdded` | messageId, instance, sender | OK (add message text) |
| `VaultRegistered` | vault, creator | OK |
| `HookRegistered` | hook, creator, vault | OK |
| `PositionRented` | instance, renter | Need to verify |
| `InstanceCreated` (factories) | instance, creator, vault | OK |

---

## Questions for Contract Team

1. Is `positionDemand` used for pricing calculations that can't be done off-chain?
2. Any external contracts calling removed view functions?
3. Preferred migration strategy: deprecate then remove, or immediate removal?
