# Security Audit Checklist

This document tracks security hardening progress across all ms2.fun protocol features.

## Completed Audits ✅

- [x] **Master Registry Paid Spots** - Competitive queue system, payment refunds, utilization pricing
- [x] **Governance System** - FactoryApprovalGovernance voting and proposal mechanisms
- [x] **UltraAlignmentVault** - Share-based fee distribution, dragnet accumulation, claim calculations
- [x] **ERC404 Factory Staking** - Holder staking system, reward distribution, vault integration

## Pending Audits 🔍

### 1. ERC404 Bonding Curve System 🔴 CRITICAL - IN PROGRESS
**Priority**: CRITICAL
**Files**: `src/factories/erc404/ERC404BondingInstance.sol`, `src/factories/erc404/libraries/BondingCurveMath.sol`

**Attack Vectors to Review**:
- [ ] Buy/Sell reentrancy and frontrunning
- [ ] Bonding curve price manipulation
- [ ] Tier system password bypass
- [ ] Volume cap enforcement
- [ ] Time-based tier access control
- [ ] Free mint double-claim vulnerabilities
- [ ] Reserve accounting errors
- [ ] Message system spam/DoS
- [ ] Cost calculation overflow/underflow
- [ ] MaxCost/MinRefund slippage protection

**Key Functions**:
- `buyBonding()` - Purchase tokens from curve
- `sellBonding()` - Sell tokens back to curve
- `calculateCost()` - Cost calculation
- `calculateRefund()` - Refund calculation
- `setBondingActive()` - Activation control
- `canAccessTier()` - Tier access verification

---

### 2. ERC404 Staking System 🔴 HIGH
**Priority**: HIGH
**Files**: `src/factories/erc404/ERC404BondingInstance.sol` (staking section)

**Attack Vectors to Review**:
- [ ] Stake/unstake reentrancy
- [ ] Reward calculation rounding errors
- [ ] Proportional share manipulation
- [ ] Dust accumulation exploitation
- [ ] Tracking state corruption
- [ ] Auto-claim on unstake vulnerabilities
- [ ] First staker advantage
- [ ] Zero totalStaked division errors

**Key Functions**:
- `enableStaking()` - Enable staking (irreversible)
- `stake()` - Stake tokens for rewards
- `unstake()` - Unstake with auto-claim
- `claimStakerRewards()` - Claim accumulated rewards
- `calculatePendingRewards()` - View pending rewards
- `withdrawDust()` - Owner dust withdrawal

---

### 3. V4 Hook Tax Collection 🔴 HIGH
**Priority**: HIGH
**Files**: `src/factories/erc404/hooks/UltraAlignmentV4Hook.sol`

**Attack Vectors to Review**:
- [ ] Tax calculation manipulation
- [ ] Currency enforcement bypass (non-ETH/WETH)
- [ ] PoolManager take/settle abuse
- [ ] Tax rate change timing attacks
- [ ] Hook permission validation
- [ ] Rounding errors in tax calculation
- [ ] Swap direction edge cases
- [ ] Delta manipulation

**Key Functions**:
- `afterSwap()` - Hook callback for swaps
- `_processTax()` - Tax calculation and transfer
- `setTaxRate()` - Update tax rate

---

### 4. ERC404 V4 Liquidity Deployment 🔴 HIGH
**Priority**: HIGH
**Files**: `src/factories/erc404/ERC404BondingInstance.sol` (liquidity section)

**Attack Vectors to Review**:
- [ ] Front-running liquidity deployment
- [ ] Price initialization manipulation
- [ ] Unlock callback authorization
- [ ] Delta settlement exploits
- [ ] Tick range validation
- [ ] WETH wrapping vulnerabilities
- [ ] Approval race conditions
- [ ] Refund manipulation

**Key Functions**:
- `deployLiquidity()` - Deploy liquidity to V4
- `unlockCallback()` - PoolManager callback
- Token approvals and settlements

---

### 5. ERC1155 Pricing Models 🟡 MEDIUM
**Priority**: MEDIUM
**Files**: `src/factories/erc1155/ERC1155Instance.sol`, `src/factories/erc1155/libraries/EditionPricing.sol`

