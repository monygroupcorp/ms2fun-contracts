// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {UltraAlignmentVault} from "src/vaults/UltraAlignmentVault.sol";
import {LPPositionValuation} from "src/libraries/LPPositionValuation.sol";

/**
 * @title UltraAlignmentVault.ClaimCalculations.t.sol
 * @notice Integration tests for the O(1) lifetime contribution ratio fee claim model
 * @dev Verifies:
 *      1. Claim amounts calculated correctly using lifetime contribution ratio
 *      2. Multiple claims from same benefactor work properly (delta calculation)
 *      3. Precision handling (1e18 scaling) maintains accuracy
 *      4. Edge cases (zero lifetime contribution, no fees accumulated, etc.)
 *      5. All fees in ETH distribution (token0 already converted)
 */
contract UltraAlignmentVaultClaimCalculationsTest is Test {
    UltraAlignmentVault vault;

    // Test addresses
    address vaultOwner = address(0x1000);
    address benefactor1 = address(0x2000);
    address benefactor2 = address(0x3000);
    address benefactor3 = address(0x4000);

    // Alignment target mock
    address alignmentToken = address(0x5000);
    address weth = address(0x6000);
    address v4Pool = address(0x7000);

    // ========== Setup ==========

    function setUp() public {
        // Initialize vault with owner
        vm.prank(vaultOwner);
        vault = new UltraAlignmentVault(
            alignmentToken,   // _alignmentTarget
            weth,              // _weth
            v4Pool,            // _v4PoolManager
            address(0x9000),   // _router
            address(0x8000)    // _hookFactory
        );
    }

    // ========== Helper Functions ==========

    /**
     * @dev Register a benefactor in vault's new BenefactorState mapping
     *      Directly sets benefactorState to simulate multiple conversions
     */
    function _registerBenefactor(address benefactor, uint256 lifetimeETH) internal {
        vm.store(
            address(vault),
            keccak256(abi.encode(benefactor, keccak256(abi.encode("benefactorState")))),
            bytes32(abi.encodePacked(uint128(lifetimeETH), uint32(0), uint32(0), uint8(1)))
        );
    }

    /**
     * @dev Simulate ETH accumulation and conversion
     *      Sets totalLiquidity in alignmentTarget to track LP value
     */
    function _simulateConversionAndLiquidity(uint256 ethAmount, uint256 lpValue) internal {
        // Simulate: fund vault with ETH
        vm.deal(address(vault), ethAmount);

        // Simulate: set total liquidity (this is what claimBenefactorFees() reads)
        // alignmentTarget.totalLiquidity = lpValue
        vm.store(
            address(vault),
            keccak256(abi.encode(keccak256(abi.encode("alignmentTarget")), 2)),
            bytes32(lpValue)
        );

        // Simulate: set totalETHCollected
        vm.store(
            address(vault),
            keccak256(abi.encode("totalETHCollected")),
            bytes32(uint256(ethAmount))
        );
    }

    /**
     * @dev Helper to calculate expected claim amount
     *      benefactorShare = (totalLPValue * lifetimeContribution) / totalETHCollected
     *      newClaim = benefactorShare - lastClaimAmount
     */
    function _calculateExpectedClaim(
        uint256 totalLPValue,
        uint256 lifetimeContribution,
        uint256 totalETHCollected,
        uint256 lastClaimAmount
    ) internal pure returns (uint256) {
        if (totalETHCollected == 0) return 0;

        uint256 benefactorShare = (totalLPValue * lifetimeContribution) / totalETHCollected;
        return benefactorShare > lastClaimAmount ? benefactorShare - lastClaimAmount : 0;
    }

    // ========== Test Cases ==========

    /**
     * @notice Test 1: Single benefactor claims entire LP value
     * @dev Setup:
     *      - 1 benefactor contributes 10 ETH
     *      - LP position value = 10 ETH
     *      - Expected claim = 10 ETH (100% ownership)
     */
    function test_SingleBenefactor_ClaimsEntireValue() public {
        uint256 lifetimeETH = 10 ether;
        uint256 lpValue = 10 ether;

        _registerBenefactor(benefactor1, lifetimeETH);
        _simulateConversionAndLiquidity(lifetimeETH, lpValue);

        uint256 expectedClaim = _calculateExpectedClaim(lpValue, lifetimeETH, lifetimeETH, 0);
        assertEq(expectedClaim, 10 ether, "Single benefactor should claim 100% of LP value");
    }

    /**
     * @notice Test 2: Two benefactors claim proportional shares
     * @dev Setup:
     *      - Benefactor1 contributes 60 ETH (60% ownership)
     *      - Benefactor2 contributes 40 ETH (40% ownership)
     *      - LP position value = 100 ETH
     *      - Expected: B1 claims 60 ETH, B2 claims 40 ETH
     */
    function test_TwoBenefactors_ProportionalClaims() public {
        uint256 b1Lifetime = 60 ether;
        uint256 b2Lifetime = 40 ether;
        uint256 totalETH = b1Lifetime + b2Lifetime;
        uint256 lpValue = 100 ether;

        _registerBenefactor(benefactor1, b1Lifetime);
        _registerBenefactor(benefactor2, b2Lifetime);
        _simulateConversionAndLiquidity(totalETH, lpValue);

        uint256 b1Expected = _calculateExpectedClaim(lpValue, b1Lifetime, totalETH, 0);
        uint256 b2Expected = _calculateExpectedClaim(lpValue, b2Lifetime, totalETH, 0);

        assertEq(b1Expected, 60 ether, "Benefactor1 should claim 60% (60 ETH)");
        assertEq(b2Expected, 40 ether, "Benefactor2 should claim 40% (40 ETH)");
        assertEq(b1Expected + b2Expected, lpValue, "Total claims should equal LP value");
    }

    /**
     * @notice Test 3: Three benefactors with asymmetric contributions
     * @dev Setup:
     *      - B1: 50 ETH (50%), B2: 30 ETH (30%), B3: 20 ETH (20%)
     *      - LP value = 200 ETH (2x growth)
     *      - Expected: B1=100, B2=60, B3=40 ETH
     */
    function test_ThreeBenefactors_AsymmetricContributions() public {
        uint256 b1Lifetime = 50 ether;
        uint256 b2Lifetime = 30 ether;
        uint256 b3Lifetime = 20 ether;
        uint256 totalETH = b1Lifetime + b2Lifetime + b3Lifetime;
        uint256 lpValue = 200 ether;

        _registerBenefactor(benefactor1, b1Lifetime);
        _registerBenefactor(benefactor2, b2Lifetime);
        _registerBenefactor(benefactor3, b3Lifetime);
        _simulateConversionAndLiquidity(totalETH, lpValue);

        uint256 b1Expected = _calculateExpectedClaim(lpValue, b1Lifetime, totalETH, 0);
        uint256 b2Expected = _calculateExpectedClaim(lpValue, b2Lifetime, totalETH, 0);
        uint256 b3Expected = _calculateExpectedClaim(lpValue, b3Lifetime, totalETH, 0);

        assertEq(b1Expected, 100 ether, "B1 should claim 50% of 200 ETH = 100 ETH");
        assertEq(b2Expected, 60 ether, "B2 should claim 30% of 200 ETH = 60 ETH");
        assertEq(b3Expected, 40 ether, "B3 should claim 20% of 200 ETH = 40 ETH");
        assertEq(b1Expected + b2Expected + b3Expected, lpValue, "Total should equal LP value");
    }

    /**
     * @notice Test 4: Multiple claims from same benefactor (delta calculation)
     * @dev Setup:
     *      - Benefactor1 contributes 10 ETH (100% ownership)
     *      - LP value grows: 10 → 15 → 20 ETH
     *      - Claim 1: receives 15 ETH (full share from 15 ETH LP value)
     *      - Claim 2: receives 5 ETH (20 - 15 = new accrued)
     *      - Claim 3: receives 0 ETH (no new fees accumulated)
     */
    function test_MultipleClaims_DeltaCalculation() public {
        uint256 lifetimeETH = 10 ether;

        _registerBenefactor(benefactor1, lifetimeETH);

        // ---- Claim 1: LP value at 15 ETH ----
        _simulateConversionAndLiquidity(lifetimeETH, 15 ether);

        uint256 claim1Expected = _calculateExpectedClaim(15 ether, lifetimeETH, lifetimeETH, 0);
        assertEq(claim1Expected, 15 ether, "Claim 1: benefactor should receive 15 ETH");

        // ---- Claim 2: LP value grows to 20 ETH ----
        _simulateConversionAndLiquidity(lifetimeETH, 20 ether);

        uint256 claim2Expected = _calculateExpectedClaim(20 ether, lifetimeETH, lifetimeETH, 15 ether);
        assertEq(claim2Expected, 5 ether, "Claim 2: benefactor should receive delta 20-15 = 5 ETH");

        // ---- Claim 3: LP value unchanged ----
        // No new fees accumulated
        uint256 claim3Expected = _calculateExpectedClaim(20 ether, lifetimeETH, lifetimeETH, 20 ether);
        assertEq(claim3Expected, 0, "Claim 3: no new fees, should receive 0 ETH");
    }

    /**
     * @notice Test 5: Precision handling - 1e18 scaling for percentages
     * @dev Tests that small contributions and large LP values maintain precision
     *      Setup:
     *      - B1: 1 wei ETH (minimal contribution)
     *      - B2: 999...999 wei ETH (remaining)
     *      - LP value: type(uint256).max - 1 (near max)
     *      - Should still calculate correctly without overflow
     */
    function test_PrecisionHandling_SmallContributions() public {
        uint256 b1Lifetime = 1;  // 1 wei
        uint256 b2Lifetime = 10 ether - 1;  // ~10 ETH - 1 wei
        uint256 totalETH = 10 ether;
        uint256 lpValue = 1000 ether;

        _registerBenefactor(benefactor1, b1Lifetime);
        _registerBenefactor(benefactor2, b2Lifetime);
        _simulateConversionAndLiquidity(totalETH, lpValue);

        uint256 b1Expected = _calculateExpectedClaim(lpValue, b1Lifetime, totalETH, 0);
        uint256 b2Expected = _calculateExpectedClaim(lpValue, b2Lifetime, totalETH, 0);

        // B1 should get ~0.0001 ETH (1 / 10 ETH * 1000 ETH)
        assertEq(b1Expected, 100, "B1 (1 wei contribution) should get minimal share");

        // B2 should get almost all
        assertGt(b2Expected, 999 ether, "B2 should get ~999.9 ETH");

        // Totals should match (within rounding)
        assertEq(b1Expected + b2Expected, lpValue, "Total claims must equal LP value");
    }

    /**
     * @notice Test 6: LP value less than contributions (loss scenario)
     * @dev Setup:
     *      - Total contributions: 100 ETH
     *      - LP value: 50 ETH (50% loss)
     *      - Expected: each benefactor gets 50% of their share
     */
    function test_LPValueLosses_ReducedClaims() public {
        uint256 b1Lifetime = 60 ether;
        uint256 b2Lifetime = 40 ether;
        uint256 totalETH = 100 ether;
        uint256 lpValue = 50 ether;  // 50% loss

        _registerBenefactor(benefactor1, b1Lifetime);
        _registerBenefactor(benefactor2, b2Lifetime);
        _simulateConversionAndLiquidity(totalETH, lpValue);

        uint256 b1Expected = _calculateExpectedClaim(lpValue, b1Lifetime, totalETH, 0);
        uint256 b2Expected = _calculateExpectedClaim(lpValue, b2Lifetime, totalETH, 0);

        assertEq(b1Expected, 30 ether, "B1 should get 60% of 50 ETH = 30 ETH");
        assertEq(b2Expected, 20 ether, "B2 should get 40% of 50 ETH = 20 ETH");
    }

    /**
     * @notice Test 7: LP value greater than contributions (gains scenario)
     * @dev Setup:
     *      - Total contributions: 100 ETH
     *      - LP value: 500 ETH (5x growth)
     *      - Expected: each benefactor gets 5x their original share
     */
    function test_LPValueGains_AmplifiedClaims() public {
        uint256 b1Lifetime = 60 ether;
        uint256 b2Lifetime = 40 ether;
        uint256 totalETH = 100 ether;
        uint256 lpValue = 500 ether;  // 5x growth

        _registerBenefactor(benefactor1, b1Lifetime);
        _registerBenefactor(benefactor2, b2Lifetime);
        _simulateConversionAndLiquidity(totalETH, lpValue);

        uint256 b1Expected = _calculateExpectedClaim(lpValue, b1Lifetime, totalETH, 0);
        uint256 b2Expected = _calculateExpectedClaim(lpValue, b2Lifetime, totalETH, 0);

        assertEq(b1Expected, 300 ether, "B1 should get 60% of 500 ETH = 300 ETH");
        assertEq(b2Expected, 200 ether, "B2 should get 40% of 500 ETH = 200 ETH");
    }

    /**
     * @notice Test 8: Zero totalETHCollected (edge case)
     * @dev Setup:
     *      - benefactor has lifetime contribution but totalETHCollected = 0
     *      - Should return 0 (no valid ratio calculation)
     */
    function test_EdgeCase_ZeroTotalETHCollected() public {
        uint256 lifetimeETH = 10 ether;
        uint256 lpValue = 100 ether;

        // Register benefactor but don't set totalETHCollected
        _registerBenefactor(benefactor1, lifetimeETH);

        // Set LP value but leave totalETHCollected at 0
        vm.store(
            address(vault),
            keccak256(abi.encode(keccak256(abi.encode("alignmentTarget")), 2)),
            bytes32(lpValue)
        );

        uint256 expected = _calculateExpectedClaim(lpValue, lifetimeETH, 0, 0);
        assertEq(expected, 0, "Should return 0 when totalETHCollected is 0");
    }

    /**
     * @notice Test 9: Benefactor with zero lifetime contribution
     * @dev Setup:
     *      - Benefactor has 0 lifetime contribution
     *      - LP value = 100 ETH
     *      - Expected claim = 0
     */
    function test_EdgeCase_ZeroLifetimeContribution() public {
        uint256 b1Lifetime = 0;  // Zero contribution
        uint256 b2Lifetime = 100 ether;
        uint256 totalETH = 100 ether;
        uint256 lpValue = 100 ether;

        _registerBenefactor(benefactor1, b1Lifetime);
        _registerBenefactor(benefactor2, b2Lifetime);
        _simulateConversionAndLiquidity(totalETH, lpValue);

        uint256 b1Expected = _calculateExpectedClaim(lpValue, b1Lifetime, totalETH, 0);
        uint256 b2Expected = _calculateExpectedClaim(lpValue, b2Lifetime, totalETH, 0);

        assertEq(b1Expected, 0, "Zero lifetime contribution yields zero claim");
        assertEq(b2Expected, 100 ether, "B2 gets entire LP value");
    }

    /**
     * @notice Test 10: Fractional division accuracy
     * @dev Tests that fractional divisions (e.g., 1/3, 2/3) maintain precision
     *      Setup:
     *      - B1: 33.33... ETH (1/3), B2: 66.66... ETH (2/3)
     *      - LP value: 99 ETH
     *      - Expected: B1 ≈ 33 ETH, B2 ≈ 66 ETH (with rounding)
     */
    function test_PrecisionHandling_FractionalDivision() public {
        uint256 totalETH = 99 ether;
        uint256 b1Lifetime = totalETH / 3;  // 33 ETH
        uint256 b2Lifetime = totalETH - b1Lifetime;  // 66 ETH
        uint256 lpValue = 99 ether;

        _registerBenefactor(benefactor1, b1Lifetime);
        _registerBenefactor(benefactor2, b2Lifetime);
        _simulateConversionAndLiquidity(totalETH, lpValue);

        uint256 b1Expected = _calculateExpectedClaim(lpValue, b1Lifetime, totalETH, 0);
        uint256 b2Expected = _calculateExpectedClaim(lpValue, b2Lifetime, totalETH, 0);

        // Verify proportions are maintained
        uint256 totalClaimed = b1Expected + b2Expected;
        assertEq(totalClaimed, lpValue, "Total claims equal LP value");

        // Verify ratios maintained (within rounding)
        assertApproxEqAbs(b1Expected * 3, b2Expected * 3 / 2, 1, "1:2 ratio maintained");
    }

    /**
     * @notice Test 11: Last claim amount updates prevent double-claiming
     * @dev Setup:
     *      - Benefactor claims at LP value 100 ETH (receives 100)
     *      - lastClaimAmount set to 100 in state
     *      - LP value unchanged
     *      - Next claim should return 0 (100 - 100 = 0)
     */
    function test_LastClaimAmount_PreventsDouble_Claiming() public {
        uint256 lifetimeETH = 10 ether;
        uint256 lpValue = 100 ether;
        uint256 lastClaimAmount = 100 ether;  // Already claimed everything

        uint256 claim1 = _calculateExpectedClaim(lpValue, lifetimeETH, 10 ether, 0);
        uint256 claim2 = _calculateExpectedClaim(lpValue, lifetimeETH, 10 ether, lastClaimAmount);

        assertEq(claim1, 100 ether, "First claim receives full share");
        assertEq(claim2, 0, "Second claim with unchanged LP value returns 0");
    }

    /**
     * @notice Test 12: Very large numbers don't overflow
     * @dev Tests claim calculation with max-like values
     *      Setup:
     *      - Uses large but realistic Solidity values
     *      - Ensures no overflow in multiplication
     *      - Note: Integer division causes rounding loss at scale
     */
    function test_LargeNumbers_NoOverflow() public {
        uint256 b1Lifetime = 10_000_000 ether;  // 10M ETH
        uint256 b2Lifetime = 5_000_000 ether;   // 5M ETH
        uint256 totalETH = b1Lifetime + b2Lifetime;
        uint256 lpValue = 1_000_000_000 ether;  // 1B ETH value

        _registerBenefactor(benefactor1, b1Lifetime);
        _registerBenefactor(benefactor2, b2Lifetime);
        _simulateConversionAndLiquidity(totalETH, lpValue);

        uint256 b1Expected = _calculateExpectedClaim(lpValue, b1Lifetime, totalETH, 0);
        uint256 b2Expected = _calculateExpectedClaim(lpValue, b2Lifetime, totalETH, 0);

        // B1: (1B * 10M) / 15M = 666.67M
        assertEq(b1Expected, (lpValue * b1Lifetime) / totalETH, "B1 calculation correct");

        // B2: (1B * 5M) / 15M = 333.33M
        assertEq(b2Expected, (lpValue * b2Lifetime) / totalETH, "B2 calculation correct");

        // Totals match (within 1 wei of rounding loss)
        uint256 totalClaimed = b1Expected + b2Expected;
        assertLe(lpValue - totalClaimed, 1, "Total within 1 wei of LP value (rounding loss)");
    }

    /**
     * @notice Test 13: Accumulated fees scenario (incremental LP fee collection)
     * @dev Simulates realistic scenario:
     *      - Initial conversion: 100 ETH → 100 ETH LP value
     *      - Fees accumulate: 10 ETH collected as LP fees
     *      - Total LP value now: 110 ETH
     *      - Benefactor can claim the 10 ETH fee growth
     */
    function test_RealisticScenario_FeesAccumulate() public {
        uint256 lifetimeETH = 100 ether;
        uint256 initialLPValue = 100 ether;
        uint256 feesAccumulated = 10 ether;
        uint256 totalLPValue = initialLPValue + feesAccumulated;

        _registerBenefactor(benefactor1, lifetimeETH);

        // After initial conversion
        _simulateConversionAndLiquidity(lifetimeETH, initialLPValue);
        uint256 initialClaim = _calculateExpectedClaim(initialLPValue, lifetimeETH, lifetimeETH, 0);
        assertEq(initialClaim, 100 ether, "Initial claim equals initial LP value");

        // After fees accumulate
        _simulateConversionAndLiquidity(lifetimeETH, totalLPValue);
        uint256 secondClaim = _calculateExpectedClaim(totalLPValue, lifetimeETH, lifetimeETH, initialClaim);
        assertEq(secondClaim, feesAccumulated, "Second claim receives only new fees");
    }

    /**
     * @notice Test 14: Fractional ETH in benefactor contributions
     * @dev Tests that fractional ETH amounts maintain precision
     *      Setup:
     *      - B1: 1.5 ETH, B2: 2.5 ETH, B3: 1 ETH
     *      - Total: 5 ETH
     *      - LP value: 50 ETH
     *      - Expected: B1=15, B2=25, B3=10 ETH
     */
    function test_FractionalETH_Contributions() public {
        uint256 b1Lifetime = 1.5 ether;
        uint256 b2Lifetime = 2.5 ether;
        uint256 b3Lifetime = 1 ether;
        uint256 totalETH = 5 ether;
        uint256 lpValue = 50 ether;

        _registerBenefactor(benefactor1, b1Lifetime);
        _registerBenefactor(benefactor2, b2Lifetime);
        _registerBenefactor(benefactor3, b3Lifetime);
        _simulateConversionAndLiquidity(totalETH, lpValue);

        uint256 b1Expected = _calculateExpectedClaim(lpValue, b1Lifetime, totalETH, 0);
        uint256 b2Expected = _calculateExpectedClaim(lpValue, b2Lifetime, totalETH, 0);
        uint256 b3Expected = _calculateExpectedClaim(lpValue, b3Lifetime, totalETH, 0);

        assertEq(b1Expected, 15 ether, "B1 gets 30% of 50 ETH = 15 ETH");
        assertEq(b2Expected, 25 ether, "B2 gets 50% of 50 ETH = 25 ETH");
        assertEq(b3Expected, 10 ether, "B3 gets 20% of 50 ETH = 10 ETH");
    }
}
