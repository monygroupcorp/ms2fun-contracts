// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

/**
 * @title ERC404StakingAccountingTest
 * @notice Documentation test demonstrating the share-based accounting fix
 * @dev This test documents the bug scenario and how the fix resolves it
 *
 * CRITICAL BUG FIX: Share-Based Accounting for ERC404BondingInstance Staking
 *
 * ## The Problem (Before Fix):
 *
 * The staking system was treating vault.claimFees() return value (a delta) as if it were
 * the total cumulative fees, leading to incorrect distributions when multiple stakers
 * claimed at different times.
 *
 * ### Broken Flow:
 * 1. StakerA (50% stake) and StakerB (50% stake) both stake
 * 2. Vault accumulates 100 ETH total for instance
 * 3. StakerA calls claimStakerRewards()
 *    - vault.claimFees() returns 100 ETH (delta, first claim)
 *    - Calculates: userShare = (100 ETH × 50%) / 100% = 50 ETH ✓ CORRECT
 *    - StakerA receives 50 ETH
 * 4. Vault accumulates 100 more ETH (200 ETH total now)
 * 5. StakerB calls claimStakerRewards()
 *    - vault.claimFees() returns 100 ETH (delta since instance's last claim)
 *    - Calculates: userShare = (100 ETH × 50%) / 100% = 50 ETH ✗ WRONG!
 *    - Should be: (200 ETH total × 50%) = 100 ETH
 *    - StakerB receives only 50 ETH instead of 100 ETH
 *
 * Result: StakerA got 50 ETH, StakerB got 50 ETH, but 100 ETH remains unclaimed
 *
 * ## The Solution (After Fix):
 *
 * Adopted share-based accounting model (same as vault uses):
 * - totalFeesAccumulatedFromVault: Cumulative total fees received from vault
 * - stakerFeesAlreadyClaimed[user]: Watermark of fees each staker has claimed
 *
 * ### Fixed Flow:
 * 1. StakerA (50%) and StakerB (50%) both stake
 * 2. Vault has 100 ETH total for instance
 * 3. StakerA claims:
 *    - vaultTotalFees = vault.calculateClaimableAmount(instance) = 100 ETH ✓
 *    - vault.claimFees() transfers the delta (100 ETH)
 *    - totalFeesAccumulatedFromVault = 100 ETH
 *    - userTotalEntitlement = (100 ETH × 50%) = 50 ETH
 *    - userAlreadyClaimed = 0
 *    - Pays: 50 - 0 = 50 ETH ✓
 *    - stakerFeesAlreadyClaimed[A] = 50 ETH
 * 4. Vault has 200 ETH total now
 * 5. StakerB claims:
 *    - vaultTotalFees = vault.calculateClaimableAmount(instance) = 200 ETH ✓
 *    - vault.claimFees() transfers the delta (100 ETH)
 *    - totalFeesAccumulatedFromVault = 200 ETH
 *    - userTotalEntitlement = (200 ETH × 50%) = 100 ETH ✓
 *    - userAlreadyClaimed = 0
 *    - Pays: 100 - 0 = 100 ETH ✓
 *    - stakerFeesAlreadyClaimed[B] = 100 ETH
 * 6. StakerA claims again:
 *    - vaultTotalFees = 200 ETH
 *    - userTotalEntitlement = (200 ETH × 50%) = 100 ETH
 *    - userAlreadyClaimed = 50 ETH
 *    - Pays: 100 - 50 = 50 ETH ✓
 *    - stakerFeesAlreadyClaimed[A] = 100 ETH
 *
 * Result: StakerA got 100 ETH total (50 + 50), StakerB got 100 ETH - CORRECT!
 *
 * ## Code Changes:
 *
 * ### Variables Renamed/Added:
 * - `lastVaultFeesClaimed` → `totalFeesAccumulatedFromVault` (cumulative total)
 * - `stakeRewardsTracking[user]` → `stakerFeesAlreadyClaimed[user]` (cumulative claimed)
 *
 * ### Algorithm Updated:
 * ```solidity
 * // OLD (BROKEN):
 * uint256 currentVaultFees = vault.claimFees(); // delta!
 * uint256 userShare = (currentVaultFees * stakedBalance[user]) / totalStaked;
 * rewardAmount = userShare - userAlreadyReceived; // wrong baseline
 *
 * // NEW (FIXED):
 * uint256 vaultTotalFees = vault.calculateClaimableAmount(address(this)); // cumulative!
 * vault.claimFees(); // just transfer the delta
 * totalFeesAccumulatedFromVault = vaultTotalFees; // track cumulative
 * uint256 userTotalEntitlement = (totalFeesAccumulatedFromVault * stakedBalance[user]) / totalStaked;
 * uint256 userAlreadyClaimed = stakerFeesAlreadyClaimed[user];
 * rewardAmount = userTotalEntitlement - userAlreadyClaimed; // correct!
 * stakerFeesAlreadyClaimed[user] = userTotalEntitlement; // update watermark
 * ```
 */
contract ERC404StakingAccountingTest is Test {
    // This is a documentation-only test file
    // Actual runtime tests exist in ERC404BondingInstance.t.sol

    function test_DocumentationOnly() public pure {
        // This test file serves as documentation for the share-based accounting fix
        // See the contract-level comments for the full bug analysis and solution
        assert(true);
    }
}
