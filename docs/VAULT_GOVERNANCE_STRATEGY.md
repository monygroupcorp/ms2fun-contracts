# Vault Governance Strategy & Multi-Vault Architecture

## Executive Summary

This document outlines a strategy for expanding MasterRegistryV1 to support multiple vaults with governance and approval systems, mirroring the existing factory approval infrastructure.

---

## Current Architecture Analysis

### Vault Integration Pattern (As-Is)

```
Factory Creation Flow:
┌─────────────────────┐
│  ERC404Factory      │  createInstance(vault: optional)
│  ERC1155Factory     │  createInstance(vault: required)
└──────────┬──────────┘
           │
           ▼
┌─────────────────────────────┐         ┌──────────────────────────┐
│  Instance                   │────────→│  UltraAlignmentVault     │
│  - stores vault reference   │         │  - benefactor tracking   │
│  - calls receiveHookTax()   │         │  - share distribution    │
│  - calls claimFees()        │         │  - V4 LP management      │
└─────────────────────────────┘         └──────────────────────────┘

Fee Flow:
ERC1155: mint → withdraw (20% tithe) → vault.receive() or receiveHookTax()
ERC404:  swap → V4 hook → vault.receiveHookTax()
         ↓
Vault: accumulates fees, issues shares to benefactors
         ↓
Instance: vault.claimFees() → distribute to stakers/creators
```

### Current Vault Interface (Implicit)

**Required Methods:**
```solidity
interface IAlignmentVault {
    // Fee reception
    function receiveHookTax(Currency currency, uint256 amount, address benefactor) external payable;
    receive() external payable;

    // Fee claiming
    function claimFees() external returns (uint256 ethClaimed);
    function calculateClaimableAmount(address benefactor) external view returns (uint256);

    // Optional: share queries
    function getBenefactorShares(address benefactor) external view returns (uint256);
    function getBenefactorContribution(address benefactor) external view returns (uint256);
}
```

### Current Limitations

1. **No Vault Governance**: Any address can be set as vault (no approval process)
2. **No Vault Versioning**: Cannot migrate to improved vault implementations
3. **Single Vault Per Instance**: Instances can only route fees to one vault
4. **Implicit Interface**: No formal interface contract enforcing vault standards
5. **V4-Specific Implementation**: Current vault tightly coupled to Uniswap V4

---

## Proposed Architecture: Multi-Vault Governance System

### Design Principles

1. **Governance Parity**: Vault approval mirrors factory approval system
2. **Plug-and-Play**: Factories remain vault-agnostic via standardized interface
3. **Backward Compatibility**: Existing instances continue functioning
4. **Future-Proof**: Support new vault technologies (V5, other DEXes, etc.)
5. **Migration Support**: Instances can upgrade vault without redeployment

---

## Strategy 1: Vault Governance (Mirroring Factory Governance)

### Implementation Plan

#### 1.1 Create Vault Approval Governance Module

**File**: `src/governance/VaultApprovalGovernance.sol`

**Mimic**: `FactoryApprovalGovernance.sol`

```solidity
/**
 * @title VaultApprovalGovernance
 * @notice Governance module for vault approval via EXEC token voting
 * @dev Same voting mechanism as FactoryApprovalGovernance:
 *      - 3-phase voting (Debate → Vote → Challenge)
 *      - Quadratic voting via EXEC tokens
 *      - Multi-round challenge system
 *      - Security deposit (0.1 ETH application fee)
 */
contract VaultApprovalGovernance {
    // Application structure
    struct VaultApplication {
        address vaultAddress;
        address applicant;
        string vaultType;           // e.g., "UniswapV4LP", "AaveYield", "CurveStable"
        string title;
        string displayTitle;
        string metadataURI;
        bytes32[] features;         // e.g., ["full-range-lp", "auto-compound"]
        ApplicationStatus status;
        uint256 applicationFee;
        uint256 createdAt;
    }

    // Voting phases
    enum ApplicationPhase {
        Debate,        // 7 days: Community discussion
        Vote,          // 7 days: Voting on approval
        Challenge,     // 3 days: Challenge period
        Approved,
        Rejected
    }

    // Same voting logic as factory governance
    function submitVaultApplication(...) external payable;
    function voteOnVault(address vault, bool approve, uint256 execAmount) external;
    function challengeVault(address vault, string memory reason) external payable;
}
```

