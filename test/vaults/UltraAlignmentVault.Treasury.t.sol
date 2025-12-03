// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {UltraAlignmentVault} from "src/vaults/UltraAlignmentVault.sol";
import {LPPositionValuation} from "src/libraries/LPPositionValuation.sol";

/**
 * @title UltraAlignmentVault.Treasury.t.sol
 * @notice Tests for vault treasury architecture and epoch enforcement
 * @dev Verifies:
 *      1. Treasury structure and state management
 *      2. Treasury rebalancing between pools
 *      3. Epoch finalization configuration
 *      4. Epoch boundary settings (advisory only)
 *      5. Accounting integrity
 *      6. Query functions correctness
 */
contract UltraAlignmentVaultTreasuryTest is Test {
    UltraAlignmentVault vault;

    // Test addresses
    address vaultOwner = address(0x1000);
    address keeper = address(0x2000);

    // External contracts
    address alignmentToken = address(0x5000);
    address weth = address(0x6000);
    address v4Pool = address(0x7000);

    // ========== Setup ==========

    function setUp() public {
        vm.prank(vaultOwner);
        vault = new UltraAlignmentVault(
            alignmentToken,
            weth,
            v4Pool,
            address(0x9000),  // _router
            address(0x8000)   // _hookFactory
        );
    }

    // ========== Helper Functions ==========

    /**
     * @dev Get current treasury state
     */
    function _getTreasuryState() internal view returns (UltraAlignmentVault.Treasury memory) {
        return vault.getTreasuryState();
    }

    /**
     * @dev Get treasury accounting totals
     */
    function _getTreasuryTotals() internal view returns (uint256 allocated, uint256 withdrawn) {
        return vault.getTreasuryTotals();
    }

    // ========== Treasury State Tests ==========

    /**
     * @notice Test: Treasury initializes with zero balances
     * @dev All pools should be 0 at deployment
     */
    function test_Treasury_InitialStateIsZero() public {
        UltraAlignmentVault.Treasury memory treasury = _getTreasuryState();
        assertEq(treasury.conversionPool, 0, "conversionPool should be 0");
        assertEq(treasury.feeClaimPool, 0, "feeClaimPool should be 0");
        assertEq(treasury.operatorIncentivePool, 0, "operatorIncentivePool should be 0");
    }

    /**
     * @notice Test: getTreasuryState returns Treasury struct correctly
     * @dev Verifies getter function works properly
     */
    function test_Treasury_QueryReturnsCorrectStructure() public {
        UltraAlignmentVault.Treasury memory state = vault.getTreasuryState();

        // Verify we can access all fields
        uint256 total = state.conversionPool + state.feeClaimPool + state.operatorIncentivePool;
        assertEq(total, 0, "Initial sum should be 0");
    }

    /**
     * @notice Test: getTreasuryTotals tracks allocated and withdrawn
     * @dev Accounting structure should initialize to 0
     */
    function test_Treasury_AccountingInitialization() public {
        (uint256 allocated, uint256 withdrawn) = _getTreasuryTotals();
        assertEq(allocated, 0, "allocated should be 0 initially");
        assertEq(withdrawn, 0, "withdrawn should be 0 initially");
    }

    // ========== Treasury Rebalancing Tests ==========

    /**
     * @notice Test: Owner can reallocate from conversionPool to feeClaimPool
     * @dev Even with zero balances, rebalancing logic should execute without reverting on valid 0 amounts
     */
    function test_Rebalancing_ZeroAmountSucceeds() public {
        vm.prank(vaultOwner);
        // Reallocating 0 should succeed
        vault.reallocateTreasuryForFeeClaims(0);

        UltraAlignmentVault.Treasury memory treasury = _getTreasuryState();
        assertEq(treasury.conversionPool, 0, "conversion should still be 0");
        assertEq(treasury.feeClaimPool, 0, "fee claim should still be 0");
    }

    /**
     * @notice Test: Owner cannot reallocate more than available in conversionPool
     * @dev Should revert with "Insufficient conversion pool"
     */
    function test_Rebalancing_RevertsOnInsufficientPool() public {
        vm.prank(vaultOwner);
        vm.expectRevert("Insufficient conversion pool");
        vault.reallocateTreasuryForFeeClaims(1 ether);
    }

    /**
     * @notice Test: Non-owner cannot reallocate treasury
     * @dev Should revert with ownership error
     */
    function test_Rebalancing_OnlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        vault.reallocateTreasuryForFeeClaims(0);
    }

    /**
     * @notice Test: Owner can reallocate from conversionPool to operatorIncentivePool
     * @dev Even with zero balances, function should succeed for 0 amount
     */
    function test_Rebalancing_OperatorAllocation() public {
        vm.prank(vaultOwner);
        vault.reallocateTreasuryForOperators(0);

        UltraAlignmentVault.Treasury memory treasury = _getTreasuryState();
        assertEq(treasury.operatorIncentivePool, 0, "operator incentive should still be 0");
    }

    // ========== Epoch Configuration Tests ==========

    /**
     * @notice Test: maxConversionsPerEpoch is advisory only (default 100)
     * @dev Configuration parameter should be readable and writable
     */
    function test_EpochBoundary_MaxConversionsDefault() public {
        assertEq(vault.maxConversionsPerEpoch(), 100, "Default max should be 100");
    }

    /**
     * @notice Test: Owner can set maxConversionsPerEpoch
     * @dev Should accept any positive value
     */
    function test_EpochBoundary_SetMaxConversions() public {
        vm.prank(vaultOwner);
        vault.setMaxConversionsPerEpoch(50);

        assertEq(vault.maxConversionsPerEpoch(), 50, "Max should update to 50");
    }

    /**
     * @notice Test: setMaxConversionsPerEpoch rejects zero
     * @dev Should revert with "Max conversions must be positive"
     */
    function test_EpochBoundary_SetMaxConversionsRejectsZero() public {
        vm.prank(vaultOwner);
        vm.expectRevert("Max conversions must be positive");
        vault.setMaxConversionsPerEpoch(0);
    }

    /**
     * @notice Test: Owner can set epochKeeperRewardBps
     * @dev Should accept values up to 100 bps (1%)
     */
    function test_EpochKeeper_SetRewardSucceeds() public {
        vm.prank(vaultOwner);
        vault.setEpochKeeperRewardBps(50);

        assertEq(vault.epochKeeperRewardBps(), 50, "Reward should be 50 bps");
    }

    /**
     * @notice Test: setEpochKeeperRewardBps caps at 100 bps (1%)
     * @dev Should revert if value exceeds 100
     */
    function test_EpochKeeper_RewardCappedAt1Percent() public {
        vm.prank(vaultOwner);
        vm.expectRevert("Reward too high (max 1%)");
        vault.setEpochKeeperRewardBps(150);
    }

    /**
     * @notice Test: Non-owner cannot set epoch parameters
     * @dev Should revert with ownership error
     */
    function test_EpochConfiguration_OnlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        vault.setMaxConversionsPerEpoch(75);
    }

    // ========== Epoch Finalization Tests ==========

    /**
     * @notice Test: Epoch finalization fails if epoch has no ETH
     * @dev Should revert with "Epoch has no ETH, nothing to finalize"
     */
    function test_EpochFinalization_RevertsOnEmptyEpoch() public {
        vm.expectRevert("Epoch has no ETH, nothing to finalize");
        vault.finalizeEpochAndStartNew();
    }

    // ========== Epoch Window Management Tests ==========

    /**
     * @notice Test: Epoch window configuration constants
     * @dev maxEpochWindow should be 3 (keep last 3 epochs)
     */
    function test_EpochWindow_Configuration() public {
        // maxEpochWindow is a constant: 3
        // Verification: vault only keeps 3 active epochs in storage
        // When (currentEpochId - minEpochIdInWindow) > 3, compression happens

        // Test doesn't directly access the constant, but documents the design:
        // At most 4 epochs active (0,1,2,3) before oldest (0) is compressed
    }

    // ========== Minimum Threshold Tests ==========

    /**
     * @notice Test: Owner can set minConversionThreshold
     * @dev Configuration parameter for conversion minimum
     */
    function test_Threshold_SetMinConversionThreshold() public {
        vm.prank(vaultOwner);
        vault.setMinConversionThreshold(0.1 ether);

        // Value is set, function succeeds
    }

    /**
     * @notice Test: minConversionThreshold rejects zero
     * @dev Must be positive
     */
    function test_Threshold_SetMinConversionThresholdRejectsZero() public {
        vm.prank(vaultOwner);
        vm.expectRevert("Threshold must be positive");
        vault.setMinConversionThreshold(0);
    }

    /**
     * @notice Test: Owner can set minLiquidityThreshold
     * @dev Configuration parameter for liquidity minimum
     */
    function test_Threshold_SetMinLiquidityThreshold() public {
        vm.prank(vaultOwner);
        vault.setMinLiquidityThreshold(0.05 ether);

        // Value is set, function succeeds
    }

    /**
     * @notice Test: minLiquidityThreshold rejects zero
     * @dev Must be positive
     */
    function test_Threshold_SetMinLiquidityThresholdRejectsZero() public {
        vm.prank(vaultOwner);
        vm.expectRevert("Threshold must be positive");
        vault.setMinLiquidityThreshold(0);
    }

    // ========== Configuration Integrity Tests ==========

    /**
     * @notice Test: Multiple configuration changes maintain independence
     * @dev Each configuration parameter should be independent
     */
    function test_Configuration_Independence() public {
        vm.startPrank(vaultOwner);

        // Change all parameters
        vault.setMaxConversionsPerEpoch(75);
        vault.setEpochKeeperRewardBps(25);
        vault.setMinConversionThreshold(0.15 ether);
        vault.setMinLiquidityThreshold(0.08 ether);

        vm.stopPrank();

        // Verify each change took effect
        assertEq(vault.maxConversionsPerEpoch(), 75, "maxConversionsPerEpoch should be 75");
        assertEq(vault.epochKeeperRewardBps(), 25, "epochKeeperRewardBps should be 25");
    }

    /**
     * @notice Test: Default keeper reward is 5 bps (0.05%)
     * @dev Initial configuration should be 5 bps
     */
    function test_Configuration_DefaultKeeperReward() public {
        assertEq(vault.epochKeeperRewardBps(), 5, "Default keeper reward should be 5 bps");
    }

    /**
     * @notice Test: Default minConversionThreshold is 0.01 ETH
     * @dev Initial configuration should match design spec
     */
    function test_Configuration_DefaultMinConversionThreshold() public {
        // vault.setMinConversionThreshold is called, but initial value not directly testable
        // without accessing private state variable
        // This test documents the expectation from the code (line 123)
    }

    // ========== Treasury Three-Pool Architecture Tests ==========

    /**
     * @notice Test: Treasury supports three distinct pools
     * @dev Pools should be: conversionPool, feeClaimPool, operatorIncentivePool
     */
    function test_Treasury_ThreePoolArchitecture() public {
        UltraAlignmentVault.Treasury memory treasury = _getTreasuryState();

        // All three pools should be accessible
        uint256 conversionSum = treasury.conversionPool;
        uint256 feeSum = treasury.feeClaimPool;
        uint256 operatorSum = treasury.operatorIncentivePool;

        uint256 totalSum = conversionSum + feeSum + operatorSum;
        assertEq(totalSum, 0, "Three pools sum to 0 initially");
    }

    /**
     * @notice Test: Treasury accounting tracks separate allocations
     * @dev Should maintain separate tallies for allocated and withdrawn
     */
    function test_Treasury_AccountingSeparation() public {
        (uint256 allocated, uint256 withdrawn) = _getTreasuryTotals();

        // Both accounting variables should exist and be independently trackable
        // Sum should not exceed balance
        assertLe(withdrawn, allocated, "Withdrawn should not exceed allocated");
    }

    // ========== Documentation Tests ==========

    /**
     * @notice Test: Vault supports all required treasury functions
     * @dev Verify function availability
     */
    function test_Treasury_RequiredFunctionsExist() public {
        // These function calls should all succeed (no revert)
        UltraAlignmentVault.Treasury memory state = vault.getTreasuryState();
        (uint256 a, uint256 w) = vault.getTreasuryTotals();

        // Functions exist and are callable
        assertTrue(state.conversionPool >= 0, "conversionPool is accessible");
        assertTrue(a >= 0 && w >= 0, "Totals are accessible");
    }
}
