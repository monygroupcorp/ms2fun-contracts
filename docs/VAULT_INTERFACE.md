# IAlignmentVault Interface Documentation

**Version**: 1.0.0
**Last Updated**: 2025-01-06
**Status**: Production Ready

---

## Overview

The `IAlignmentVault` interface defines the standard contract interface for all alignment vaults in the ms2fun ecosystem. This interface enables:

- **Governance approval** of vault implementations
- **Factory/instance compatibility** across all vault types
- **Frontend integration** with consistent vault metadata
- **Future-proof extensibility** for new yield strategies

Any contract implementing this interface can be approved by governance and used by project instances for fee accumulation and distribution.

---

## Interface Location

```solidity
src/interfaces/IAlignmentVault.sol
```

---

## Core Concepts

### Benefactor Model

Vaults use a **benefactor** model where:
1. Project instances send ETH fees to the vault
2. Vault tracks each instance as a "benefactor" and issues proportional shares
3. Benefactors can claim accumulated fees based on their share percentage
4. Vaults are responsible for yield generation strategy (V4 LP, Aave, etc.)

**Key Point**: Instances don't need to know HOW vaults generate yield, only that they can send fees and claim rewards.

### Share-Based Distribution

```
Benefactor's Claimable Amount = (Total Accumulated Fees × Benefactor Shares) ÷ Total Shares
```

Shares represent proportional ownership of vault fees. The vault determines how shares are issued based on contributions.

---

## Required Methods

### Fee Reception

#### `receiveHookTax(Currency currency, uint256 amount, address benefactor)`

```solidity
function receiveHookTax(
    Currency currency,
    uint256 amount,
    address benefactor
) external payable;
```

**Purpose**: Receive alignment taxes with explicit benefactor attribution

**Parameters**:
- `currency` - Currency of the tax (native ETH = `address(0)`, or ERC20)
- `amount` - Amount of tax received (in wei or token units)
- `benefactor` - Address to credit for this contribution (the project instance)

**Usage**:
```solidity
// V4 hook sending tax to vault
vault.receiveHookTax{value: taxAmount}(
    Currency.wrap(address(0)),  // Native ETH
    taxAmount,
    address(this)  // Credit this instance as benefactor
);
```

**Requirements**:
- Must track `benefactor` as contributor (not necessarily `msg.sender`)
- Must emit `ContributionReceived` event
- Must handle ETH via `msg.value`

---

#### `receive()`

```solidity
receive() external payable;
```

**Purpose**: Receive native ETH contributions via fallback

**Usage**:
```solidity
// Direct ETH transfer
(bool success, ) = address(vault).call{value: amount}("");
```

**Requirements**:
- Must track `msg.sender` as benefactor
- Must emit `ContributionReceived` event
- Used when instances send ETH without calling `receiveHookTax()`

---

### Fee Claiming

#### `claimFees()`

```solidity
function claimFees() external returns (uint256 ethClaimed);
```

**Purpose**: Claim accumulated fees for caller

**Returns**: Amount of ETH transferred to caller

**Usage**:
```solidity
// Instance claims fees
uint256 claimed = vault.claimFees();
// Transfer to stakers/creator
SafeTransferLib.safeTransferETH(recipient, claimed);
```

**Requirements**:
- Must calculate proportional share: `(accumulatedFees × benefactorShares[caller]) ÷ totalShares`
- Must support multi-claim (only pay unclaimed amount since last claim)
- Must track `shareValueAtLastClaim[benefactor]` for delta calculation
- Must emit `FeesClaimed` event

**Multi-Claim Support**:
```solidity
// First claim: user gets 100% of current fees
vault.claimFees(); // Returns 10 ETH

// Vault generates more yield...
// Second claim: user only gets NEW fees since last claim
vault.claimFees(); // Returns 5 ETH (new yield)
```

---

#### `calculateClaimableAmount(address benefactor)`

```solidity
function calculateClaimableAmount(address benefactor)
    external
    view
    returns (uint256);
```

**Purpose**: Query claimable amount without claiming

**Parameters**:
- `benefactor` - Address to query

**Returns**: Total ETH claimable by this benefactor (not delta)

**Usage**:
```solidity
// Check claimable before claiming
uint256 available = vault.calculateClaimableAmount(msg.sender);
if (available > minimumClaim) {
    vault.claimFees();
}
```

---

### Share Queries

#### `getBenefactorContribution(address benefactor)`

```solidity
function getBenefactorContribution(address benefactor)
    external
    view
    returns (uint256);
```

**Purpose**: Get total historical contribution (for leaderboards/UI)