#### 1.2 Extend MasterRegistryV1 for Vault Governance

**Additions to `MasterRegistryV1.sol`:**

```solidity
// Add vault governance module reference
address public vaultGovernanceModule;

// Vault application forwarding
function applyForVault(
    address vaultAddress,
    string memory vaultType,
    string memory title,
    string memory displayTitle,
    string memory metadataURI,
    bytes32[] memory features
) external payable {
    require(vaultGovernanceModule != address(0), "Vault governance not set");
    IVaultApprovalGovernance(vaultGovernanceModule).submitVaultApplication{value: msg.value}(
        vaultAddress,
        vaultType,
        title,
        displayTitle,
        metadataURI,
        features,
        msg.sender
    );
}

// Approved vault registration (called by governance module)
function registerApprovedVault(
    address vaultAddress,
    string memory vaultType,
    string memory title,
    string memory displayTitle,
    string memory metadataURI,
    bytes32[] memory features
) external {
    require(msg.sender == vaultGovernanceModule, "Only vault governance");
    require(vaultAddress != address(0), "Invalid vault address");
    require(!registeredVaults[vaultAddress], "Vault already registered");

    registeredVaults[vaultAddress] = true;
    vaultList.push(vaultAddress);

    vaultInfo[vaultAddress] = VaultInfo({
        vault: vaultAddress,
        creator: tx.origin, // Applicant
        name: title,
        metadataURI: metadataURI,
        active: true,
        registeredAt: block.timestamp,
        instanceCount: 0
    });

    emit VaultRegistered(vaultAddress, tx.origin, title, 0);
}
```

#### 1.3 Vault Metadata Standard

**File**: `VAULT_METADATA_STANDARD.md`

```json
{
  "vaultType": "UniswapV4LP",
  "version": "1.0.0",
  "name": "Ultra Alignment Vault",
  "description": "Full-range liquidity provision on Uniswap V4",
  "deploymentChains": [1, 8453, 42161],
  "features": [
    "full-range-lp",
    "auto-compound",
    "benefactor-shares",
    "eth-native"
  ],
  "riskProfile": {
    "level": "medium",
    "factors": ["impermanent-loss", "smart-contract-risk", "v4-dependency"]
  },
  "feeStructure": {
    "managementFee": "0%",
    "performanceFee": "0%",
    "conversionReward": "0.0012 ETH (gas + incentive)"
  },
  "auditReports": [
    {
      "auditor": "Example Security",
      "date": "2024-01-01",
      "reportUri": "ipfs://..."
    }
  ],
  "interfaceCompliance": "IAlignmentVault v1.0"
}
```

---

## Strategy 2: Formal Vault Interface Standard

### 2.1 Create IAlignmentVault Interface