**Attack Vectors to Review**:
- [ ] Dynamic pricing overflow attacks
- [ ] Batch cost calculation errors
- [ ] Exponential growth manipulation
- [ ] Price increase rate validation
- [ ] Supply limit bypasses
- [ ] Edition creation authorization
- [ ] Metadata update exploits

**Key Functions**:
- `addEdition()` - Create new edition
- `calculateMintCost()` - Calculate mint cost
- `getCurrentPrice()` - Get current price
- `updateEditionMetadata()` - Update metadata

---

### 6. ERC404 Reroll System 🟡 MEDIUM
**Priority**: MEDIUM
**Files**: `src/factories/erc404/ERC404BondingInstance.sol` (reroll section)

**Attack Vectors to Review**:
- [ ] Escrow mechanism vulnerabilities
- [ ] NFT exemption bypass
- [ ] Balance verification failures
- [ ] Self-transfer exploits
- [ ] SkipNFT state corruption
- [ ] Token locking attacks
- [ ] Reentrancy during reroll

**Key Functions**:
- `rerollSelectedNFTs()` - Reroll NFTs with exemptions
- `getRerollEscrow()` - Query escrow state

---

### 7. ERC1155 Vault Fee Claims 🟡 MEDIUM
**Priority**: MEDIUM
**Files**: `src/factories/erc1155/ERC1155Instance.sol`

**Attack Vectors to Review**:
- [ ] Unauthorized vault fee claims
- [ ] 20% tithe bypass vulnerabilities
- [ ] Withdraw accounting errors
- [ ] Balance vs proceeds mismatch
- [ ] Creator authorization bypass
- [ ] Reentrancy in withdraw/claim flow

**Key Functions**:
- `withdraw()` - Withdraw with 20% tithe
- `claimVaultFees()` - Claim vault fees
- `getTotalProceeds()` - Query proceeds

---

### 8. ERC1155 Message System 🟢 LOW
**Priority**: LOW
**Files**: `src/factories/erc1155/ERC1155Instance.sol`, `src/factories/erc1155/libraries/EditionMessagePacking.sol`

**Attack Vectors to Review**:
- [ ] Message spam attacks
- [ ] Storage bloat DoS
- [ ] Batch query gas bombs
- [ ] Message packing data corruption
- [ ] Overflow in packed data

**Key Functions**:
- `mintWithMessage()` - Mint with message
- `getMessageDetails()` - Get single message
- `getMessagesBatch()` - Get message range

---

### 9. Factory Creation Fees 🟢 LOW
**Priority**: LOW
**Files**: `src/factories/erc404/ERC404Factory.sol`, `src/factories/erc1155/ERC1155Factory.sol`

**Attack Vectors to Review**:
- [ ] Fee bypass exploits
- [ ] Refund manipulation
- [ ] Duplicate instance registration
- [ ] Orphaned instance attacks
- [ ] Hook factory fee splitting

**Key Functions**:
- `createInstance()` - Create new instance
- `setInstanceCreationFee()` - Update fee

---

### 10. ERC404 Balance Mint 🟢 LOW
**Priority**: LOW
**Files**: `src/factories/erc404/ERC404BondingInstance.sol` (balance mint section)

**Attack Vectors to Review**:
- [ ] Unauthorized NFT creation
- [ ] SkipNFT state manipulation
- [ ] Self-transfer exploits
- [ ] Balance accounting errors
- [ ] Unit calculation overflow

**Key Functions**:
- `balanceMint()` - Mint NFTs from balance

---

## Audit Methodology

For each feature, we review:
1. **Access Control** - Who can call what and when
2. **State Transitions** - Valid state changes and invariants
3. **Economic Attacks** - Price/reward/fee manipulation
4. **Reentrancy** - External calls and state changes
5. **Integer Math** - Overflow, underflow, rounding
6. **Edge Cases** - Zero values, max values, boundary conditions
7. **Gas Optimization** - DoS via gas consumption
8. **Integration Points** - External contract interactions

---

## Legend

- 🔴 **CRITICAL** - Handles significant funds or core protocol logic
- 🟡 **MEDIUM** - Important but limited attack surface
- 🟢 **LOW** - Minor issues or DoS concerns
- ✅ **COMPLETED** - Audit finished and hardened
- 🔍 **IN PROGRESS** - Currently under review
