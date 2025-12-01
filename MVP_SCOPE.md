# MS2FUN MVP Scope - Final Definition

**Status**: Ready for Implementation
**Release**: Single comprehensive MVP (no phase split)
**Timeline**: ~1 week
**Target**: Production-ready for testnet deployment

---

## What Ships in MVP

### Tier 1: Complete Architecture ✅

1. **Vault-Hook Redesign** (100% done)
   - Vaults own their canonical hooks (1:1 immutable)
   - Multiple projects share vault's hook
   - Hook taxes benefactors, vault tracks contributions
   - MasterRegistry cleaned of hook tracking

2. **Hook Integration** (95% done, needs verification)
   - UltraAlignmentV4Hook deployed per vault
   - Taxes swaps, passes benefactor info
   - Receives taxes, tracks origin

3. **Benefactor Tracking** (90% done, needs completion)
   - Vault tracks all benefactors (projects, EOAs, hooks)
   - ETH receive() function works
   - Benefactor contribution mapping in place

### Tier 2: Registry & Discovery

1. **Master Registry** (70% done)
   - Factory registration & voting ✅ (FactoryApprovalGovernance)
   - Instance tracking & listing ✅ (getInstancesByTierAndDate)
   - **Missing**: Vault registration functions
   - **Missing**: Featured tier purchasing logic

2. **Featured Tier System** (50% done)
   - Tier state tracking exists
   - Dynamic pricing algorithm ready
   - Tier ordering in listing ✅ (getInstancesByTierAndDate)
   - **Missing**: purchaseFeaturedPromotion() implementation

3. **EXEC Voting** (80% done)
   - Governance contract implemented
   - Vote casting with power calculation ✅
   - Quorum enforcement ✅
   - Application finalization ✅
   - **Missing**: Comprehensive tests

### Tier 3: Fee Distribution

1. **Benefactor Fee Collection** (30% done)
   - Vault collects fees ✅
   - SimpleBeneficiary module placeholder exists
   - **Missing**: VaultBenefactorDistribution contract
   - **Missing**: Proportional distribution logic
   - **Missing**: Claim mechanism

### Tier 4: Advanced Features (Optional)

1. **LP Conversion** (20% done, can defer)
   - ETH accumulation works
   - Thresholds set
   - V3/V4 structures defined
   - **Missing**: Actual swap & liquidity logic
   - **Assessment**: Can defer post-launch

---

## What We Don't Ship (Post-MVP)

- Multi-token voting
- Vote delegation
- Advanced pricing algorithms
- LP conversion automation (manual trigger only, if included)
- V2 pool support
- ERC404 reroll feature
- Fork testing framework
- Cross-chain operations

---

## Implementation Breakdown by Component

### Component A: Benefactor Distribution (NEW CONTRACT)
**Scope**: Create `VaultBenefactorDistribution.sol`
**Size**: ~200 LOC
**Time**: 2-3 days
**Deliverables**:
- Proportional fee distribution logic
- Benefactor claim mechanism
- Events for analytics
- 20+ unit tests

**Design**:
```solidity
contract VaultBenefactorDistribution {
    // Track pending rewards per benefactor
    mapping(address => uint256) public pendingRewards;

    // Called by vault when fees accumulate
    function onFeeAccumulated(uint256 amount, address[] calldata benefactors) external

    // Benefactors claim their share
    function claimRewards() external returns (uint256)

    // Query pending rewards
    function getPendingRewards(address benefactor) external view returns (uint256)
}
```

### Component B: Featured Tier System (UPDATE MASTERREGISTRY)
**Scope**: Add to `MasterRegistryV1.sol`
**Size**: ~150 LOC
**Time**: 1 day
**Deliverables**:
- purchaseFeaturedPromotion() function
- Dynamic pricing update
- Tier expiration check
- 15+ test cases

**Design**:
```solidity
function purchaseFeaturedPromotion(address instance, uint256 tier) external payable {
    require(tier >= 1 && tier <= 3, "Invalid tier");
    require(msg.value >= getCurrentPrice(tier), "Insufficient payment");

    instanceFeaturedTier[instance] = tier;
    // Update pricing
    // Record purchase
    // Emit event
}
```

### Component C: Vault Registration (UPDATE MASTERREGISTRY)
**Scope**: Add to `MasterRegistryV1.sol`
**Size**: ~100 LOC
**Time**: 1 day
**Deliverables**:
- registerVault() function
- getVaultInfo() getter
- deactivateVault() function
- Vault list queries
- 10+ test cases

**Design**:
```solidity
function registerVault(address vault, string memory name, string memory metadataURI) external payable {
    require(msg.value >= vaultRegistrationFee, "Fee required");
    vaultInfo[vault] = VaultInfo({...});
    registeredVaults[vault] = true;
    vaultList.push(vault);
}
```