**Returns**: Cumulative lifetime ETH contributed (never decreases)

**Usage**:
```solidity
// Display leaderboard
uint256 totalContributed = vault.getBenefactorContribution(instance);
console.log("Total contributed:", totalContributed);
```

---

#### `getBenefactorShares(address benefactor)`

```solidity
function getBenefactorShares(address benefactor)
    external
    view
    returns (uint256);
```

**Purpose**: Get current share balance

**Returns**: Share balance in vault-specific units

**Usage**:
```solidity
// Calculate share percentage
uint256 shares = vault.getBenefactorShares(instance);
uint256 total = vault.totalShares();
uint256 percentage = (shares * 100) / total;
```

---

### Vault Info

#### `vaultType()`

```solidity
function vaultType() external view returns (string memory);
```

**Purpose**: Get vault implementation type identifier

**Returns**: Human-readable type string

**Examples**:
- `"UniswapV4LP"` - Uniswap V4 liquidity provision
- `"AaveYield"` - Aave ETH lending
- `"CurveStable"` - Curve stablecoin pools
- `"MockVault"` - Testing vault

**Usage**:
```solidity
// Governance classification
string memory vType = vault.vaultType();
if (keccak256(bytes(vType)) == keccak256("UniswapV4LP")) {
    // V4-specific logic
}
```

**Requirements**:
- Must be non-empty string
- Should be consistent and descriptive
- Used by governance for risk assessment

---

#### `description()`

```solidity
function description() external view returns (string memory);
```

**Purpose**: Get human-readable vault description for frontend display

**Returns**: 1-2 sentence description of vault strategy

**Examples**:
- `"Full-range liquidity provision on Uniswap V4 with automated fee compounding and benefactor share distribution"`
- `"Low-risk stable yield via Aave ETH lending"`
- `"Mock vault for testing - stores ETH without yield generation (testing only, do not use in production)"`

**Usage**:
```solidity
// Frontend display
string memory desc = vault.description();
console.log("Vault Strategy:", desc);
```

**Requirements**:
- Must be non-empty (>0 characters)
- Should be descriptive (recommended >20 characters)
- Should explain yield strategy and risk profile

---

#### `accumulatedFees()`

```solidity
function accumulatedFees() external view returns (uint256);
```

**Purpose**: Get total accumulated fees in vault

**Returns**: Total ETH fees available for benefactor claims (in wei)

**Usage**:
```solidity
// Check vault health
uint256 fees = vault.accumulatedFees();
console.log("Total fees available:", fees);
```

**Note**: Increases when yield generated, decreases when fees claimed

---

#### `totalShares()`

```solidity
function totalShares() external view returns (uint256);
```

**Purpose**: Get total shares issued across all benefactors

**Returns**: Total shares in vault-specific units

**Usage**:
```solidity
// Calculate share percentage
uint256 total = vault.totalShares();
uint256 myShares = vault.getBenefactorShares(msg.sender);
uint256 myPercent = (myShares * 10000) / total; // Basis points
```

---

## Events

### `ContributionReceived`

```solidity
event ContributionReceived(address indexed benefactor, uint256 amount);
```

**Emitted**: When benefactor contributes ETH to vault

**Parameters**:
- `benefactor` - Address credited for contribution
- `amount` - ETH amount received

---

### `FeesClaimed`

```solidity
event FeesClaimed(address indexed benefactor, uint256 ethAmount);
```

**Emitted**: When benefactor claims accumulated fees

**Parameters**:
- `benefactor` - Address that claimed fees
- `ethAmount` - ETH amount transferred

---

### `FeesAccumulated`

```solidity
event FeesAccumulated(uint256 amount);
```

**Emitted**: When vault accumulates new fees from yield generation

**Parameters**:
- `amount` - New fees added to vault

---

## Implementation Guide

### Step 1: Implement Interface

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAlignmentVault} from "../interfaces/IAlignmentVault.sol";
import {Currency} from "v4-core/types/Currency.sol";

contract MyCustomVault is IAlignmentVault {
    // State variables
    mapping(address => uint256) public benefactorTotalETH;
    mapping(address => uint256) public override benefactorShares; // Note: can't use override on mappings
    uint256 public override totalShares;
    uint256 public override accumulatedFees;

    // Implement all interface methods...
}
```

### Step 2: Implement vaultType() and description()

```solidity
function vaultType() external pure override returns (string memory) {
    return "MyCustomVault";
}