**File**: `src/interfaces/IAlignmentVault.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Currency} from "v4-core/types/Currency.sol";

/**
 * @title IAlignmentVault
 * @notice Standard interface for alignment vaults compatible with ms2fun ecosystem
 * @dev All vaults must implement this interface to be approved by governance
 */
interface IAlignmentVault {
    // ========== Events ==========

    event ContributionReceived(address indexed benefactor, uint256 amount);
    event FeesClaimed(address indexed benefactor, uint256 ethAmount);
    event FeesAccumulated(uint256 amount);

    // ========== Fee Reception ==========

    /**
     * @notice Receive alignment taxes from V4 hooks with benefactor attribution
     * @param currency Currency of the tax (native ETH or ERC20)
     * @param amount Amount of tax received
     * @param benefactor Address to credit for this contribution
     */
    function receiveHookTax(
        Currency currency,
        uint256 amount,
        address benefactor
    ) external payable;

    /**
     * @notice Receive native ETH contributions
     * @dev Must track msg.sender as benefactor
     */
    receive() external payable;

    // ========== Fee Claiming ==========

    /**
     * @notice Claim accumulated fees for caller
     * @dev Must calculate proportional share based on benefactor's contribution
     * @return ethClaimed Amount of ETH transferred to caller
     */
    function claimFees() external returns (uint256 ethClaimed);

    /**
     * @notice Calculate claimable amount for benefactor without claiming
     * @param benefactor Address to query
     * @return Amount of ETH claimable by this benefactor
     */
    function calculateClaimableAmount(address benefactor) external view returns (uint256);

    // ========== Share Queries (Optional) ==========

    /**
     * @notice Get benefactor's total historical contribution
     * @param benefactor Address to query
     * @return Total ETH contributed by this benefactor (for bragging rights)
     */
    function getBenefactorContribution(address benefactor) external view returns (uint256);

    /**
     * @notice Get benefactor's current share balance
     * @param benefactor Address to query
     * @return Share balance (vault-specific units)
     */
    function getBenefactorShares(address benefactor) external view returns (uint256);

    // ========== Vault Info ==========

    /**
     * @notice Get vault implementation type
     * @return Vault type identifier (e.g., "UniswapV4LP", "AaveYield")
     */
    function vaultType() external view returns (string memory);

    /**
     * @notice Get total accumulated fees in vault
     * @return Total ETH fees accumulated
     */
    function accumulatedFees() external view returns (uint256);

    /**
     * @notice Get total shares issued
     * @return Total shares across all benefactors
     */
    function totalShares() external view returns (uint256);
}
```

### 2.2 UltraAlignmentVault Implements IAlignmentVault

**Changes to `UltraAlignmentVault.sol`:**

```solidity
contract UltraAlignmentVault is
    ReentrancyGuard,
    Ownable,
    IUnlockCallback,
    IAlignmentVault  // ← Add interface implementation
{
    // Add vaultType() implementation
    function vaultType() external pure override returns (string memory) {
        return "UniswapV4LP";
    }

    // Existing functions already match IAlignmentVault interface
    // No changes needed to:
    // - receiveHookTax()
    // - receive()
    // - claimFees()
    // - calculateClaimableAmount()
    // - getBenefactorContribution()
    // - getBenefactorShares()
    // - accumulatedFees (public var)
    // - totalShares (public var)
}
```

---

## Strategy 3: Factory Vault Agnosticism (Plug-and-Play)

### Current Status: ✅ MOSTLY READY

**Analysis:**
- ✅ Factories already accept `vault` as parameter
- ✅ Factories don't assume vault implementation details
- ✅ Instances store vault reference but use generic interface
- ⚠️ **Issue**: Instances assume vault has `receiveHookTax()` and `claimFees()`
- ⚠️ **Issue**: No validation that vault implements IAlignmentVault

### Required Changes

#### 3.1 Vault Interface Validation in Factories

**Update ERC404Factory.sol:**

```solidity
import {IAlignmentVault} from "../interfaces/IAlignmentVault.sol";

function createInstance(..., address vault) external payable returns (address instance) {
    // Validate vault if provided
    if (vault != address(0)) {
        require(vault.code.length > 0, "Vault must be a contract");

        // Validate vault is approved by governance
        require(masterRegistry.isVaultRegistered(vault), "Vault not approved");

        // Validate vault implements IAlignmentVault (via ERC165 or interface check)
        require(_supportsVaultInterface(vault), "Vault must implement IAlignmentVault");
    }

    // Rest of creation logic...
}

function _supportsVaultInterface(address vault) internal view returns (bool) {
    // Try calling vaultType() - if it reverts, vault is not compliant
    try IAlignmentVault(vault).vaultType() returns (string memory) {
        return true;
    } catch {
        return false;
    }
}
```

**Update ERC1155Factory.sol:**

```solidity
function createInstance(..., address vault) external payable returns (address instance) {
    require(vault != address(0), "Vault is required");
    require(vault.code.length > 0, "Vault must be a contract");

    // Add governance validation
    require(masterRegistry.isVaultRegistered(vault), "Vault not approved");
    require(_supportsVaultInterface(vault), "Vault must implement IAlignmentVault");

    // Rest of creation logic...
}
```

