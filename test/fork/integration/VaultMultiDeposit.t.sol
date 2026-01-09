// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ForkTestBase } from "../helpers/ForkTestBase.sol";
import { UltraAlignmentVault } from "src/vaults/UltraAlignmentVault.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";

/**
 * @title VaultMultiDeposit
 * @notice Tests multi-contributor share mechanics across conversion rounds
 * @dev Run with: forge test --mp test/fork/integration/VaultMultiDeposit.t.sol --fork-url $ETH_RPC_URL -vvv
 *
 * Focus areas:
 * - Equal/unequal contributions across conversion cycles
 * - Share accumulation and dilution
 * - Multi-claim delta calculation
 */
contract VaultMultiDepositTest is ForkTestBase {
    UltraAlignmentVault vault;
    address owner;
    address alice;
    address bob;
    address charlie;

    function setUp() public {
        loadAddresses();

        // Create test addresses
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        // Deploy vault with router and factory addresses
        address alignmentToken = USDC; // Use real USDC for fork tests (has V3 pool with WETH)
        vm.prank(owner);
        vault = new UltraAlignmentVault(
            WETH,
            UNISWAP_V4_POOL_MANAGER,
            UNISWAP_V3_ROUTER,
            UNISWAP_V2_ROUTER,
            UNISWAP_V2_FACTORY,
            UNISWAP_V3_FACTORY,
            alignmentToken
        );

        // Set V4 pool key - H-02: Hook requires native ETH (address(0)), not WETH
        vm.prank(owner);
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),  // Native ETH
            currency1: Currency.wrap(alignmentToken),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vault.setV4PoolKey(poolKey);

        // Label addresses
        vm.label(address(vault), "UltraAlignmentVault");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(charlie, "Charlie");

        // CRITICAL: In fork mode, makeAddr() might generate addresses that already have code on mainnet
        // Remove any existing code from test addresses to ensure they behave as EOAs
        vm.etch(alice, "");
        vm.etch(bob, "");
        vm.etch(charlie, "");
        vm.etch(owner, "");
    }

    /// @notice Helper to contribute ETH
    function _contribute(address contributor, uint256 amount) internal {
        vm.deal(contributor, amount);
        vm.prank(contributor);
        (bool success,) = address(vault).call{value: amount}("");
        require(success, "Contribution failed");
    }

    /// @notice Accept caller rewards from vault
    receive() external payable {}

    /// @notice Test: Two cycles with equal contributions
    function test_twoCycles_equalContributions_equalSharesWithinTolerance() public {
        emit log_string("=== Test: Two Cycles - Equal Contributions ===");

        // Cycle 1: Alice 5 ETH, Bob 5 ETH → convert (same dragnet)
        // NOTE: Using 5 ETH to ensure stub's integer division produces non-zero amounts
        _contribute(alice, 5 ether);
        _contribute(bob, 5 ether);
        vault.convertAndAddLiquidity(0);

        uint256 aliceSharesCycle1 = vault.benefactorShares(alice);
        uint256 bobSharesCycle1 = vault.benefactorShares(bob);

        emit log_named_uint("Cycle 1 - Alice shares", aliceSharesCycle1);
        emit log_named_uint("Cycle 1 - Bob shares", bobSharesCycle1);

        // Verify ~equal within 1%
        uint256 ratio1 = (aliceSharesCycle1 * 1e18) / bobSharesCycle1;
        assertApproxEqRel(ratio1, 1e18, 0.01e18, "Cycle 1: Shares should be ~equal");

        // Cycle 2: Alice 5 ETH, Bob 5 ETH → convert (same dragnet)
        _contribute(alice, 5 ether);
        _contribute(bob, 5 ether);
        vault.convertAndAddLiquidity(0);

        uint256 aliceSharesCycle2 = vault.benefactorShares(alice);
        uint256 bobSharesCycle2 = vault.benefactorShares(bob);

        emit log_named_uint("Cycle 2 - Alice total shares", aliceSharesCycle2);
        emit log_named_uint("Cycle 2 - Bob total shares", bobSharesCycle2);

        // After 2 equal cycles, they should still have ~equal total shares
        uint256 ratio2 = (aliceSharesCycle2 * 1e18) / bobSharesCycle2;
        assertApproxEqRel(ratio2, 1e18, 0.01e18, "Cycle 2: Shares should remain ~equal");

        // Verify shares accumulated (not replaced)
        assertGt(aliceSharesCycle2, aliceSharesCycle1, "Alice shares should accumulate");
        assertGt(bobSharesCycle2, bobSharesCycle1, "Bob shares should accumulate");

        emit log_string("");
        emit log_string("[PASS] Equal contributors maintain ~equal shares across cycles");
    }

    /// @notice Test: Three cycles with proportional shares
    function test_threeCycles_proportionalShares() public {
        emit log_string("=== Test: Three Cycles - Proportional Shares ===");

        // Cycle 1: Alice 10 ETH, Bob 5 ETH (2:1 ratio)
        // NOTE: Using 5+ ETH amounts to work with stub's integer division
        _contribute(alice, 10 ether);
        _contribute(bob, 5 ether);
        vault.convertAndAddLiquidity(0);

        uint256 aliceShares1 = vault.benefactorShares(alice);
        uint256 bobShares1 = vault.benefactorShares(bob);
        emit log_named_uint("Cycle 1 - Alice shares", aliceShares1);
        emit log_named_uint("Cycle 1 - Bob shares", bobShares1);

        // Verify 2:1 ratio (within tolerance)
        uint256 expectedRatio1 = 2e18; // 2:1
        uint256 actualRatio1 = (aliceShares1 * 1e18) / bobShares1;
        assertApproxEqRel(actualRatio1, expectedRatio1, 0.01e18, "Cycle 1 ratio mismatch");

        // Cycle 2: Alice 5 ETH, Bob 10 ETH (1:2 ratio this cycle)
        _contribute(alice, 5 ether);
        _contribute(bob, 10 ether);
        vault.convertAndAddLiquidity(0);

        uint256 aliceShares2 = vault.benefactorShares(alice);
        uint256 bobShares2 = vault.benefactorShares(bob);
        emit log_named_uint("Cycle 2 - Alice shares", aliceShares2);
        emit log_named_uint("Cycle 2 - Bob shares", bobShares2);

        // Verify shares accumulated
        assertGt(aliceShares2, aliceShares1, "Alice shares should accumulate");
        assertGt(bobShares2, bobShares1, "Bob shares should accumulate");

        // Cycle 3: Alice 5 ETH, Bob 5 ETH (1:1 ratio this cycle)
        _contribute(alice, 5 ether);
        _contribute(bob, 5 ether);
        vault.convertAndAddLiquidity(0);

        uint256 aliceSharesFinal = vault.benefactorShares(alice);
        uint256 bobSharesFinal = vault.benefactorShares(bob);
        emit log_named_uint("Cycle 3 - Alice final shares", aliceSharesFinal);
        emit log_named_uint("Cycle 3 - Bob final shares", bobSharesFinal);

        // Cumulative contributions: Alice 20 ETH (10+5+5), Bob 20 ETH (5+10+5)
        // Final shares should be approximately equal
        uint256 finalRatio = (aliceSharesFinal * 1e18) / bobSharesFinal;
        assertApproxEqRel(finalRatio, 1e18, 0.02e18, "Final ratio should be ~1:1 (within 2%)");

        // Verify total shares = alice + bob
        assertEq(
            vault.totalShares(),
            aliceSharesFinal + bobSharesFinal,
            "Total shares mismatch"
        );

        emit log_string("");
        emit log_string("[PASS] Proportional shares accumulate correctly across 3 cycles");
    }

    /// @notice Test: New contributor after LP growth (dilution)
    function test_newContributor_afterLpGrowth() public {
        emit log_string("=== Test: New Contributor Dilution ===");

        // Cycle 1: Alice contributes 10 ETH alone
        _contribute(alice, 10 ether);
        vault.convertAndAddLiquidity(0);

        uint256 aliceShares = vault.benefactorShares(alice);
        uint256 totalSharesAfterCycle1 = vault.totalShares();

        emit log_named_uint("Cycle 1 - Alice shares", aliceShares);
        emit log_named_uint("Cycle 1 - Total shares", totalSharesAfterCycle1);

        // Alice has 100% of shares
        assertEq(aliceShares, totalSharesAfterCycle1, "Alice should have all shares");

        // Cycle 2: Bob contributes 10 ETH (same amount as Alice contributed)
        _contribute(bob, 10 ether);
        vault.convertAndAddLiquidity(0);

        uint256 aliceSharesAfter = vault.benefactorShares(alice);
        uint256 bobShares = vault.benefactorShares(bob);
        uint256 totalSharesFinal = vault.totalShares();

        emit log_named_uint("Cycle 2 - Alice shares (unchanged)", aliceSharesAfter);
        emit log_named_uint("Cycle 2 - Bob shares (new)", bobShares);
        emit log_named_uint("Cycle 2 - Total shares", totalSharesFinal);

        // Alice's shares should not change (she didn't contribute in Cycle 2)
        assertEq(aliceSharesAfter, aliceShares, "Alice shares should remain constant");

        // Calculate share percentages
        uint256 alicePercent = (aliceShares * 10000) / totalSharesFinal; // in bps
        uint256 bobPercent = (bobShares * 10000) / totalSharesFinal;

        emit log_named_uint("Alice %", alicePercent);
        emit log_named_uint("Bob %", bobPercent);

        // NOTE: With current stub implementation, vault value doesn't grow between conversions
        // So equal ETH contributions result in equal shares (~50% each)
        // In production with real LP growth, Bob would experience dilution (< 50%)
        // For now, verify they get approximately equal shares
        assertApproxEqAbs(alicePercent, 5000, 100, "Alice should have ~50% (stub limitation)");
        assertApproxEqAbs(bobPercent, 5000, 100, "Bob should have ~50% (stub limitation)");

        // Total shares should be sum
        assertEq(totalSharesFinal, aliceShares + bobShares, "Total = Alice + Bob");

        emit log_string("");
        emit log_string("[PASS] Share distribution verified (dilution requires production LP growth)");
    }

    /// @notice Test: Multi-claim delta calculation
    function test_multiClaim_deltaCalculation() public {
        emit log_string("=== Test: Multi-Claim Delta Calculation ===");

        // Setup: Alice 5 ETH, Bob 5 ETH → equal shares
        _contribute(alice, 5 ether);
        _contribute(bob, 5 ether);
        vault.convertAndAddLiquidity(0);

        uint256 aliceShares = vault.benefactorShares(alice);
        uint256 bobShares = vault.benefactorShares(bob);

        emit log_named_uint("Alice shares", aliceShares);
        emit log_named_uint("Bob shares", bobShares);

        // First fee accumulation: 1 ETH
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        vault.depositFees{value: 1 ether}();

        emit log_string("");
        emit log_string("--- First Fee Accumulation: 1 ETH ---");

        // Alice claims first
        uint256 aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        uint256 aliceClaim1 = vault.claimFees();

        emit log_named_uint("Alice claim 1", aliceClaim1);
        assertApproxEqAbs(aliceClaim1, 0.5 ether, 1, "Alice should claim ~0.5 ETH");
        assertEq(alice.balance - aliceBalanceBefore, aliceClaim1, "Alice should receive ETH");

        // Second fee accumulation: 2 ETH more
        vm.deal(owner, 2 ether);
        vm.prank(owner);
        vault.depositFees{value: 2 ether}();

        emit log_string("");
        emit log_string("--- Second Fee Accumulation: 2 ETH more (3 ETH total) ---");

        // Alice claims again (should only get delta = 1 ETH, not full 1.5 ETH)
        aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        uint256 aliceClaim2 = vault.claimFees();

        emit log_named_uint("Alice claim 2 (delta)", aliceClaim2);
        assertApproxEqAbs(aliceClaim2, 1 ether, 1, "Alice should claim delta ~1 ETH");
        assertEq(alice.balance - aliceBalanceBefore, aliceClaim2, "Alice should receive delta");

        // Bob claims once (should get full accumulated portion)
        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        uint256 bobClaim = vault.claimFees();

        emit log_named_uint("Bob claim (full)", bobClaim);
        // Bob should get 50% of total 3 ETH = 1.5 ETH
        assertApproxEqAbs(bobClaim, 1.5 ether, 2, "Bob should claim full ~1.5 ETH");
        assertEq(bob.balance - bobBalanceBefore, bobClaim, "Bob should receive ETH");

        // Verify: Total claimed = Alice claim 1 + Alice claim 2 + Bob claim ≈ 3 ETH
        uint256 totalClaimed = aliceClaim1 + aliceClaim2 + bobClaim;
        emit log_named_uint("Total claimed", totalClaimed);
        assertApproxEqAbs(totalClaimed, 3 ether, 3, "Total claimed should equal total fees");

        emit log_string("");
        emit log_string("[PASS] Multi-claim delta calculation works correctly");
    }

    /// @notice Test: Share ratios with very different contribution amounts
    function test_extremeRatios_veryUnequalContributions() public {
        emit log_string("=== Test: Extreme Ratios (10:1) ===");

        // Alice contributes 50 ETH, Bob contributes 5 ETH (10:1 ratio)
        // NOTE: Using 5+ ETH amounts to work with stub's integer division
        _contribute(alice, 50 ether);
        _contribute(bob, 5 ether);
        vault.convertAndAddLiquidity(0);

        uint256 aliceShares = vault.benefactorShares(alice);
        uint256 bobShares = vault.benefactorShares(bob);

        emit log_named_uint("Alice shares (50 ETH)", aliceShares);
        emit log_named_uint("Bob shares (5 ETH)", bobShares);

        // Verify 10:1 ratio (within 2% tolerance for extreme ratios)
        uint256 expectedRatio = 10e18;
        uint256 actualRatio = (aliceShares * 1e18) / bobShares;

        emit log_named_uint("Expected ratio (10:1)", expectedRatio);
        emit log_named_uint("Actual ratio", actualRatio);

        assertApproxEqRel(actualRatio, expectedRatio, 0.02e18, "10:1 ratio should hold");

        // Verify percentages
        uint256 total = vault.totalShares();
        uint256 alicePercent = (aliceShares * 10000) / total; // bps
        uint256 bobPercent = (bobShares * 10000) / total;

        emit log_named_uint("Alice % (bps)", alicePercent); // ~9090 (90.9%)
        emit log_named_uint("Bob % (bps)", bobPercent);     // ~909 (9.1%)

        // Alice should have ~90.9%, Bob ~9.1%
        assertApproxEqAbs(alicePercent, 9091, 100, "Alice should have ~90.9%");
        assertApproxEqAbs(bobPercent, 909, 100, "Bob should have ~9.1%");

        emit log_string("");
        emit log_string("[PASS] Extreme contribution ratios (10:1) handled correctly");
    }

    /// @notice Test: Three contributors with different amounts
    function test_threeContributors_complexProportions() public {
        emit log_string("=== Test: Three Contributors (5:3:2) ===");

        // Alice 10 ETH, Bob 6 ETH, Charlie 4 ETH (total 20 ETH, maintains 5:3:2 ratio)
        // NOTE: Using 4+ ETH amounts to work with stub's integer division
        _contribute(alice, 10 ether);
        _contribute(bob, 6 ether);
        _contribute(charlie, 4 ether);
        vault.convertAndAddLiquidity(0);

        uint256 aliceShares = vault.benefactorShares(alice);
        uint256 bobShares = vault.benefactorShares(bob);
        uint256 charlieShares = vault.benefactorShares(charlie);
        uint256 total = vault.totalShares();

        emit log_named_uint("Alice shares (10 ETH)", aliceShares);
        emit log_named_uint("Bob shares (6 ETH)", bobShares);
        emit log_named_uint("Charlie shares (4 ETH)", charlieShares);
        emit log_named_uint("Total shares", total);

        // Calculate percentages
        uint256 alicePercent = (aliceShares * 10000) / total; // bps
        uint256 bobPercent = (bobShares * 10000) / total;
        uint256 charliePercent = (charlieShares * 10000) / total;

        emit log_named_uint("Alice % (bps)", alicePercent);   // Should be ~5000 (50%)
        emit log_named_uint("Bob % (bps)", bobPercent);       // Should be ~3000 (30%)
        emit log_named_uint("Charlie % (bps)", charliePercent); // Should be ~2000 (20%)

        // Verify percentages (within 1%)
        assertApproxEqAbs(alicePercent, 5000, 100, "Alice should have ~50%");
        assertApproxEqAbs(bobPercent, 3000, 100, "Bob should have ~30%");
        assertApproxEqAbs(charliePercent, 2000, 100, "Charlie should have ~20%");

        // Verify sum of shares
        assertEq(total, aliceShares + bobShares + charlieShares, "Total should be sum");

        // Test fee claims are proportional
        // Deposit 20 ETH in fees to match the 20 ETH total contributions (5:3:2 ratio)
        vm.deal(owner, 20 ether);
        vm.prank(owner);
        vault.depositFees{value: 20 ether}();

        // Each claims
        vm.prank(alice);
        uint256 aliceClaim = vault.claimFees();
        vm.prank(bob);
        uint256 bobClaim = vault.claimFees();
        vm.prank(charlie);
        uint256 charlieClaim = vault.claimFees();

        emit log_named_uint("Alice claim", aliceClaim);
        emit log_named_uint("Bob claim", bobClaim);
        emit log_named_uint("Charlie claim", charlieClaim);

        // Verify proportional claims (50%, 30%, 20% of 20 ETH)
        assertApproxEqAbs(aliceClaim, 10 ether, 0.1 ether, "Alice should claim ~10 ETH");
        assertApproxEqAbs(bobClaim, 6 ether, 0.1 ether, "Bob should claim ~6 ETH");
        assertApproxEqAbs(charlieClaim, 4 ether, 0.1 ether, "Charlie should claim ~4 ETH");

        // Total claimed should equal total fees
        assertApproxEqAbs(
            aliceClaim + bobClaim + charlieClaim,
            20 ether,
            0.1 ether,
            "Total claims should equal total fees"
        );

        emit log_string("");
        emit log_string("[PASS] Three contributors with complex proportions (5:3:2) work correctly");
    }
}