function description() external pure override returns (string memory) {
    return "Custom yield strategy with [explain your approach]";
}
```

### Step 3: Implement Fee Reception

```solidity
function receiveHookTax(
    Currency currency,
    uint256 amount,
    address benefactor
) external payable override {
    require(msg.value >= amount, "Insufficient ETH sent");
    require(amount > 0, "Amount must be positive");
    require(benefactor != address(0), "Invalid benefactor");

    // Track contribution
    benefactorTotalETH[benefactor] += amount;

    // Issue shares (your logic here)
    uint256 sharesToIssue = _calculateShares(amount);
    benefactorShares[benefactor] += sharesToIssue;
    totalShares += sharesToIssue;

    // Accumulate fees (or invest for yield)
    accumulatedFees += amount;

    emit ContributionReceived(benefactor, amount);
    emit FeesAccumulated(amount);
}

receive() external payable override {
    require(msg.value > 0, "Amount must be positive");

    // Track msg.sender as benefactor
    receiveHookTax(
        Currency.wrap(address(0)),
        msg.value,
        msg.sender
    );
}
```

### Step 4: Implement Fee Claiming

```solidity
function claimFees() external override returns (uint256 ethClaimed) {
    address benefactor = msg.sender;

    require(benefactorShares[benefactor] > 0, "No shares");
    require(accumulatedFees > 0, "No fees to claim");

    // Calculate proportional share
    uint256 currentShareValue = (accumulatedFees * benefactorShares[benefactor]) / totalShares;

    // Calculate unclaimed amount (delta)
    ethClaimed = currentShareValue > shareValueAtLastClaim[benefactor]
        ? currentShareValue - shareValueAtLastClaim[benefactor]
        : 0;

    require(ethClaimed > 0, "No new fees to claim");
    require(address(this).balance >= ethClaimed, "Insufficient ETH");

    // Update state BEFORE transfer
    shareValueAtLastClaim[benefactor] = currentShareValue;
    accumulatedFees -= ethClaimed; // Optional: track fees paid out

    // Transfer ETH
    (bool success, ) = payable(benefactor).call{value: ethClaimed}("");
    require(success, "Transfer failed");

    emit FeesClaimed(benefactor, ethClaimed);
    return ethClaimed;
}
```

### Step 5: Implement Yield Strategy

```solidity
// Your custom yield generation logic
// Examples:
// - Deposit to Aave
// - Add LP to Uniswap V4/V5
// - Stake in protocol
// - Convert to stablecoins
// etc.

function generateYield() internal {
    // Your logic here...
    // Update accumulatedFees when yield is earned
}
```

---

## Testing Your Implementation

### Use the Compliance Test Suite

```solidity
import {VaultInterfaceComplianceTest} from "../test/vaults/VaultInterfaceCompliance.t.sol";

contract MyVaultTest is VaultInterfaceComplianceTest {
    function setUp() public override {
        super.setUp();

        // Replace mockVault with your vault
        mockVault = MyCustomVault(...);
    }

    // All 19 compliance tests will run against your vault
}
```

### Required Test Coverage

✅ Interface implementation (vaultType, description)
✅ Fee reception (receiveHookTax, receive)
✅ Fee claiming (claimFees, calculateClaimableAmount)
✅ Share queries (getBenefactorShares, getBenefactorContribution)
✅ Multi-benefactor scenarios
✅ Multi-claim support
✅ Event emissions
✅ Edge cases (unknown benefactor, zero shares, etc.)

---

## Common Patterns

### Pattern 1: 1:1 Share Issuance (Simple)

```solidity
// 1 ETH contributed = 1 share issued
benefactorShares[benefactor] += amount;
totalShares += amount;
```

**Use Case**: MockVault, testing

---

### Pattern 2: Liquidity-Based Shares (Complex)

```solidity
// Shares based on liquidity units created
uint128 liquidityUnits = _addLiquidity(amount);
benefactorShares[benefactor] += uint256(liquidityUnits);
totalShares += uint256(liquidityUnits);
```

**Use Case**: UltraAlignmentVault (Uniswap V4)

---

### Pattern 3: Weighted Shares by Duration

```solidity
// Longer commitments get more shares
uint256 baseShares = amount;
uint256 timeBonus = (amount * lockDuration) / 365 days;
uint256 totalSharesIssued = baseShares + timeBonus;
```

**Use Case**: Staking vaults

---

## Governance Approval Process

### Step 1: Submit Application

```solidity
// Via MasterRegistry
masterRegistry.applyForVault(
    vaultAddress,
    "MyCustomVault",                    // vaultType
    "My Custom Vault",                  // title
    "Custom Yield Vault",               // displayTitle
    "ipfs://metadata-uri",              // metadataURI
    ["feature1", "feature2"]            // features
);
```

### Step 2: Community Voting

- 3-phase voting (Debate → Vote → Challenge)
- EXEC token holders vote
- Quadratic voting mechanism
- Multi-round challenge system

### Step 3: Automatic Registration

Upon approval, vault is automatically registered in MasterRegistry and can be used by factories.

---

## Integration Examples

### Factory Integration

```solidity
// Factory validates vault before instance creation
function createInstance(..., address vault) external {
    require(masterRegistry.isVaultRegistered(vault), "Vault not approved");

    // Create instance with approved vault
    instance = new Instance(..., vault);
}
```

### Instance Integration

```solidity
// Instance uses interface for vault-agnostic operation
IAlignmentVault public vault;