#### 3.2 Instance Vault Agnosticism

**Current State**: Instances are ALREADY vault-agnostic!

```solidity
// ERC404BondingInstance.sol
UltraAlignmentVault public vault;  // ← Type-specific reference

// Should be:
IAlignmentVault public vault;  // ← Interface reference
```

**Changes needed:**
1. Replace `UltraAlignmentVault` type with `IAlignmentVault` interface
2. Remove any V4-specific assumptions in instance code
3. Use interface methods only

**Example (ERC404BondingInstance.sol):**

```solidity
import {IAlignmentVault} from "../interfaces/IAlignmentVault.sol";

contract ERC404BondingInstance {
    IAlignmentVault public vault;  // ← Interface, not concrete type

    function setVault(address payable _vault) external onlyOwner {
        require(_vault != address(0), "Invalid vault");
        require(address(vault) == address(0), "Vault already set");

        // Validate vault compliance
        require(IAlignmentVault(_vault).vaultType().length > 0, "Invalid vault");

        vault = IAlignmentVault(_vault);
    }

    function claimStakerRewards() external nonReentrant returns (uint256 rewardAmount) {
        // Uses interface method - works with ANY compliant vault
        uint256 deltaReceived = vault.claimFees();

        // Rest of reward logic...
    }
}
```

---

## Strategy 4: Multi-Vault Support (Advanced)

### Use Case

An instance might want to:
- Route 80% of fees to V4 LP vault (high yield)
- Route 20% of fees to stable yield vault (low risk)
- Migrate from V4 vault to V5 vault without redeployment

### Implementation

#### 4.1 Vault Router Pattern

**File**: `src/vaults/VaultRouter.sol`

```solidity
/**
 * @title VaultRouter
 * @notice Routes fees to multiple vaults with weighted distribution
 * @dev Implements IAlignmentVault interface, acts as vault aggregator
 */
contract VaultRouter is IAlignmentVault {
    struct VaultAllocation {
        IAlignmentVault vault;
        uint256 weight;  // Basis points (10000 = 100%)
        bool active;
    }

    mapping(uint256 => VaultAllocation) public vaultAllocations;
    uint256 public vaultCount;
    uint256 public constant TOTAL_WEIGHT = 10000;

    /**
     * @notice Receive fees and split across vaults
     */
    function receiveHookTax(
        Currency currency,
        uint256 amount,
        address benefactor
    ) external payable override {
        for (uint256 i = 0; i < vaultCount; i++) {
            VaultAllocation memory allocation = vaultAllocations[i];
            if (!allocation.active) continue;

            uint256 share = (amount * allocation.weight) / TOTAL_WEIGHT;
            allocation.vault.receiveHookTax{value: share}(currency, share, benefactor);
        }
    }

    /**
     * @notice Claim fees from all vaults
     */
    function claimFees() external override returns (uint256 totalClaimed) {
        for (uint256 i = 0; i < vaultCount; i++) {
            VaultAllocation memory allocation = vaultAllocations[i];
            if (!allocation.active) continue;

            totalClaimed += allocation.vault.claimFees();
        }
    }

    /**
     * @notice Add vault to allocation
     */
    function addVault(address vault, uint256 weight) external onlyOwner {
        require(masterRegistry.isVaultRegistered(vault), "Vault not approved");
        require(_validateWeights(weight), "Invalid weight distribution");

        vaultAllocations[vaultCount] = VaultAllocation({
            vault: IAlignmentVault(vault),
            weight: weight,
            active: true
        });
        vaultCount++;
    }

    /**
     * @notice Update vault weights (for rebalancing)
     */
    function updateVaultWeight(uint256 vaultId, uint256 newWeight) external onlyOwner {
        require(_validateWeights(newWeight), "Invalid weight distribution");
        vaultAllocations[vaultId].weight = newWeight;
    }
}
```

#### 4.2 Vault Migration Support

**Add to Instance contracts:**

