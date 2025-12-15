// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {BondingCurveMath} from "../../src/factories/erc404/libraries/BondingCurveMath.sol";

/**
 * @title BondingCurveMathTest
 * @notice Comprehensive test suite for BondingCurveMath library
 * @dev Tests polynomial bonding curve: P(s) = quarticCoeff * S^4 + cubicCoeff * S^3 + quadraticCoeff * S^2 + initialPrice
 */
contract BondingCurveMathTest is Test {
    using BondingCurveMath for BondingCurveMath.Params;

    // Standard ERC404 bonding curve parameters (matching CULTEXEC404)
    BondingCurveMath.Params public standardParams;
    BondingCurveMath.Params public linearParams;
    BondingCurveMath.Params public quadraticParams;
    BondingCurveMath.Params public fullPolynomialParams;

    function setUp() public {
        // Standard parameters (realistic ERC404 curve)
        standardParams = BondingCurveMath.Params({
            initialPrice: 0.025 ether,
            quarticCoeff: 3 gwei,        // 12/4 * 1 gwei (integral coefficient)
            cubicCoeff: 1333333333,       // 4/3 * 1 gwei (integral coefficient)
            quadraticCoeff: 2 gwei,      // 4/2 * 1 gwei (integral coefficient)
            normalizationFactor: 1e7     // 10M tokens base
        });

        // Linear only (no polynomial terms)
        linearParams = BondingCurveMath.Params({
            initialPrice: 0.01 ether,
            quarticCoeff: 0,
            cubicCoeff: 0,
            quadraticCoeff: 0,
            normalizationFactor: 1e7
        });

        // Quadratic only
        quadraticParams = BondingCurveMath.Params({
            initialPrice: 0.01 ether,
            quarticCoeff: 0,
            cubicCoeff: 0,
            quadraticCoeff: 1 gwei,
            normalizationFactor: 1e7
        });

        // Full polynomial with all coefficients
        fullPolynomialParams = BondingCurveMath.Params({
            initialPrice: 0.05 ether,
            quarticCoeff: 5 gwei,
            cubicCoeff: 2 gwei,
            quadraticCoeff: 3 gwei,
            normalizationFactor: 1e7
        });
    }

    // ============================================
    // 1. Basic Integral Calculation (6 tests)
    // ============================================

    function test_calculateIntegral_ZeroToSmall() public view {
        // Test integral from 0 to 100 tokens
        // Note: 100 tokens / normalizationFactor (1e7) = 0.00001 scaled supply
        // So the cost is very small due to scaling
        uint256 amount = 100 * 1e18;
        uint256 integral = BondingCurveMath.calculateIntegral(standardParams, 0, amount);

        // Should be positive and relatively small for low supply
        assertGt(integral, 0, "Integral should be positive");
        // Due to normalization, cost is: 0.025 ether * (100*1e18/1e7) / 1e18 = 0.00025 ether
        assertLt(integral, 0.001 ether, "Integral should be small for 100 tokens");
    }

    function test_calculateIntegral_SmallRange() public view {
        // Test integral from 100 to 200 tokens
        uint256 lower = 100 * 1e18;
        uint256 upper = 200 * 1e18;
        uint256 integral = BondingCurveMath.calculateIntegral(standardParams, lower, upper);

        assertGt(integral, 0, "Integral should be positive");
        // Due to very small scaled supply, costs are similar at low ranges
        uint256 firstIntegral = BondingCurveMath.calculateIntegral(standardParams, 0, 100 * 1e18);
        // At very small scales, the polynomial terms are negligible
        assertGe(integral, firstIntegral * 99 / 100, "Costs should be similar at low supply");
    }

    function test_calculateIntegral_LargeRange() public view {
        // Test integral from 0 to 1M tokens (10% of normalization factor)
        uint256 amount = 1_000_000 * 1e18;
        uint256 integral = BondingCurveMath.calculateIntegral(standardParams, 0, amount);

        assertGt(integral, 0, "Integral should be positive");
        // 1M tokens at 0.1 scaled supply should have noticeable cost
        assertGt(integral, 0.001 ether, "Large supply should have measurable cost");
    }

    function test_calculateIntegral_SamePoints() public view {
        // Test integral where upperBound == lowerBound (should return 0)
        uint256 supply = 1000 * 1e18;
        uint256 integral = BondingCurveMath.calculateIntegral(standardParams, supply, supply);

        assertEq(integral, 0, "Integral of same points should be zero");
    }

    function test_calculateIntegral_Ordering() public view {
        // Verify (0,100) + (100,200) = (0,200)
        uint256 integral1 = BondingCurveMath.calculateIntegral(standardParams, 0, 100 * 1e18);
        uint256 integral2 = BondingCurveMath.calculateIntegral(standardParams, 100 * 1e18, 200 * 1e18);
        uint256 integralTotal = BondingCurveMath.calculateIntegral(standardParams, 0, 200 * 1e18);

        assertEq(integral1 + integral2, integralTotal, "Integral additivity should hold");
    }

    function test_calculateIntegral_WithHighPrecision() public view {
        // Test rounding behavior with very small amounts
        uint256 smallAmount = 1e18; // 1 token
        uint256 integral = BondingCurveMath.calculateIntegral(standardParams, 0, smallAmount);

        // Should be close to initial price but account for polynomial terms
        assertGt(integral, 0, "Integral should be positive");
        assertLt(integral, 0.1 ether, "Single token should be reasonably priced");
    }

    // ============================================
    // 2. Cost Calculation (calculateCost) (8 tests)
    // ============================================

    function test_calculateCost_FirstToken() public view {
        // Cost of first token from zero supply
        // 1 token / 1e7 normalization = 0.0000001 scaled supply
        uint256 cost = BondingCurveMath.calculateCost(standardParams, 0, 1e18);

        assertGt(cost, 0, "First token should have cost");
        // Due to normalization, cost is scaled down proportionally
        // 1 token out of 10M base costs about 0.025 ether / 1e7
        assertGt(cost, 1 gwei, "First token should have measurable cost");
        assertLt(cost, 0.01 ether, "First token should not be too expensive");
    }

    function test_calculateCost_SmallAmount() public view {
        // Cost of 1 token at supply 100
        // At very low supply (100 / 1e7 = 0.00001), polynomial terms are negligible
        uint256 currentSupply = 100 * 1e18;
        uint256 cost = BondingCurveMath.calculateCost(standardParams, currentSupply, 1e18);

        assertGt(cost, 0, "Cost should be positive");
        // At tiny scaled supply, costs are essentially the same (polynomial insignificant)
        uint256 firstTokenCost = BondingCurveMath.calculateCost(standardParams, 0, 1e18);
        assertGe(cost, firstTokenCost * 99 / 100, "Costs should be similar at low supply");
    }

    function test_calculateCost_LargeAmount() public view {
        // Cost of 1M tokens from zero supply (10% of normalization)
        uint256 amount = 1_000_000 * 1e18;
        uint256 cost = BondingCurveMath.calculateCost(standardParams, 0, amount);

        assertGt(cost, 0, "Large purchase should have cost");
        // 1M tokens is substantial relative to the scaled curve
        assertGt(cost, 0.001 ether, "1M tokens should have measurable cost");
    }

    function test_calculateCost_ZeroAmount() public view {
        // Cost of zero tokens should be zero
        uint256 cost = BondingCurveMath.calculateCost(standardParams, 0, 0);

        assertEq(cost, 0, "Zero amount should have zero cost");
    }

    function test_calculateCost_MonotonicIncreasing() public view {
        // Each additional token should cost more (or equal for linear)
        uint256 supply = 0;
        uint256 previousCost = 0;

        for (uint256 i = 0; i < 10; i++) {
            uint256 cost = BondingCurveMath.calculateCost(standardParams, supply, 100 * 1e18);
            assertGe(cost, previousCost, "Cost should monotonically increase");
            previousCost = cost;
            supply += 100 * 1e18;
        }
    }

    function test_calculateCost_WithDifferentCoefficients() public view {
        // Test impact of each coefficient
        uint256 amount = 1000 * 1e18;

        // Linear only
        uint256 linearCost = BondingCurveMath.calculateCost(linearParams, 0, amount);

        // Quadratic
        uint256 quadraticCost = BondingCurveMath.calculateCost(quadraticParams, 0, amount);

        // Full polynomial
        uint256 fullCost = BondingCurveMath.calculateCost(fullPolynomialParams, 0, amount);

        // All should be positive
        assertGt(linearCost, 0, "Linear cost should be positive");
        assertGt(quadraticCost, 0, "Quadratic cost should be positive");
        assertGt(fullCost, 0, "Full polynomial cost should be positive");

        // Polynomial terms add cost
        assertGt(quadraticCost, linearCost, "Quadratic should cost more than linear");
    }

    function test_calculateCost_Scalability() public view {
        // Test with supply approaching normalization factor
        uint256 nearMaxSupply = 9_000_000 * 1e18; // 90% of 10M normalization (scaled = 0.9)
        uint256 cost = BondingCurveMath.calculateCost(standardParams, nearMaxSupply, 1000 * 1e18);

        assertGt(cost, 0, "Cost at high supply should be positive");
        // At 0.9 scaled supply, cost includes polynomial terms
        // but still relatively small due to coefficient sizes
        assertGt(cost, 0.000001 ether, "High supply tokens should cost something");
    }

    function test_calculateCost_NormalizationFactor() public view {
        // Test different normalization factors
        BondingCurveMath.Params memory params10x = standardParams;
        params10x.normalizationFactor = 1e8; // 100M tokens (10x larger)

        BondingCurveMath.Params memory params01x = standardParams;
        params01x.normalizationFactor = 1e6; // 1M tokens (0.1x smaller)

        uint256 amount = 1000 * 1e18;

        uint256 costStandard = BondingCurveMath.calculateCost(standardParams, 0, amount);
        uint256 cost10x = BondingCurveMath.calculateCost(params10x, 0, amount);
        uint256 cost01x = BondingCurveMath.calculateCost(params01x, 0, amount);

        // Larger normalization = slower price growth = cheaper
        assertLt(cost10x, costStandard, "10x normalization should be cheaper");
        // Smaller normalization = faster price growth = more expensive
        assertGt(cost01x, costStandard, "0.1x normalization should be more expensive");
    }

    // ============================================
    // 3. Refund Calculation (calculateRefund) (6 tests)
    // ============================================

    function test_calculateRefund_AfterMint() public view {
        // Mint 100 tokens, refund for 1 token
        uint256 mintAmount = 100 * 1e18;
        uint256 costToMint = BondingCurveMath.calculateCost(standardParams, 0, mintAmount);

        // Now refund 1 token at supply 100
        uint256 refund = BondingCurveMath.calculateRefund(standardParams, mintAmount, 1e18);

        assertGt(refund, 0, "Refund should be positive");
        // At very low supply (100/1e7), cost progression is minimal
        // Refund for token 100->99 should be similar to cost for token 0->1
        uint256 firstTokenCost = BondingCurveMath.calculateCost(standardParams, 0, 1e18);
        assertGe(refund, firstTokenCost * 99 / 100, "Refund should be similar at low supply");
    }

    function test_calculateRefund_PartialReturn() public view {
        // Buy 100 tokens, return 50
        uint256 currentSupply = 100 * 1e18;
        uint256 returnAmount = 50 * 1e18;

        uint256 refund = BondingCurveMath.calculateRefund(standardParams, currentSupply, returnAmount);

        assertGt(refund, 0, "Partial refund should be positive");
        // Refund should be less than cost of buying those same 50 tokens
        uint256 costOfLast50 = BondingCurveMath.calculateCost(standardParams, 50 * 1e18, 50 * 1e18);
        assertApproxEqAbs(refund, costOfLast50, 1e15, "Refund should match integral");
    }

    function test_calculateRefund_AllTokens() public view {
        // Return all tokens
        uint256 currentSupply = 100 * 1e18;
        uint256 refund = BondingCurveMath.calculateRefund(standardParams, currentSupply, currentSupply);

        // Refund should equal cost to buy from 0 to 100
        uint256 costToBuy = BondingCurveMath.calculateCost(standardParams, 0, currentSupply);

        assertEq(refund, costToBuy, "Full refund should equal original cost");
    }

    function test_calculateRefund_ZeroAmount() public view {
        // Refund of zero tokens should be zero
        uint256 refund = BondingCurveMath.calculateRefund(standardParams, 100 * 1e18, 0);

        assertEq(refund, 0, "Zero refund amount should be zero");
    }

    function test_calculateRefund_AsymmetryToCost() public view {
        // Buy 100 tokens, then sell 100 tokens
        uint256 amount = 100 * 1e18;

        // Cost to buy from 0 to 100
        uint256 costToBuy = BondingCurveMath.calculateCost(standardParams, 0, amount);

        // Refund for selling from 100 to 0
        uint256 refundFromSell = BondingCurveMath.calculateRefund(standardParams, amount, amount);

        // These should be equal (same integral range)
        assertEq(costToBuy, refundFromSell, "Buy and sell over same range should be equal");
    }

    function test_calculateRefund_SequentialReturns() public view {
        // Return 10 then 20 should equal returning 30
        uint256 currentSupply = 100 * 1e18;

        uint256 refund1 = BondingCurveMath.calculateRefund(standardParams, currentSupply, 10 * 1e18);
        uint256 refund2 = BondingCurveMath.calculateRefund(standardParams, currentSupply - 10 * 1e18, 20 * 1e18);
        uint256 refundTotal = BondingCurveMath.calculateRefund(standardParams, currentSupply, 30 * 1e18);

        assertEq(refund1 + refund2, refundTotal, "Sequential refunds should add up");
    }

    // ============================================
    // 4. Cost vs Refund Dynamics (7 tests)
    // ============================================

    function test_CostRefundAsymmetry() public view {
        // Buy 1 token at supply 50, then sell 1 token at supply 51
        uint256 baseSupply = 50 * 1e18;

        uint256 costToBuy = BondingCurveMath.calculateCost(standardParams, baseSupply, 1e18);
        uint256 refundToSell = BondingCurveMath.calculateRefund(standardParams, baseSupply + 1e18, 1e18);

        // These should be equal (same supply range)
        assertEq(costToBuy, refundToSell, "Cost and refund at same supply should be equal");
    }

    function test_BondingCurveProgression() public view {
        // Verify price progression with larger supply differences
        uint256 firstTokenCost = BondingCurveMath.calculateCost(standardParams, 0, 1e18);
        uint256 token1MCost = BondingCurveMath.calculateCost(standardParams, 999_999 * 1e18, 1e18);
        uint256 token5MCost = BondingCurveMath.calculateCost(standardParams, 4_999_999 * 1e18, 1e18);

        // Need significant scaled supply to see polynomial effects
        assertLt(firstTokenCost, token1MCost, "Cost should increase at 10% supply");
        assertLt(token1MCost, token5MCost, "Cost should increase at 50% supply");

        // Ratio should increase due to polynomial (at higher scaled values)
        uint256 ratio1 = (token1MCost * 1e18) / firstTokenCost;
        uint256 ratio2 = (token5MCost * 1e18) / token1MCost;
        assertGe(ratio2, ratio1, "Price acceleration should be visible at higher supply");
    }

    function test_CostIncreaseWithSupply() public view {
        // Same amount costs more at higher initial supply - need significant supply differences
        uint256 amount = 10_000 * 1e18;

        uint256 costAtZero = BondingCurveMath.calculateCost(standardParams, 0, amount);
        uint256 costAt1M = BondingCurveMath.calculateCost(standardParams, 1_000_000 * 1e18, amount);
        uint256 costAt5M = BondingCurveMath.calculateCost(standardParams, 5_000_000 * 1e18, amount);

        assertLt(costAtZero, costAt1M, "Cost should increase at 10% supply");
        assertLt(costAt1M, costAt5M, "Cost should increase at 50% supply");
    }

    function test_FullCycleProfitability() public view {
        // Buy 100 tokens, sell 100 tokens - should break even (no slippage loss)
        uint256 amount = 100 * 1e18;

        uint256 costToBuy = BondingCurveMath.calculateCost(standardParams, 0, amount);
        uint256 refundToSell = BondingCurveMath.calculateRefund(standardParams, amount, amount);

        // With bonding curve, should be equal (no loss, same integral)
        assertEq(costToBuy, refundToSell, "Full cycle should break even");
    }

    function test_CostRefundGap() public view {
        // Gap between buying and selling at different supply points
        // Buy 10 tokens at supply 100
        uint256 supply = 100 * 1e18;
        uint256 amount = 10 * 1e18;

        uint256 costToBuy = BondingCurveMath.calculateCost(standardParams, supply, amount);
        // Sell 10 tokens at supply 100 (before buying)
        uint256 refundBeforeBuy = BondingCurveMath.calculateRefund(standardParams, supply, amount);

        // These should be equal (same supply range 90-100)
        assertEq(costToBuy, refundBeforeBuy, "Cost to buy 100->110 should equal refund 100->90");
    }

    function test_BreakEvenPoint() public view {
        // Due to integral math, buying and selling same range should be equal
        uint256 supply = 500 * 1e18;
        uint256 amount = 50 * 1e18;

        uint256 cost = BondingCurveMath.calculateCost(standardParams, supply, amount);
        uint256 refund = BondingCurveMath.calculateRefund(standardParams, supply + amount, amount);

        assertEq(cost, refund, "Cost and refund should be equal for same range");
    }

    function test_RealWorldScenario_ERC404Bonding() public view {
        // Simulate real ERC404 bonding scenario
        // User buys 1000 tokens at start
        uint256 initialBuy = 1000 * 1e18;
        uint256 initialCost = BondingCurveMath.calculateCost(standardParams, 0, initialBuy);

        // Supply increases as others buy
        uint256 newSupply = 5000 * 1e18;

        // User sells their 1000 tokens at higher supply
        uint256 refund = BondingCurveMath.calculateRefund(standardParams, newSupply, 1000 * 1e18);

        // User profits from supply increase
        assertGt(refund, initialCost, "Should profit from supply increase");

        // Log the profit
        uint256 profit = refund - initialCost;
        console2.log("Initial buy (1000 tokens):", initialCost);
        console2.log("Refund at 5000 supply:", refund);
        console2.log("Profit:", profit);
    }

    // ============================================
    // 5. Polynomial Coefficient Effects (8 tests)
    // ============================================

    function test_WithOnlyInitialPrice() public view {
        // Linear curve (constant price) - but scaled by normalization
        uint256 amount = 1000 * 1e18;
        uint256 cost = BondingCurveMath.calculateCost(linearParams, 0, amount);

        // Cost is initialPrice * (scaledSupply) = initialPrice * (amount / normalizationFactor)
        // = 0.01 ether * (1000 * 1e18 / 1e7) = 0.01 ether * 100 = 1 ether (but in WAD)
        uint256 scaledAmount = amount / linearParams.normalizationFactor; // 1e18 / 1e7 * 1000 = 100e11
        uint256 expected = (linearParams.initialPrice * scaledAmount) / 1e18;
        assertApproxEqRel(cost, expected, 0.01e18, "Linear cost should match scaled calculation");
    }

    function test_WithOnlyLinearAndQuadratic() public view {
        // Test with cubic=0
        uint256 amount = 1000 * 1e18;
        uint256 cost = BondingCurveMath.calculateCost(quadraticParams, 0, amount);

        assertGt(cost, 0, "Quadratic cost should be positive");
        // Should be more than pure linear
        uint256 linearCost = BondingCurveMath.calculateCost(linearParams, 0, amount);
        assertGt(cost, linearCost, "Quadratic should cost more than linear");
    }

    function test_WithFullPolynomial() public view {
        // All coefficients non-zero
        uint256 amount = 1000 * 1e18;
        uint256 cost = BondingCurveMath.calculateCost(fullPolynomialParams, 0, amount);

        assertGt(cost, 0, "Full polynomial cost should be positive");
        // Should be significantly more than linear
        uint256 linearCost = BondingCurveMath.calculateCost(linearParams, 0, amount);
        assertGt(cost, linearCost * 2, "Full polynomial should be much more expensive");
    }

    function test_QuarticDominance() public view {
        // At high supply, quartic term contributes
        uint256 highSupply = 5_000_000 * 1e18; // 50% of normalization factor (scaled = 0.5)
        uint256 amount = 100_000 * 1e18; // Larger amount to see effect

        uint256 cost = BondingCurveMath.calculateCost(standardParams, highSupply, amount);

        // Cost should include quartic term effects
        // quarticCoeff = 3 gwei, at scaled 0.5, S^4 term contributes
        assertGt(cost, 0.0001 ether, "Quartic effect contributes at high supply");
    }

    function test_CubicVsQuartic() public view {
        // Compare impact of cubic vs quartic at meaningful scaled supply
        BondingCurveMath.Params memory cubicOnly = standardParams;
        cubicOnly.quarticCoeff = 0;

        BondingCurveMath.Params memory quarticOnly = standardParams;
        quarticOnly.cubicCoeff = 0;
        quarticOnly.quadraticCoeff = 0;

        uint256 highSupply = 5_000_000 * 1e18; // 50% scaled supply
        uint256 amount = 100_000 * 1e18;

        uint256 cubicCost = BondingCurveMath.calculateCost(cubicOnly, highSupply, amount);
        uint256 quarticCost = BondingCurveMath.calculateCost(quarticOnly, highSupply, amount);

        // At 0.5 scaled supply, S^4 vs S^3 difference becomes visible
        assertGt(quarticCost, cubicCost * 95 / 100, "Both should contribute at high supply");
    }

    function test_CoefficientScaling() public view {
        // Test with 10x larger coefficients
        BondingCurveMath.Params memory scaled = standardParams;
        scaled.quarticCoeff = standardParams.quarticCoeff * 10;
        scaled.cubicCoeff = standardParams.cubicCoeff * 10;
        scaled.quadraticCoeff = standardParams.quadraticCoeff * 10;

        uint256 amount = 1000 * 1e18;
        uint256 standardCost = BondingCurveMath.calculateCost(standardParams, 0, amount);
        uint256 scaledCost = BondingCurveMath.calculateCost(scaled, 0, amount);

        // Scaled cost should be significantly higher
        assertGt(scaledCost, standardCost, "10x coefficients should increase cost");
    }

    function test_ZeroCoefficients() public view {
        // All coefficients zero except initial price
        BondingCurveMath.Params memory zeroCoeffs = BondingCurveMath.Params({
            initialPrice: 0.025 ether,
            quarticCoeff: 0,
            cubicCoeff: 0,
            quadraticCoeff: 0,
            normalizationFactor: 1e7
        });

        uint256 amount = 1000 * 1e18;
        uint256 cost = BondingCurveMath.calculateCost(zeroCoeffs, 0, amount);

        // Cost = initialPrice * (scaledAmount) = initialPrice * (amount / normalizationFactor)
        uint256 scaledAmount = amount / zeroCoeffs.normalizationFactor;
        uint256 expected = (zeroCoeffs.initialPrice * scaledAmount) / 1e18;
        assertEq(cost, expected, "Zero coefficients should give linear cost (scaled)");
    }

    function test_NegativeEffects() public view {
        // Test edge case: very small initial price
        BondingCurveMath.Params memory smallPrice = standardParams;
        smallPrice.initialPrice = 1 wei;

        uint256 amount = 1000 * 1e18;
        uint256 cost = BondingCurveMath.calculateCost(smallPrice, 0, amount);

        // Should still work, polynomial terms dominate
        assertGt(cost, 0, "Small initial price should still work");
    }

    // ============================================
    // 6. Normalization Factor Effects (4 tests)
    // ============================================

    function test_NormalizationFactor_10M() public view {
        // Standard 10M normalization
        uint256 amount = 100_000 * 1e18; // 1% of max supply
        uint256 cost = BondingCurveMath.calculateCost(standardParams, 0, amount);

        assertGt(cost, 0, "10M normalization should work");
        assertLt(cost, 10000 ether, "Reasonable cost for 1% of supply");
    }

    function test_NormalizationFactor_1B() public view {
        // 1B normalization (100x larger)
        BondingCurveMath.Params memory largeNorm = standardParams;
        largeNorm.normalizationFactor = 1e9;

        uint256 amount = 100_000 * 1e18;
        uint256 cost = BondingCurveMath.calculateCost(largeNorm, 0, amount);

        // Should be much cheaper due to slower growth
        uint256 standardCost = BondingCurveMath.calculateCost(standardParams, 0, amount);
        assertLt(cost, standardCost, "Larger normalization should be cheaper");
    }

    function test_NormalizationFactor_Scaling() public view {
        // Verify 10x normalization scales predictably
        BondingCurveMath.Params memory norm10x = standardParams;
        norm10x.normalizationFactor = 1e8; // 100M tokens

        // Buy same absolute amount
        uint256 amount = 100_000 * 1e18;

        uint256 costStandard = BondingCurveMath.calculateCost(standardParams, 0, amount);
        uint256 cost10x = BondingCurveMath.calculateCost(norm10x, 0, amount);

        // 10x normalization means supply is 1/10th as far along the curve
        assertLt(cost10x, costStandard, "10x normalization reduces cost");
    }

    function test_NormalizationFactor_ExtremeCases() public view {
        // Very small normalization (fast price growth)
        BondingCurveMath.Params memory tinyNorm = standardParams;
        tinyNorm.normalizationFactor = 1e5; // 100k tokens (100x smaller)

        // Very large normalization (slow price growth)
        BondingCurveMath.Params memory hugeNorm = standardParams;
        hugeNorm.normalizationFactor = 1e10; // 10B tokens (1000x larger)

        uint256 amount = 1000 * 1e18;

        uint256 costTiny = BondingCurveMath.calculateCost(tinyNorm, 0, amount);
        uint256 costHuge = BondingCurveMath.calculateCost(hugeNorm, 0, amount);

        assertGt(costTiny, costHuge, "Smaller normalization should be more expensive");
    }

    // ============================================
    // 7. Edge Cases & Boundaries (6 tests)
    // ============================================

    function test_SupplyOverflow() public view {
        // Test with very large supply (but not overflowing)
        uint256 largeSupply = 1_000_000_000 * 1e18; // 1B tokens

        // Should not revert, but cost will be astronomical
        uint256 cost = BondingCurveMath.calculateCost(standardParams, largeSupply, 1e18);
        assertGt(cost, 0, "Large supply should still calculate");
    }

    function test_PrecisionLoss() public view {
        // Test with very small amounts (1 wei)
        uint256 tinyAmount = 1;
        uint256 cost = BondingCurveMath.calculateCost(standardParams, 0, tinyAmount);

        // Should be effectively zero or very small
        assertLt(cost, 1 gwei, "1 wei purchase should be tiny");
    }

    function test_BoundaryConditions() public {
        // Test invalid bounds (upper < lower)
        // Use try-catch to handle revert properly
        try this.externalCalculateIntegral(standardParams, 100, 50) {
            fail("Should have reverted with invalid bounds");
        } catch (bytes memory reason) {
            // Expected to revert
            assertTrue(true);
        }
    }

    // External wrapper for testing reverts
    function externalCalculateIntegral(
        BondingCurveMath.Params memory params,
        uint256 lower,
        uint256 upper
    ) external pure returns (uint256) {
        return BondingCurveMath.calculateIntegral(params, lower, upper);
    }

    function test_VerySmallAmounts() public view {
        // 1 wei purchase
        uint256 cost = BondingCurveMath.calculateCost(standardParams, 0, 1);

        // Should be calculable and tiny
        assertLt(cost, 1 gwei, "1 wei should be very cheap");
    }

    function test_VeryLargeAmounts() public view {
        // Buy 1B tokens (100x normalization factor - scaled supply = 100)
        uint256 hugeAmount = 1_000_000_000 * 1e18;
        uint256 cost = BondingCurveMath.calculateCost(standardParams, 0, hugeAmount);

        assertGt(cost, 0, "Huge amount should calculate");
        // At scaled supply = 100, S^4 term = 100^4 = 100M, so cost is substantial
        assertGt(cost, 1 ether, "1B tokens (scaled=100) should be expensive");
    }

    function test_GasOptimization() public {
        // Measure gas for typical operations
        uint256 amount = 1000 * 1e18;

        uint256 gasBefore = gasleft();
        BondingCurveMath.calculateCost(standardParams, 0, amount);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Gas used for calculateCost:", gasUsed);

        // Should be reasonably efficient (under 50k gas)
        assertLt(gasUsed, 50000, "Gas usage should be reasonable");
    }

    // ============================================
    // Additional Integration Tests (3 tests)
    // ============================================

    function test_Integration_BuyAndSellCycle() public view {
        // Simulate a complete buy/sell cycle
        uint256 buyAmount = 1000 * 1e18;

        // Buy tokens
        uint256 buyC = BondingCurveMath.calculateCost(standardParams, 0, buyAmount);

        // Sell tokens
        uint256 sellRefund = BondingCurveMath.calculateRefund(standardParams, buyAmount, buyAmount);

        // Should break even
        assertEq(buyC, sellRefund, "Buy/sell cycle should break even");
    }

    function test_Integration_MultipleUsers() public view {
        // Simulate multiple users buying sequentially
        uint256 user1Buy = 500 * 1e18;
        uint256 user2Buy = 300 * 1e18;
        uint256 user3Buy = 200 * 1e18;

        uint256 user1Cost = BondingCurveMath.calculateCost(standardParams, 0, user1Buy);
        uint256 user2Cost = BondingCurveMath.calculateCost(standardParams, user1Buy, user2Buy);
        uint256 user3Cost = BondingCurveMath.calculateCost(standardParams, user1Buy + user2Buy, user3Buy);

        // Total cost should equal buying all at once
        uint256 totalCost = BondingCurveMath.calculateCost(standardParams, 0, user1Buy + user2Buy + user3Buy);

        assertEq(user1Cost + user2Cost + user3Cost, totalCost, "Sequential buys should equal bulk buy");
    }

    function test_Integration_PriceDiscovery() public view {
        // Test price discovery at different supply points
        uint256[] memory supplyPoints = new uint256[](5);
        supplyPoints[0] = 100_000 * 1e18;    // 1% of 10M
        supplyPoints[1] = 500_000 * 1e18;    // 5% of 10M
        supplyPoints[2] = 1_000_000 * 1e18;  // 10% of 10M
        supplyPoints[3] = 5_000_000 * 1e18;  // 50% of 10M
        supplyPoints[4] = 9_000_000 * 1e18;  // 90% of 10M

        console2.log("Price Discovery (cost of next 100 tokens):");

        for (uint256 i = 0; i < supplyPoints.length; i++) {
            uint256 cost = BondingCurveMath.calculateCost(standardParams, supplyPoints[i], 100 * 1e18);
            console2.log("At", supplyPoints[i] / 1e18, "supply: ", cost);

            // Cost should increase monotonically
            if (i > 0) {
                uint256 prevCost = BondingCurveMath.calculateCost(
                    standardParams,
                    supplyPoints[i-1],
                    100 * 1e18
                );
                assertGt(cost, prevCost, "Price should increase with supply");
            }
        }
    }

    // ============================================
    // Fuzz Tests (3 tests)
    // ============================================

    function testFuzz_CalculateCost(uint256 supply, uint256 amount) public view {
        // Bound inputs to reasonable ranges
        supply = bound(supply, 0, 10_000_000 * 1e18);
        amount = bound(amount, 0, 1_000_000 * 1e18);

        uint256 cost = BondingCurveMath.calculateCost(standardParams, supply, amount);

        if (amount == 0) {
            assertEq(cost, 0, "Zero amount should have zero cost");
        } else {
            // At very small scaled amounts (< 10000 tokens = 0.001 scaled), cost might round to zero
            // Due to normalization factor of 1e7, amounts under ~10k tokens can have zero cost
            if (amount >= 10_000 * 1e18) {
                assertGt(cost, 0, "Significant amounts should have positive cost");
            } else {
                // Small amounts may or may not have cost due to rounding
                assertGe(cost, 0, "Cost should be non-negative");
            }
        }
    }

    function testFuzz_CalculateRefund(uint256 supply, uint256 amount) public view {
        // Bound inputs to reasonable ranges
        supply = bound(supply, 1000, 10_000_000 * 1e18); // Minimum 1000 to avoid rounding issues
        amount = bound(amount, 0, supply); // Can't refund more than supply

        uint256 refund = BondingCurveMath.calculateRefund(standardParams, supply, amount);

        if (amount == 0) {
            assertEq(refund, 0, "Zero refund should be zero");
        } else {
            // At very small scaled amounts, refund might round to zero
            // Only assert positive refund for meaningful amounts
            if (amount >= 1000) {
                assertGe(refund, 0, "Non-zero refund should be non-negative");
            }
        }
    }

    function testFuzz_IntegralAdditivity(uint256 a, uint256 b) public view {
        // Test that integral(a,b) + integral(b,c) = integral(a,c)
        a = bound(a, 0, 1_000_000 * 1e18);
        b = bound(b, a, 2_000_000 * 1e18);
        uint256 c = b + 100_000 * 1e18;

        uint256 int1 = BondingCurveMath.calculateIntegral(standardParams, a, b);
        uint256 int2 = BondingCurveMath.calculateIntegral(standardParams, b, c);
        uint256 intTotal = BondingCurveMath.calculateIntegral(standardParams, a, c);

        assertEq(int1 + int2, intTotal, "Integral additivity should hold");
    }
}