function sendFeesToVault(uint256 amount) external {
    vault.receiveHookTax{value: amount}(
        Currency.wrap(address(0)),
        amount,
        address(this)  // This instance is benefactor
    );
}

function distributeRewards() external {
    uint256 fees = vault.claimFees();
    // Distribute to stakers/creators
}
```

### Frontend Integration

```solidity
// Display vault info
string memory vType = vault.vaultType();
string memory desc = vault.description();
uint256 tvl = vault.accumulatedFees();

console.log("Vault:", vType);
console.log("Strategy:", desc);
console.log("TVL:", tvl);
```

---

## Security Considerations

### Reentrancy

Always use `nonReentrant` modifier on:
- `receiveHookTax()`
- `claimFees()`
- Any function transferring ETH

### State Updates Before Transfers

```solidity
// ✅ CORRECT
accumulatedFees -= ethClaimed;
(bool success, ) = payable(benefactor).call{value: ethClaimed}("");

// ❌ WRONG
(bool success, ) = payable(benefactor).call{value: ethClaimed}("");
accumulatedFees -= ethClaimed;
```

### Share Calculation Precision

```solidity
// Avoid division before multiplication
// ✅ CORRECT
uint256 claimable = (accumulatedFees * shares) / totalShares;

// ❌ WRONG
uint256 sharePercent = shares / totalShares;
uint256 claimable = accumulatedFees * sharePercent;
```

### Zero Division Protection

```solidity
if (totalShares == 0 || accumulatedFees == 0) return 0;
```

---

## Reference Implementations

### MockVault (Simple, 1:1 Shares)
```
test/mocks/MockVault.sol
```
- No yield generation
- 1:1 share issuance
- Perfect for testing

### UltraAlignmentVault (Production, V4 LP)
```
src/vaults/UltraAlignmentVault.sol
```
- Uniswap V4 liquidity provision
- Full-range LP positions
- Automated compounding
- Production-ready

---

## Frequently Asked Questions

### Q: Can I modify the interface?

**A**: No. The interface is standardized for governance and compatibility. If you need additional methods, add them to your implementation but keep all required methods.

### Q: Do I need to use the exact event names?

**A**: Yes. The interface defines required events (`ContributionReceived`, `FeesClaimed`, `FeesAccumulated`) that must be emitted.

### Q: Can shares be non-fungible (NFTs)?

**A**: The interface expects `uint256` shares. If you want NFT-like behavior, track share balances per benefactor but return aggregated values in `getBenefactorShares()`.

### Q: What if my vault uses ERC20 instead of ETH?

**A**: The interface supports both via the `Currency` type in `receiveHookTax()`. For ERC20, use `Currency.wrap(tokenAddress)` instead of `Currency.wrap(address(0))`.

### Q: How do I handle failed claims?

**A**: Revert the transaction. Don't partially update state. Use `require()` for validation.

### Q: Can benefactors transfer their shares?

**A**: The interface doesn't define transfer methods. If you want transferable shares, implement additional functions in your vault (not part of the standard interface).

---

## Support & Resources

- **Interface Source**: `src/interfaces/IAlignmentVault.sol`
- **Test Suite**: `test/vaults/VaultInterfaceCompliance.t.sol`
- **Reference Implementation**: `src/vaults/UltraAlignmentVault.sol`
- **Mock Implementation**: `test/mocks/MockVault.sol`
- **Governance**: See `VAULT_GOVERNANCE_STRATEGY.md`
- **Project Tracker**: `VAULT_EXPANSION_TRACKER.md`

---

**Version History**:
- **v1.0.0** (2025-01-06): Initial interface with `description()` method
- Added `description()` for frontend display
- 19 compliance tests passing
- Production ready

**Maintainer**: ms2fun Core Team
**License**: MIT