### Component D: Testing & Verification
**Scope**: All feature tests + integration tests
**Time**: 2 days
**Deliverables**:
- 50+ new unit tests
- 20+ integration tests
- End-to-end scenario tests
- Edge case coverage

**Test Scenarios**:
1. Factory apply → vote → register
2. Create vault → deploy hook → register
3. Contribute ETH → accumulate fees → distribute
4. Purchase tier → verify ordering
5. Multiple benefactors → fee splitting
6. Hook tax collection → vault tracking

---

## Build to Ship Checklist

### Week 1: Implementation
- [ ] Fix test compilation error (1h)
- [ ] Implement featured tier purchasing (1d)
- [ ] Create benefactor distribution contract (2d)
- [ ] Add vault registration functions (1d)
- [ ] Verify voting system works (1d)
- [ ] End-to-end integration tests (1-2d)
- [ ] Bug fixes & refinement (0.5d)

### Week 2: Validation
- [ ] Code review by team
- [ ] Security audit (external firm)
- [ ] Gas optimization review
- [ ] Documentation finalization

### Week 3: Deployment
- [ ] Deployment scripts ready
- [ ] Testnet deployment (Sepolia)
- [ ] Integration testing on testnet
- [ ] Mainnet preparation

---

## Success Metrics

**Code Quality**:
- [ ] 0 compilation errors
- [ ] 100% of unit tests pass
- [ ] 100% of integration tests pass
- [ ] No security issues (audit)
- [ ] Gas efficient (benchmarks available)

**Feature Completeness**:
- [ ] All 6 features implemented or deferred
- [ ] Vault-hook integration working
- [ ] Featured tiers working
- [ ] Voting working
- [ ] Fee distribution working
- [ ] Discovery & listing working

**Documentation**:
- [ ] API documentation
- [ ] Deployment guide
- [ ] User guide
- [ ] Architecture overview

---

## Risk Assessment

### Technical Risks (Low)
- **Hook integration**: Already working architecture, just needs verification
- **Voting**: Already implemented, just needs tests
- **Featured tiers**: Simple logic, low complexity
- **Fee distribution**: Standard pattern, well-understood

### Timeline Risks (Medium)
- Depends on team availability
- Testing can take longer if issues found
- Security audit could find issues requiring rework

### Mitigation
- Daily standups on progress
- Parallel work on independent components
- Early security review (pre-audit)
- Comprehensive testing during development

---

## Comparison: Previous vs Current Plan

| Aspect | Previous | Current |
|--------|----------|---------|
| Phase 1/2 split | Yes | No - single MVP |
| Benefactor staking | Phase 2 | MVP (simple distribution) |
| Featured tiers | Phase 2 | MVP |
| Vault registry | Phase 2 | MVP |
| Voting | Phase 2 | MVP |
| LP conversion | Phase 2 | Optional (can defer) |
| Hook ownership | Centralized | Vault-owned ✅ |

**Key Change**: Everything ships together with reasonable MVP implementations. Future upgrades are additive, not foundational.

---

## Deployment Architecture

```
Single Deployment Package:
├── MasterRegistryV1 (with all features)
│   ├── Factory approval & voting
│   ├── Instance discovery & tiers
│   └── Vault registry
├── FactoryApprovalGovernance
│   └── EXEC token voting
├── UltraAlignmentVault
│   └── Creates canonical hook
├── UltraAlignmentHookFactory
│   └── Deploys per-vault hooks
├── VaultBenefactorDistribution
│   └── Fee distribution
└── ERC404Factory & ERC1155Factory
    └── Create instances

All initialized & configured in single transaction sequence
Ready to accept first factories immediately
```

---

## Go/No-Go Criteria

**Go Decision Requires**:
- [ ] All code compiles (0 errors)
- [ ] All tests pass (100%)
- [ ] Security audit passed
- [ ] Team code review approved
- [ ] Documentation complete

**If any blocked**: No-go until resolved. No shipping incomplete work.

---

## Post-MVP Roadmap

Once MVP is live and stable:

### Phase 2 (1-2 months):
- Advanced fee distribution (weighted, multipliers)
- LP conversion automation
- Vote delegation
- Multi-token voting

### Phase 3 (3-6 months):
- Cross-chain support
- Advanced analytics
- DAO governance
- Community features

---

## Final Note

This MVP is **NOT a hack**. Every component works correctly, is tested thoroughly, and is production-ready. It's just a focused scope:
- No unnecessary complexity
- No features that aren't used
- Designed for extension without refactoring
- Battle-tested patterns only

Quality over quantity. Ship what we can guarantee works.

---

**Approval Required From**: Project owner
**Timeline**: Ready to start immediately
**Budget**: ~1 week dev time + audit
**Risk Level**: Low
**Confidence**: High
