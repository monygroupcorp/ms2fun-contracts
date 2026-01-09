# Frontend Coverage Checklist
## ms2.fun Protocol - Complete Function Coverage

> **Purpose**: Ensure the frontend exposes all contract functionality organized by user role.
> **For**: Frontend engineers building a statically hosted client-based Ethereum application (direct chain queries, no server, no database).

---

## Table of Contents
1. [Regular Users](#1-regular-users)
2. [ERC404 Project Owners](#2-erc404-project-owners)
3. [ERC1155 Project Owners](#3-erc1155-project-owners)
4. [Vault Owners](#4-vault-owners)
5. [Governance Participants](#5-governance-participants)
6. [Factory Applicants](#6-factory-applicants)
7. [Anyone (Permissionless Operations)](#7-anyone-permissionless-operations)

---

## 1. Regular Users
**Role**: Browse, discover, participate in projects, claim rewards

### 1.1 Discovery & Browsing

#### Master Registry - Project Discovery
- [ ] **Query total factories**: `MasterRegistryV1.getTotalFactories()`
- [ ] **Get factory by ID**: `MasterRegistryV1.getFactoryInfo(uint256 factoryId)`
- [ ] **Get factory by address**: `MasterRegistryV1.getFactoryInfoByAddress(address)`
- [ ] **Get featured instances (paginated)**: `MasterRegistryV1.getFeaturedInstances(startIndex, endIndex)`

#### Master Registry - Vault Discovery
- [ ] **Query total vaults**: `MasterRegistryV1.getTotalVaults()`
- [ ] **Get vault info**: `MasterRegistryV1.getVaultInfo(address vault)`
- [ ] **Get all vaults (paginated)**: `MasterRegistryV1.getVaults(startIndex, endIndex)`
- [ ] **Get top vaults by TVL**: `MasterRegistryV1.getVaultsByTVL(uint256 limit)`
- [ ] **Get top vaults by popularity**: `MasterRegistryV1.getVaultsByPopularity(uint256 limit)`
- [ ] **Get instances using a vault**: `MasterRegistryV1.getInstancesByVault(address vault)`
- [ ] **Check if vault is registered**: `MasterRegistryV1.isVaultRegistered(address vault)`

#### Global Messaging - Activity Feed
- [ ] **Get total message count**: `GlobalMessageRegistry.getMessageCount()`
- [ ] **Get recent messages (protocol-wide)**: `GlobalMessageRegistry.getRecentMessages(uint256 count)`
- [ ] **Get recent messages (paginated)**: `GlobalMessageRegistry.getRecentMessagesPaginated(offset, limit)`
- [ ] **Get single message**: `GlobalMessageRegistry.getMessage(uint256 messageId)`
- [ ] **Get message count for instance**: `GlobalMessageRegistry.getMessageCountForInstance(address instance)`
- [ ] **Get instance messages**: `GlobalMessageRegistry.getInstanceMessages(address instance, uint256 count)`
- [ ] **Get instance messages (paginated)**: `GlobalMessageRegistry.getInstanceMessagesPaginated(instance, offset, limit)`
- [ ] **Batch query messages**: `GlobalMessageRegistry.getMessagesBatch(uint256[] messageIds)`

### 1.2 ERC404 Token Interaction

#### ERC404 - Bonding Curve Purchase/Sale
- [ ] **Buy tokens**: `ERC404BondingInstance.buyBonding(amount, maxCost, mintNFT, passwordHash, message)`
- [ ] **Sell tokens**: `ERC404BondingInstance.sellBonding(amount, minRefund, passwordHash, message)`
- [ ] **Calculate buy cost**: `ERC404BondingInstance.calculateCost(uint256 amount)`
- [ ] **Calculate sell refund**: `ERC404BondingInstance.calculateRefund(uint256 amount)`
- [ ] **Get pricing info**: `ERC404BondingInstance.getPricingInfo(uint256 amount)`

#### ERC404 - Token Queries
- [ ] **Get token balance**: `ERC404BondingInstance.balanceOf(address user)`
- [ ] **Get project metadata**: `ERC404BondingInstance.getProjectMetadata()`
- [ ] **Get bonding status**: `ERC404BondingInstance.getBondingStatus()`
- [ ] **Get bonding curve params**: `ERC404BondingInstance.getBondingCurveParams()`
- [ ] **Get liquidity info**: `ERC404BondingInstance.getLiquidityInfo()`
- [ ] **Get supply info**: `ERC404BondingInstance.getSupplyInfo()`
- [ ] **Get tier config summary**: `ERC404BondingInstance.getTierConfigSummary()`
- [ ] **Get user tier info**: `ERC404BondingInstance.getUserTierInfo(address user)`
- [ ] **Check tier access**: `ERC404BondingInstance.canAccessTier(address user, bytes32 passwordHash)`
- [ ] **Get tier password hash**: `ERC404BondingInstance.getTierPasswordHash(uint256 tierIndex)`
- [ ] **Get tier volume cap**: `ERC404BondingInstance.getTierVolumeCap(uint256 tierIndex)`
- [ ] **Get tier unlock time**: `ERC404BondingInstance.getTierUnlockTime(uint256 tierIndex)`

#### ERC404 - NFT Management (Balance Mint)
- [ ] **Mint NFTs from balance**: `ERC404BondingInstance.balanceMint(uint256 amount)`
- [ ] **Get skip NFT status**: `ERC404BondingInstance.getSkipNFT(address user)`
- [ ] **Set skip NFT**: `ERC404BondingInstance.setSkipNFT(bool skipNFT)`

#### ERC404 - NFT Reroll
- [ ] **Reroll selected NFTs**: `ERC404BondingInstance.rerollSelectedNFTs(tokenAmount, exemptedNFTIds[])`
- [ ] **Get reroll escrow**: `ERC404BondingInstance.getRerollEscrow(address user)`

#### ERC404 - Staking (if enabled)
- [ ] **Stake tokens**: `ERC404BondingInstance.stake(uint256 amount)`
- [ ] **Unstake tokens**: `ERC404BondingInstance.unstake(uint256 amount)`
- [ ] **Claim staker rewards**: `ERC404BondingInstance.claimStakerRewards()`
- [ ] **Calculate pending rewards**: `ERC404BondingInstance.calculatePendingRewards(address staker)`
- [ ] **Get staking info**: `ERC404BondingInstance.getStakingInfo(address user)`
- [ ] **Get staking stats**: `ERC404BondingInstance.getStakingStats()`

#### ERC404 - ERC20/ERC721 Standard Functions
- [ ] **Transfer tokens**: `ERC404BondingInstance.transfer(address to, uint256 amount)`
- [ ] **Approve spender**: `ERC404BondingInstance.approve(address spender, uint256 amount)`
- [ ] **Transfer from**: `ERC404BondingInstance.transferFrom(from, to, amount)`
- [ ] **Get allowance**: `ERC404BondingInstance.allowance(address owner, address spender)`
- [ ] **Get total supply**: `ERC404BondingInstance.totalSupply()`
- [ ] **Get name**: `ERC404BondingInstance.name()`
- [ ] **Get symbol**: `ERC404BondingInstance.symbol()`

### 1.3 ERC1155 Token Interaction

#### ERC1155 - Minting
- [ ] **Mint tokens**: `ERC1155Instance.mint(uint256 editionId, uint256 amount)`
- [ ] **Mint with message**: `ERC1155Instance.mintWithMessage(editionId, amount, message)`
- [ ] **Calculate mint cost**: `ERC1155Instance.calculateMintCost(uint256 editionId, uint256 amount)`
- [ ] **Get current price**: `ERC1155Instance.getCurrentPrice(uint256 editionId)`

#### ERC1155 - Edition Queries
- [ ] **Get edition metadata**: `ERC1155Instance.getEditionMetadata(uint256 editionId)`
- [ ] **Get all edition IDs**: `ERC1155Instance.getAllEditionIds()`
- [ ] **Get edition count**: `ERC1155Instance.getEditionCount()`
- [ ] **Get editions batch**: `ERC1155Instance.getEditionsBatch(startId, endId)`
- [ ] **Get pricing info**: `ERC1155Instance.getPricingInfo(uint256 editionId)`
- [ ] **Get mint stats**: `ERC1155Instance.getMintStats(uint256 editionId)`
- [ ] **Check edition exists**: `ERC1155Instance.editionExists(uint256 editionId)`
- [ ] **Get piece title**: `ERC1155Instance.getPieceTitle(uint256 editionId)`
- [ ] **Get full edition**: `ERC1155Instance.getEdition(uint256 editionId)`

#### ERC1155 - Instance Queries
- [ ] **Get instance metadata**: `ERC1155Instance.getInstanceMetadata()`
- [ ] **Get project name**: `ERC1155Instance.getProjectName()`
- [ ] **Get total proceeds**: `ERC1155Instance.getTotalProceeds()`

#### ERC1155 - ERC1155 Standard Functions
- [ ] **Get balance**: `ERC1155Instance.balanceOf(address account, uint256 editionId)`
- [ ] **Get batch balances**: `ERC1155Instance.balanceOfBatch(address account, uint256[] ids)`
- [ ] **Transfer tokens**: `ERC1155Instance.safeTransferFrom(from, to, id, amount, data)`
- [ ] **Batch transfer**: `ERC1155Instance.safeBatchTransferFrom(from, to, ids[], amounts[], data)`
- [ ] **Set approval for all**: `ERC1155Instance.setApprovalForAll(operator, approved)`
- [ ] **Check approval**: `ERC1155Instance.isApprovedForAll(account, operator)`

### 1.4 Vault Interaction

#### Vault - Fee Claims
- [ ] **Claim fees**: `UltraAlignmentVault.claimFees()`
- [ ] **Calculate claimable amount**: `UltraAlignmentVault.calculateClaimableAmount(address benefactor)`

#### Vault - Benefactor Queries
- [ ] **Get benefactor contribution**: `UltraAlignmentVault.getBenefactorContribution(address benefactor)`
- [ ] **Get benefactor shares**: `UltraAlignmentVault.getBenefactorShares(address benefactor)`

#### Vault - Vault Info
- [ ] **Get vault type**: `UltraAlignmentVault.vaultType()`
- [ ] **Get description**: `UltraAlignmentVault.description()`
- [ ] **Get accumulated fees**: `UltraAlignmentVault.accumulatedFees()`
- [ ] **Get total shares**: `UltraAlignmentVault.totalShares()`

### 1.5 Featured Position Rental

#### Featured Queue - Rental Queries
- [ ] **Get position rental price**: `MasterRegistryV1.getPositionRentalPrice(uint256 position)`
- [ ] **Calculate rental cost**: `MasterRegistryV1.calculateRentalCost(position, duration)`
- [ ] **Get rental info**: `MasterRegistryV1.getRentalInfo(address instance)`

---

## 2. ERC404 Project Owners
**Role**: Creators/owners of ERC404 bonding instances

### 2.1 Instance Creation

#### Factory - Deploy Instance
- [ ] **Create ERC404 instance**: `ERC404Factory.createInstance(name, symbol, metadataURI, maxSupply, liquidityReservePercent, curveParams, tierConfig, creator, vault, styleUri)`
- [ ] **Get hook for instance**: `ERC404Factory.getHookForInstance(address instance)`

### 2.2 Bonding Configuration (Owner Only)

#### ERC404 Owner - Bonding Lifecycle
- [ ] **Set bonding open time**: `ERC404BondingInstance.setBondingOpenTime(uint256 timestamp)`
- [ ] **Set bonding maturity time**: `ERC404BondingInstance.setBondingMaturityTime(uint256 timestamp)`
- [ ] **Set bonding active state**: `ERC404BondingInstance.setBondingActive(bool active)`
- [ ] **Check permissionless deployment**: `ERC404BondingInstance.canDeployPermissionless()`

### 2.3 Liquidity Deployment

#### ERC404 Owner - Deploy to V4
- [ ] **Deploy liquidity**: `ERC404BondingInstance.deployLiquidity(poolFee, tickSpacing, amountToken, amountETH, sqrtPriceX96)`

### 2.4 Staking Management

#### ERC404 Owner - Staking Control
- [ ] **Enable staking**: `ERC404BondingInstance.enableStaking()`
- [ ] **Withdraw dust**: `ERC404BondingInstance.withdrawDust(uint256 amount)`

### 2.5 Customization

#### ERC404 Owner - Styling
- [ ] **Set style**: `ERC404BondingInstance.setStyle(string uri)`
- [ ] **Get style**: `ERC404BondingInstance.getStyle()`

### 2.6 Advanced Configuration

#### ERC404 Owner - Hook & Vault Setup
- [ ] **Set V4 hook**: `ERC404BondingInstance.setV4Hook(address hook)`
- [ ] **Set vault**: `ERC404BondingInstance.setVault(address payable vault)`

---

## 3. ERC1155 Project Owners
**Role**: Creators/owners of ERC1155 instances (artists, open edition creators)

### 3.1 Instance Creation

#### Factory - Deploy Instance
- [ ] **Create ERC1155 instance**: `ERC1155Factory.createInstance(name, metadataURI, creator, vault, styleUri)`
- [ ] **Get vault for instance**: `ERC1155Factory.getVaultForInstance(address instance)`

### 3.2 Edition Management

#### ERC1155 Owner - Add & Update Editions
- [ ] **Add edition**: `ERC1155Instance.addEdition(pieceTitle, basePrice, supply, metadataURI, pricingModel, priceIncreaseRate)`
- [ ] **Update edition metadata**: `ERC1155Instance.updateEditionMetadata(uint256 editionId, string metadataURI)`

**Note**: `addEdition` can be called via factory:
- [ ] **Factory add edition**: `ERC1155Factory.addEdition(instance, pieceTitle, basePrice, supply, metadataURI, pricingModel, priceIncreaseRate)`

### 3.3 Proceeds Management

#### ERC1155 Owner - Withdraw
- [ ] **Withdraw proceeds (20% tithe)**: `ERC1155Instance.withdraw(uint256 amount)`
- [ ] **Claim vault fees**: `ERC1155Instance.claimVaultFees()`

### 3.4 Customization

#### ERC1155 Owner - Styling
- [ ] **Set project style**: `ERC1155Instance.setStyle(string uri)`
- [ ] **Set edition style**: `ERC1155Instance.setEditionStyle(uint256 editionId, string uri)`
- [ ] **Get style**: `ERC1155Instance.getStyle(uint256 editionId)`

---

## 4. Vault Owners
**Role**: Vault deployers/operators

### 4.1 Vault Registration

#### Master Registry - Register Vault
- [ ] **Register vault**: `MasterRegistryV1.registerVault(address vault, string name, string metadataURI)`
- [ ] **Get vault registration fee**: `MasterRegistryV1.vaultRegistrationFee()`

### 4.2 Vault Management

#### Vault Owner - Deactivation
- [ ] **Deactivate vault**: `MasterRegistryV1.deactivateVault(address vault)`

### 4.3 Conversion Triggering

#### Anyone Can Trigger (Incentivized)
- [ ] **Convert and add liquidity**: `UltraAlignmentVault.convertAndAddLiquidity(uint256 minOutTarget)`

---

## 5. Governance Participants
**Role**: EXEC token holders voting on factory and vault approvals

### 5.1 Factory Governance

#### Factory Approval - Application Queries
- [ ] **Get application**: `FactoryApprovalGovernance.applications(address factory)` (public mapping)
- [ ] **Get total messages**: `FactoryApprovalGovernance.totalMessages()`
- [ ] **Get governance message**: `FactoryApprovalGovernance.governanceMessages(uint256 messageId)` (public mapping)

#### Factory Approval - Voting
- [ ] **Vote with deposit**: `FactoryApprovalGovernance.voteWithDeposit(factory, approve, amount, message)`
- [ ] **Get deposit info**: `FactoryApprovalGovernance.deposits(factory, voter, roundIndex)` (public mapping)

#### Factory Approval - Challenges
- [ ] **Initiate challenge**: `FactoryApprovalGovernance.initiateChallenge(factory, message)`

#### Factory Approval - Finalization
- [ ] **Finalize round**: `FactoryApprovalGovernance.finalizeRound(factory)`
- [ ] **Register factory**: `FactoryApprovalGovernance.registerFactory(factory)`

#### Factory Approval - Deposit Withdrawal
- [ ] **Withdraw deposits**: `FactoryApprovalGovernance.withdrawDeposits(factory)`

### 5.2 Vault Governance

#### Vault Approval - Application Queries
- [ ] **Get application**: `VaultApprovalGovernance.applications(address vault)` (public mapping)
- [ ] **Get total messages**: `VaultApprovalGovernance.totalMessages()`
- [ ] **Get governance message**: `VaultApprovalGovernance.governanceMessages(uint256 messageId)` (public mapping)

#### Vault Approval - Voting
- [ ] **Vote with deposit**: `VaultApprovalGovernance.voteWithDeposit(vault, approve, amount, message)`
- [ ] **Get deposit info**: `VaultApprovalGovernance.deposits(vault, voter, roundIndex)` (public mapping)

#### Vault Approval - Challenges
- [ ] **Initiate challenge**: `VaultApprovalGovernance.initiateChallenge(vault, message)`

#### Vault Approval - Finalization
- [ ] **Finalize round**: `VaultApprovalGovernance.finalizeRound(vault)`
- [ ] **Register vault**: `VaultApprovalGovernance.registerVault(vault)`

#### Vault Approval - Deposit Withdrawal
- [ ] **Withdraw deposits**: `VaultApprovalGovernance.withdrawDeposits(vault)`

---

## 6. Factory Applicants
**Role**: Developers submitting new factory contracts for governance approval

### 6.1 Factory Application Submission

#### Factory Governance - Submit
- [ ] **Submit application**: `FactoryApprovalGovernance.submitApplication(factoryAddress, contractType, title, displayTitle, metadataURI, features[], message)`
- [ ] **Get application fee**: `FactoryApprovalGovernance.applicationFee()`
- [ ] **Get constants**:
  - `FactoryApprovalGovernance.APPLICATION_FEE()`
  - `FactoryApprovalGovernance.MIN_QUORUM()`
  - `FactoryApprovalGovernance.MIN_DEPOSIT()`
  - `FactoryApprovalGovernance.INITIAL_VOTING_PERIOD()`
  - `FactoryApprovalGovernance.CHALLENGE_WINDOW()`
  - `FactoryApprovalGovernance.CHALLENGE_VOTING_PERIOD()`
  - `FactoryApprovalGovernance.LAME_DUCK_PERIOD()`

### 6.2 Vault Application Submission

#### Vault Governance - Submit
- [ ] **Submit application**: `VaultApprovalGovernance.submitApplication(vaultAddress, vaultType, title, displayTitle, metadataURI, features[], message)`
- [ ] **Get application fee**: `VaultApprovalGovernance.applicationFee()`
- [ ] **Get constants**:
  - `VaultApprovalGovernance.APPLICATION_FEE()`
  - `VaultApprovalGovernance.MIN_QUORUM()`
  - `VaultApprovalGovernance.MIN_DEPOSIT()`
  - `VaultApprovalGovernance.INITIAL_VOTING_PERIOD()`
  - `VaultApprovalGovernance.CHALLENGE_WINDOW()`
  - `VaultApprovalGovernance.CHALLENGE_VOTING_PERIOD()`
  - `VaultApprovalGovernance.LAME_DUCK_PERIOD()`

---

## 7. Anyone (Permissionless Operations)
**Role**: Public incentivized functions and maintenance operations

### 7.1 Featured Position Management

#### Master Registry - Rental Operations
- [ ] **Rent featured position**: `MasterRegistryV1.rentFeaturedPosition(instance, desiredPosition, duration)`
- [ ] **Renew position**: `MasterRegistryV1.renewPosition(instance, additionalDuration)`
- [ ] **Bump position**: `MasterRegistryV1.bumpPosition(instance, targetPosition, additionalDuration)`
- [ ] **Deposit for auto-renewal**: `MasterRegistryV1.depositForAutoRenewal(address instance)`
- [ ] **Withdraw renewal deposit**: `MasterRegistryV1.withdrawRenewalDeposit(address instance)`

### 7.2 Cleanup & Maintenance

#### Master Registry - Expired Rentals
- [ ] **Cleanup expired rentals**: `MasterRegistryV1.cleanupExpiredRentals(uint256 maxCleanup)`

### 7.3 Vault Conversion (Incentivized)

#### Vault - Public Conversion
- [ ] **Convert and add liquidity**: `UltraAlignmentVault.convertAndAddLiquidity(uint256 minOutTarget)` (incentivized with reward)

### 7.4 Global Message Registry

#### Global Messages - Read Access
- [ ] **Check authorization**: `GlobalMessageRegistry.isAuthorized(address instance)`

---

## Implementation Notes

### Critical Integrations

1. **Global Messaging System**
   - All user actions (buy, sell, mint, messages) should display in activity feed
   - Use pagination for large message lists
   - Filter by instance for project-specific feeds

2. **Vault Discovery**
   - Leaderboards for TVL and popularity
   - Reverse lookup: which projects use which vaults
   - TVL rankings use `IAlignmentVault.accumulatedFees()`

3. **Featured Queue**
   - Dynamic pricing based on position demand
   - Auto-renewal deposit system
   - Permissionless cleanup incentivized with rewards

4. **Governance Flows**
   - Three-phase voting (Initial → Challenge Window → Challenge Vote → Lame Duck)
   - Escalating challenge deposits
   - Vote retrieval after resolution

5. **ERC404 Bonding Curve**
   - Password-protected tiers (volume cap or time-based)
   - Permissionless liquidity deployment when full or matured
   - Optional holder staking system

6. **ERC1155 Open Editions**
   - Dynamic pricing per edition
   - Withdraw tithe (20%) to vault
   - Claim vault fees as benefactor

### Gas Optimization Tips

- Use batch queries where available (`getVaultsByTVL`, `getEditionsBatch`, etc.)
- Cache results client-side to reduce RPC calls
- Use pagination for large data sets

### Error Handling

- All view functions will revert if queried with invalid data
- Check existence before calling getters (`editionExists`, `isVaultRegistered`, etc.)
- Handle graceful degradation for non-compliant vaults in TVL rankings

---

## Checklist Summary

**Total Functions Mapped**: 200+

### Breakdown by Category:
- **Discovery & Browsing**: 22 functions
- **ERC404 Interaction**: 45 functions
- **ERC1155 Interaction**: 28 functions
- **Vault Interaction**: 9 functions
- **Governance**: 24 functions (factory + vault)
- **Factory Applications**: 16 functions
- **Project Owner Admin**: 25 functions
- **Permissionless Operations**: 8 functions

---

## Next Steps

1. ✅ Review this checklist with your team
2. ✅ Map each function to specific UI components
3. ✅ Identify priority features for MVP
4. ✅ Build query layers (wagmi/viem hooks)
5. ✅ Test against deployed contracts on testnet

**Questions or missing features?** Cross-reference this checklist with the contract source code and documentation.