```solidity
contract ERC404BondingInstance {
    IAlignmentVault public vault;
    IAlignmentVault public pendingVault;
    uint256 public vaultMigrationDeadline;

    /**
     * @notice Propose vault migration (2-step process for safety)
     */
    function proposeVaultMigration(address newVault) external onlyOwner {
        require(masterRegistry.isVaultRegistered(newVault), "Vault not approved");
        require(IAlignmentVault(newVault).vaultType().length > 0, "Invalid vault");

        pendingVault = IAlignmentVault(newVault);
        vaultMigrationDeadline = block.timestamp + 7 days;  // 7-day timelock

        emit VaultMigrationProposed(address(vault), newVault, vaultMigrationDeadline);
    }

    /**
     * @notice Execute vault migration after timelock
     */
    function executeVaultMigration() external onlyOwner {
        require(address(pendingVault) != address(0), "No pending migration");
        require(block.timestamp >= vaultMigrationDeadline, "Timelock not expired");

        // Claim all fees from old vault before migration
        if (address(vault) != address(0)) {
            uint256 finalClaim = vault.claimFees();
            // Forward to new vault as initial contribution
            if (finalClaim > 0) {
                pendingVault.receiveHookTax{value: finalClaim}(
                    Currency.wrap(address(0)),
                    finalClaim,
                    address(this)
                );
            }
        }

        // Switch to new vault
        vault = pendingVault;
        pendingVault = IAlignmentVault(address(0));
        vaultMigrationDeadline = 0;

        emit VaultMigrated(address(vault));
    }
}
```

---

## Strategy 5: Implementation Phases

### Phase 1: Foundation (Week 1-2)
- [ ] Create `IAlignmentVault.sol` interface
- [ ] Update `UltraAlignmentVault.sol` to implement interface
- [ ] Add `vaultType()` method to existing vault
- [ ] Write vault interface compliance tests

### Phase 2: Governance Infrastructure (Week 3-4)
- [ ] Create `VaultApprovalGovernance.sol` (clone of FactoryApprovalGovernance)
- [ ] Extend `MasterRegistryV1.sol` with vault governance hooks
- [ ] Add `applyForVault()` and `registerApprovedVault()` functions
- [ ] Create vault metadata standard documentation
- [ ] Deploy governance module and connect to MasterRegistry

### Phase 3: Factory Updates (Week 5)
- [ ] Update `ERC404Factory.sol` with vault validation
- [ ] Update `ERC1155Factory.sol` with vault validation
- [ ] Replace concrete vault types with `IAlignmentVault` interface
- [ ] Add `_supportsVaultInterface()` validation checks
- [ ] Add `masterRegistry.isVaultRegistered()` checks

### Phase 4: Instance Updates (Week 6)
- [ ] Update `ERC404BondingInstance.sol` to use `IAlignmentVault`
- [ ] Update `ERC1155Instance.sol` to use `IAlignmentVault`
- [ ] Remove V4-specific assumptions from instance code
- [ ] Add vault migration support (2-step timelock pattern)

### Phase 5: Advanced Features (Week 7-8)
- [ ] Create `VaultRouter.sol` for multi-vault support
- [ ] Add weighted fee distribution logic
- [ ] Implement vault rebalancing functions
- [ ] Create vault migration helpers

### Phase 6: Testing & Documentation (Week 9-10)
- [ ] Write comprehensive vault governance tests
- [ ] Test vault migration flows
- [ ] Test multi-vault routing
- [ ] Create vault developer documentation
- [ ] Create vault application guide for governance

---

## Readiness Assessment

### Contracts Ready for Multi-Vault ✅

**MasterRegistryV1.sol**
- ✅ Already has vault registry infrastructure
- ✅ Has `vaultInfo` mapping and `registeredVaults`
- ⚠️ Missing governance integration
- ⚠️ Missing vault application flow

**ERC404Factory.sol & ERC1155Factory.sol**
- ✅ Already accept vault as parameter
- ✅ No vault-specific logic in factory
- ✅ Pass vault to instances via constructor
- ⚠️ Missing vault validation (governance check)
- ⚠️ Missing interface compliance check

