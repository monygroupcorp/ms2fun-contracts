# ERC404 Holder Staking Extension

## Overview

ERC404 instances should be extended to support a staking mechanism that allows ERC404 token holders to stake their tokens in the instance and claim their proportional share of vault fees collected from swap taxes.

This creates a "holder alignment fee benefactor" system where holders are incentivized to participate and align with the project.

## Current State

**ERC404:**
- Instance credited as benefactor when hook tax is sent to vault
- Instance can call `vault.claimBenefactorFees()` to claim accumulated fees
- **Missing:** Mechanism for holders to claim their proportional share of those fees

## Proposed Extension

Extend ERC404Instance to support:

1. **Staking Interface**
   - `stake(uint256 amount)` - Lock ERC404 tokens in the instance
   - `unstake(uint256 amount)` - Unlock staked tokens
   - `claimStakerRewards()` - Claim proportional share of vault fees based on stake

2. **Accounting**
   - Track staked amounts per holder
   - Calculate holder's proportional ownership: `holderStake / totalStaked`
   - Holder gets this proportion of any vault fees claimed by the instance

3. **Fee Distribution**
   - Instance calls `vault.claimBenefactorFees()` to claim accumulated fees
   - Distribute claimed fees proportionally to all stakers
   - Creator can also claim their portion if they stake

## Design Considerations

- **No change needed to vault** - Instance just calls existing `claimBenefactorFees()` mechanism
- **Benefactor attribution** - Instance remains credited in vault (for "bragging rights"), holders get proportional rewards
- **Decoupled from fees** - Staking layer is separate from holder incentives
- **Backwards compatible** - Creator can still call `claimBenefactorFees()` directly if they want to claim entire balance
- **Proportional distribution** - Holder's share = `stakerAmount / totalStaked`

## Implementation Path

1. Add staking state management to ERC404Instance
   - `mapping(address => uint256) public stakedBalance`
   - `uint256 public totalStaked`
   - `mapping(address => uint256) public rewardsClaimed`
2. Implement stake/unstake with proper accounting
3. Implement claim rewards that:
   - Calls `vault.claimBenefactorFees()` on instance behalf
   - Calculates holder's proportional share: `(rewardsClaimed - holderRewardsClaimed) * (stakerAmount / totalStaked)`
   - Distributes to holder and updates tracking
   - Handles edge cases (0 stakers, 0 rewards, rounding)
4. Add tests for staking scenarios

## Related Files

- `src/factories/erc404/ERC404Instance.sol` - Where staking would be implemented
- `src/vaults/UltraAlignmentVault.sol` - Vault's `claimBenefactorFees()` method (lines 439+)
- `src/factories/erc1155/ERC1155Instance.sol` - Reference: `claimVaultFees()` for creator claiming (lines ~366+)

## Status

**Not yet implemented** - Documented as future enhancement for ERC404