**UltraAlignmentVault.sol**
- ✅ Already implements required interface methods
- ✅ Uses benefactor pattern (works with any instance)
- ✅ Generic fee reception and claiming
- ⚠️ Missing formal `IAlignmentVault` declaration
- ⚠️ Missing `vaultType()` method

### Contracts Needing Updates ⚠️

**ERC404BondingInstance.sol**
- ⚠️ Uses concrete `UltraAlignmentVault` type instead of interface
- ⚠️ Assumes vault has specific V4 methods
- ⚠️ No vault migration support
- ✅ Otherwise vault-agnostic (uses generic claim methods)

**ERC1155Instance.sol**
- ⚠️ Uses concrete `UltraAlignmentVault` type instead of interface
- ⚠️ No vault migration support
- ✅ Otherwise vault-agnostic (uses receive() and claimFees())

### New Contracts Needed 🆕

1. **`IAlignmentVault.sol`** - Standard interface
2. **`VaultApprovalGovernance.sol`** - Governance module
3. **`VaultRouter.sol`** (optional) - Multi-vault aggregator
4. **Test Vaults** for validation:
   - `AaveYieldVault.sol` (test alternative implementation)
   - `MockVault.sol` (for testing)

---

## Risk Analysis

### Low Risk ✅
- Interface standardization (backward compatible)
- Vault governance (same as factory governance)
- Factory validation updates (optional checks)

### Medium Risk ⚠️
- Vault migration (requires careful testing)
- Instance type changes (UltraAlignmentVault → IAlignmentVault)
- Multi-vault routing (complex fee distribution)

### High Risk ⚠️⚠️
- **Breaking changes to existing instances** if interface changes
- **Governance manipulation** if voting system has flaws
- **Fee loss** during vault migration if not handled correctly

### Mitigation Strategies

1. **Backward Compatibility**: Keep existing `UltraAlignmentVault` working
2. **Gradual Rollout**: Phase 1-4 = no breaking changes, Phase 5-6 = opt-in features
3. **Timelock Protection**: 7-day migration timelock for safety
4. **Interface Versioning**: `IAlignmentVault_v1`, `IAlignmentVault_v2`, etc.
5. **Governance Testing**: Deploy on testnet first, run security audit

---

## Alternative Vault Examples (Future)

### Example 1: Aave Yield Vault

```solidity
contract AaveYieldVault is IAlignmentVault {
    function vaultType() external pure returns (string memory) {
        return "AaveYield";
    }

    // Deposits ETH into Aave, earns yield
    // Benefactors share yield proportionally
}
```

### Example 2: Curve Stable Vault

```solidity
contract CurveStableVault is IAlignmentVault {
    function vaultType() external pure returns (string memory) {
        return "CurveStable";
    }

    // Swaps ETH → stablecoin, deposits into Curve
    // Lower risk, lower yield
}
```

### Example 3: Uniswap V5 Vault (Future)

```solidity
contract UniswapV5Vault is IAlignmentVault {
    function vaultType() external pure returns (string memory) {
        return "UniswapV5LP";
    }

    // Uses future Uniswap V5 features
    // Backward compatible via IAlignmentVault
}
```

---

## Conclusion

### Summary

The ms2fun architecture is **80% ready** for multi-vault governance:

✅ **Already Built:**
- Vault registry in MasterRegistryV1
- Benefactor model in UltraAlignmentVault
- Factory vault parameterization
- Instance vault integration

⚠️ **Needs Work:**
- Formal IAlignmentVault interface
- Vault governance module
- Factory/instance validation updates
- Vault migration support

### Recommended Path Forward

1. **Start with Phase 1-2**: Create interface + governance (2-4 weeks)
2. **Phase 3-4**: Update factories + instances (2 weeks)
3. **Deploy & Test**: Testnet deployment with multiple vault types
4. **Phase 5-6**: Advanced features (multi-vault routing) if needed

### Key Insight

> The genius of the current architecture is that **vaults are already abstracted**. Instances don't care HOW vaults accumulate yield, they just care about the benefactor model. This makes the system inherently extensible.

By adding governance and interface standardization, you'll unlock a marketplace of competing vault strategies while maintaining full backward compatibility.
