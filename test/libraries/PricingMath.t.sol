// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {PricingMath} from "../../src/master/libraries/PricingMath.sol";

/**
 * @title PricingMathTest
 * @notice Comprehensive test suite for PricingMath library
 * @dev Tests all pricing functions including utilization, demand, price calculation, and decay
 */
contract PricingMathTest is Test {
    // Constants from PricingMath
    uint256 constant PRICE_DECAY_RATE = 1e15; // 0.1% per second
    uint256 constant DEMAND_DECAY_TIME = 3600; // 1 hour
    uint256 constant BASE_PRICE = 0.01 ether;
    uint256 constant MAX_PRICE_MULTIPLIER = 100; // 100x base price
    uint256 constant MIN_PRICE_MULTIPLIER = 1; // 1x base price

    function setUp() public {
        // Set block.timestamp to a reasonable value (Jan 1, 2024)
        // Foundry starts at timestamp=1, which causes underflow in tests using block.timestamp - X
        vm.warp(1704067200); // Jan 1, 2024 00:00:00 UTC
    }

    // ============================================
    // calculateUtilizationRate() Tests (4 tests)
    // ============================================

    function test_calculateUtilizationRate_ZeroOccupancy() public {
        uint256 occupied = 0;
        uint256 total = 100;

        uint256 rate = PricingMath.calculateUtilizationRate(occupied, total);

        assertEq(rate, 0, "Zero occupancy should return 0% utilization");
    }

    function test_calculateUtilizationRate_FullOccupancy() public {
        uint256 occupied = 100;
        uint256 total = 100;

        uint256 rate = PricingMath.calculateUtilizationRate(occupied, total);

        assertEq(rate, 1e18, "Full occupancy should return 100% utilization (1e18)");
    }

    function test_calculateUtilizationRate_HalfOccupancy() public {
        uint256 occupied = 50;
        uint256 total = 100;

        uint256 rate = PricingMath.calculateUtilizationRate(occupied, total);

        assertEq(rate, 0.5e18, "Half occupancy should return 50% utilization (0.5e18)");
    }

    function test_calculateUtilizationRate_ZeroTotal() public {
        uint256 occupied = 0;
        uint256 total = 0;

        uint256 rate = PricingMath.calculateUtilizationRate(occupied, total);

        assertEq(rate, 0, "Zero total should handle gracefully and return 0");
    }

    // ============================================
    // calculateDemandFactor() Tests (6 tests)
    // ============================================

    function test_calculateDemandFactor_JustCreated() public {
        uint256 lastPurchaseTime = block.timestamp - 10; // 10 seconds ago
        uint256 totalPurchases = 0;

        uint256 demandFactor = PricingMath.calculateDemandFactor(lastPurchaseTime, totalPurchases);

        // Time decay: 10 seconds of 3600 = 10/3600 = ~0.00277e18
        // purchaseFactor = 1e18 (no purchases)
        // factor = 1e18 - (1e18 * 0.00277e18) / 1e18 ≈ 0.997e18
        assertGt(demandFactor, 0.99e18, "Recent purchase should have high demand factor");
        assertLe(demandFactor, 1e18, "Demand factor should not exceed 1e18 with no purchases");
    }

    function test_calculateDemandFactor_AfterOneHour() public {
        uint256 lastPurchaseTime = block.timestamp - 3600; // 1 hour ago
        uint256 totalPurchases = 0;

        uint256 demandFactor = PricingMath.calculateDemandFactor(lastPurchaseTime, totalPurchases);

        // Time decay: 3600 seconds = DEMAND_DECAY_TIME, so timeDecay = 1e18
        // purchaseFactor = 1e18
        // factor = 1e18 - (1e18 * 1e18) / 1e18 = 0
        assertEq(demandFactor, 0, "After full decay time with no purchases, demand factor should be 0");
    }

    function test_calculateDemandFactor_HalfHour() public {
        uint256 lastPurchaseTime = block.timestamp - 1800; // 30 minutes ago
        uint256 totalPurchases = 0;

        uint256 demandFactor = PricingMath.calculateDemandFactor(lastPurchaseTime, totalPurchases);

        // Time decay: 1800 / 3600 = 0.5e18
        // purchaseFactor = 1e18
        // factor = 1e18 - (1e18 * 0.5e18) / 1e18 = 0.5e18
        assertEq(demandFactor, 0.5e18, "After half decay time, demand factor should be 0.5e18");
    }

    function test_calculateDemandFactor_WithPurchases() public {
        uint256 lastPurchaseTime = block.timestamp - 10; // Very recent
        uint256 totalPurchases = 5;

        uint256 demandFactor = PricingMath.calculateDemandFactor(lastPurchaseTime, totalPurchases);

        // Time decay: 10 / 3600 ≈ 0.00277e18
        // purchaseFactor = 1e18 + (5 * 1e17) = 1.5e18
        // factor = 1.5e18 - (1.5e18 * 0.00277e18) / 1e18 ≈ 1.496e18
        assertGt(demandFactor, 1.4e18, "With purchases, demand factor should include purchase bonus");
        assertLt(demandFactor, 1.6e18, "Demand factor should be reasonable");
    }

    function test_calculateDemandFactor_ZeroPurchases() public {
        uint256 lastPurchaseTime = block.timestamp - 1000; // Some time ago
        uint256 totalPurchases = 0;

        uint256 demandFactor = PricingMath.calculateDemandFactor(lastPurchaseTime, totalPurchases);

        // Time decay: 1000 / 3600 ≈ 0.277e18
        // purchaseFactor = 1e18
        // factor = 1e18 - (1e18 * 0.277e18) / 1e18 ≈ 0.723e18
        assertGt(demandFactor, 0.7e18, "Zero purchases should have pure time decay");
        assertLt(demandFactor, 0.75e18, "Zero purchases should decay based on time");
    }

    function test_calculateDemandFactor_LargeTimeDelta() public {
        uint256 lastPurchaseTime = block.timestamp - 86400; // 1 day ago
        uint256 totalPurchases = 10;

        uint256 demandFactor = PricingMath.calculateDemandFactor(lastPurchaseTime, totalPurchases);

        // Time decay: 86400 > 3600, so timeDecay caps at 1e18
        // purchaseFactor = 1e18 + (10 * 1e17) = 2e18
        // factor = 2e18 - (2e18 * 1e18) / 1e18 = 0
        assertEq(demandFactor, 0, "After days, demand should fully decay regardless of purchase count");
    }

    // ============================================
    // calculatePrice() Tests (8 tests)
    // ============================================

    function test_calculatePrice_ZeroUtilization() public {
        uint256 utilizationRate = 0;
        uint256 demandFactor = 1e18;
        uint256 basePrice = BASE_PRICE;

        uint256 price = PricingMath.calculatePrice(utilizationRate, demandFactor, basePrice);

        // supplyMultiplier = 1e18 + (0 / 2) = 1e18
        // demandMultiplier = 1e18 (since demandFactor = 1e18)
        // totalMultiplier = 1e18 * 1e18 / 1e18 = 1e18
        // price = BASE_PRICE * 1e18 / 1e18 = BASE_PRICE
        assertEq(price, BASE_PRICE, "Zero utilization should return base price");
    }

    function test_calculatePrice_HighUtilization() public {
        uint256 utilizationRate = 1e18; // 100% utilization
        uint256 demandFactor = 1e18;
        uint256 basePrice = BASE_PRICE;

        uint256 price = PricingMath.calculatePrice(utilizationRate, demandFactor, basePrice);

        // supplyMultiplier = 1e18 + (1e18 / 2) = 1.5e18
        // demandMultiplier = 1e18
        // totalMultiplier = 1.5e18 * 1e18 / 1e18 = 1.5e18
        // price = BASE_PRICE * 1.5e18 / 1e18 = BASE_PRICE * 1.5
        assertEq(price, BASE_PRICE * 15 / 10, "Full utilization should apply 1.5x multiplier");
    }

    function test_calculatePrice_ZeroDemand() public {
        uint256 utilizationRate = 0.5e18; // 50% utilization
        uint256 demandFactor = 0; // No demand
        uint256 basePrice = BASE_PRICE;

        uint256 price = PricingMath.calculatePrice(utilizationRate, demandFactor, basePrice);

        // supplyMultiplier = 1e18 + (0.5e18 / 2) = 1.25e18
        // demandMultiplier = 1e18 (since demandFactor < 1e18)
        // totalMultiplier = 1.25e18 * 1e18 / 1e18 = 1.25e18
        // price = BASE_PRICE * 1.25e18 / 1e18 = BASE_PRICE * 1.25
        assertEq(price, BASE_PRICE * 125 / 100, "Low demand still includes supply multiplier");
    }

    function test_calculatePrice_HighDemand() public {
        uint256 utilizationRate = 0; // No supply pressure
        uint256 demandFactor = 5e18; // High demand (5x base)
        uint256 basePrice = BASE_PRICE;

        uint256 price = PricingMath.calculatePrice(utilizationRate, demandFactor, basePrice);

        // supplyMultiplier = 1e18 + (0 / 2) = 1e18
        // demandMultiplier = 1e18 + ((5e18 - 1e18) / 10) = 1e18 + 0.4e18 = 1.4e18
        // totalMultiplier = 1e18 * 1.4e18 / 1e18 = 1.4e18
        // price = BASE_PRICE * 1.4e18 / 1e18 = BASE_PRICE * 1.4
        assertEq(price, BASE_PRICE * 14 / 10, "High demand should increase price significantly");
    }

    function test_calculatePrice_MaxMultiplier() public {
        uint256 utilizationRate = 1e18; // 100% utilization
        uint256 demandFactor = 1000e18; // Extreme demand
        uint256 basePrice = BASE_PRICE;

        uint256 price = PricingMath.calculatePrice(utilizationRate, demandFactor, basePrice);

        // supplyMultiplier = 1e18 + (1e18 / 2) = 1.5e18
        // demandMultiplier = 1e18 + ((1000e18 - 1e18) / 10) = 1e18 + 99.9e18 = 100.9e18
        // totalMultiplier = 1.5e18 * 100.9e18 / 1e18 = 151.35e18
        // But capped at MAX_PRICE_MULTIPLIER * 1e18 = 100e18
        // price = BASE_PRICE * 100e18 / 1e18 = BASE_PRICE * 100
        assertEq(price, BASE_PRICE * 100, "Price should cap at 100x base price");
    }

    function test_calculatePrice_MinMultiplier() public {
        uint256 utilizationRate = 0; // No utilization
        uint256 demandFactor = 0; // No demand
        uint256 basePrice = BASE_PRICE;

        uint256 price = PricingMath.calculatePrice(utilizationRate, demandFactor, basePrice);

        // supplyMultiplier = 1e18 + (0 / 2) = 1e18
        // demandMultiplier = 1e18 (since demandFactor < 1e18)
        // totalMultiplier = 1e18 * 1e18 / 1e18 = 1e18
        // price = BASE_PRICE * 1e18 / 1e18 = BASE_PRICE
        assertEq(price, BASE_PRICE, "Price should be at least 1x base price");
    }

    function test_calculatePrice_CompoundedMultipliers() public {
        uint256 utilizationRate = 0.8e18; // 80% utilization
        uint256 demandFactor = 3e18; // 3x demand
        uint256 basePrice = BASE_PRICE;

        uint256 price = PricingMath.calculatePrice(utilizationRate, demandFactor, basePrice);

        // supplyMultiplier = 1e18 + (0.8e18 / 2) = 1e18 + 0.4e18 = 1.4e18
        // demandMultiplier = 1e18 + ((3e18 - 1e18) / 10) = 1e18 + 0.2e18 = 1.2e18
        // totalMultiplier = 1.4e18 * 1.2e18 / 1e18 = 1.68e18
        // price = BASE_PRICE * 1.68e18 / 1e18 = BASE_PRICE * 1.68
        uint256 expectedPrice = (BASE_PRICE * 168) / 100;
        assertEq(price, expectedPrice, "Multipliers should combine multiplicatively");
    }

    function test_calculatePrice_WithRealWorldScenarios() public {
        // Typical use case: 60% utilization, 10 purchases, recent activity
        uint256 utilizationRate = 0.6e18; // 60% utilization
        uint256 demandFactor = 1.5e18; // Moderate demand from purchases
        uint256 basePrice = BASE_PRICE;

        uint256 price = PricingMath.calculatePrice(utilizationRate, demandFactor, basePrice);

        // supplyMultiplier = 1e18 + (0.6e18 / 2) = 1.3e18
        // demandMultiplier = 1e18 + ((1.5e18 - 1e18) / 10) = 1.05e18
        // totalMultiplier = 1.3e18 * 1.05e18 / 1e18 = 1.365e18
        // price = BASE_PRICE * 1.365
        assertGt(price, BASE_PRICE, "Real world scenario should increase price");
        assertLt(price, BASE_PRICE * 2, "Real world scenario should be reasonable");
    }

    // ============================================
    // calculatePriceDecay() Tests (6 tests)
    // ============================================

    function test_calculatePriceDecay_NoTimeElapsed() public {
        uint256 currentPrice = BASE_PRICE * 2;
        uint256 lastUpdateTime = block.timestamp;

        uint256 newPrice = PricingMath.calculatePriceDecay(currentPrice, lastUpdateTime);

        assertEq(newPrice, currentPrice, "No time elapsed should mean no decay");
    }

    function test_calculatePriceDecay_OneSecond() public {
        uint256 currentPrice = BASE_PRICE * 2; // 0.02 ether
        uint256 lastUpdateTime = block.timestamp - 1;

        uint256 newPrice = PricingMath.calculatePriceDecay(currentPrice, lastUpdateTime);

        // Decay amount: (0.02 ether * 1e15 * 1) / 1e18 = 0.00002 ether = 20000000000000 wei
        // New price: 0.02 ether - 20000000000000 wei
        uint256 expectedDecay = (currentPrice * PRICE_DECAY_RATE * 1) / 1e18;
        assertEq(newPrice, currentPrice - expectedDecay, "One second should decay by 0.1%");
    }

    function test_calculatePriceDecay_OneMinute() public {
        uint256 currentPrice = BASE_PRICE * 10; // 0.1 ether - use larger price to avoid underflow
        uint256 lastUpdateTime = block.timestamp - 60;

        uint256 newPrice = PricingMath.calculatePriceDecay(currentPrice, lastUpdateTime);

        // Decay amount: (0.1 ether * 1e15 * 60) / 1e18 = 0.006 ether
        // New price: 0.1 ether - 0.006 ether = 0.094 ether
        uint256 expectedDecay = (currentPrice * PRICE_DECAY_RATE * 60) / 1e18;
        assertEq(newPrice, currentPrice - expectedDecay, "60 seconds should decay by 6%");
    }

    function test_calculatePriceDecay_OneHour() public {
        uint256 currentPrice = BASE_PRICE * 100; // 1 ether - much larger to handle 1 hour decay
        uint256 lastUpdateTime = block.timestamp - 3600;

        uint256 newPrice = PricingMath.calculatePriceDecay(currentPrice, lastUpdateTime);

        // Decay amount: (1 ether * 1e15 * 3600) / 1e18 = 3.6 ether
        // Note: Decay is larger than current price, so should floor at BASE_PRICE
        uint256 expectedDecay = (currentPrice * PRICE_DECAY_RATE * 3600) / 1e18;

        // Check if decay would underflow or go below base price
        if (expectedDecay >= currentPrice || currentPrice - expectedDecay < BASE_PRICE) {
            assertEq(newPrice, BASE_PRICE, "Should floor at BASE_PRICE");
        } else {
            uint256 expectedPrice = currentPrice - expectedDecay;
            assertEq(newPrice, expectedPrice, "Should decay by calculated amount");
        }
    }

    function test_calculatePriceDecay_FloorAtBasePrice() public {
        uint256 currentPrice = BASE_PRICE * 2; // 0.02 ether
        // Calculate time that would cause full decay to BASE_PRICE
        // We need: currentPrice - (currentPrice * PRICE_DECAY_RATE * time) / 1e18 = BASE_PRICE
        // Solving: time = (currentPrice - BASE_PRICE) * 1e18 / (currentPrice * PRICE_DECAY_RATE)
        uint256 timeForFullDecay = ((currentPrice - BASE_PRICE) * 1e18) / (currentPrice * PRICE_DECAY_RATE);
        uint256 lastUpdateTime = block.timestamp - timeForFullDecay - 1000; // Add extra to ensure we floor

        uint256 newPrice = PricingMath.calculatePriceDecay(currentPrice, lastUpdateTime);

        // Decay would be massive, but should floor at BASE_PRICE
        assertEq(newPrice, BASE_PRICE, "Price should never go below BASE_PRICE");
    }

    function test_calculatePriceDecay_LargeTimeElapsed() public {
        uint256 currentPrice = BASE_PRICE * 100; // 1 ether
        uint256 lastUpdateTime = block.timestamp - 86400; // 1 day

        uint256 newPrice = PricingMath.calculatePriceDecay(currentPrice, lastUpdateTime);

        // Decay amount: (1 ether * 1e15 * 86400) / 1e18 = 0.0864 ether = 8.64 * BASE_PRICE
        // New price: 1 ether - 0.0864 ether = 0.9136 ether = 91.36 * BASE_PRICE
        uint256 expectedDecay = (currentPrice * PRICE_DECAY_RATE * 86400) / 1e18;
        uint256 expectedPrice = currentPrice > expectedDecay ? currentPrice - expectedDecay : BASE_PRICE;

        if (expectedPrice < BASE_PRICE) {
            assertEq(newPrice, BASE_PRICE, "Should floor at BASE_PRICE after long decay");
        } else {
            assertEq(newPrice, expectedPrice, "Should decay significantly over days");
            assertLt(newPrice, currentPrice, "Price should decrease");
        }
    }

    // ============================================
    // Edge Cases & Integration Tests (11 tests)
    // ============================================

    function test_calculatePrice_WithMaxValues() public {
        uint256 utilizationRate = 1e18; // Max utilization
        uint256 demandFactor = 1000e18; // Extreme demand
        uint256 basePrice = 1 ether; // High base price

        uint256 price = PricingMath.calculatePrice(utilizationRate, demandFactor, basePrice);

        // Should cap at MAX_PRICE_MULTIPLIER
        assertEq(price, basePrice * MAX_PRICE_MULTIPLIER, "Should cap at max multiplier");
        assertLe(price, basePrice * MAX_PRICE_MULTIPLIER, "Should never exceed max multiplier");
    }

    function test_calculatePrice_WithMinValues() public {
        uint256 utilizationRate = 0; // Min utilization
        uint256 demandFactor = 0; // Min demand
        uint256 basePrice = 0.001 ether; // Low base price

        uint256 price = PricingMath.calculatePrice(utilizationRate, demandFactor, basePrice);

        // Should be at least MIN_PRICE_MULTIPLIER * basePrice
        assertEq(price, basePrice * MIN_PRICE_MULTIPLIER, "Should be at min multiplier");
        assertGe(price, basePrice * MIN_PRICE_MULTIPLIER, "Should never be below min multiplier");
    }

    function test_PricingFlow_SupplyIncreaseThenDecay() public {
        uint256 basePrice = BASE_PRICE;

        // Step 1: High utilization increases price
        uint256 utilizationRate = 0.9e18; // 90% utilization
        uint256 demandFactor = 1e18;
        uint256 currentPrice = PricingMath.calculatePrice(utilizationRate, demandFactor, basePrice);

        // supplyMultiplier = 1e18 + (0.9e18 / 2) = 1.45e18
        // price = basePrice * 1.45
        assertGt(currentPrice, basePrice, "High utilization should increase price");

        // Step 2: Price decays over time (1 minute) - use shorter time to avoid underflow
        vm.warp(block.timestamp + 60);
        uint256 decayedPrice = PricingMath.calculatePriceDecay(currentPrice, block.timestamp - 60);

        assertLt(decayedPrice, currentPrice, "Price should decay over time");
        assertGe(decayedPrice, basePrice, "Price should not go below base price");
    }

    function test_PricingFlow_DemandThenDecay() public {
        uint256 currentTime = block.timestamp;

        // Stage 1: High demand from recent purchases
        uint256 lastPurchaseTime = currentTime - 10; // Very recent
        uint256 totalPurchases = 20; // Many purchases
        uint256 demandFactor1 = PricingMath.calculateDemandFactor(lastPurchaseTime, totalPurchases);

        assertGt(demandFactor1, 1e18, "High purchases should increase demand");

        // Stage 2: Demand decays after 30 minutes
        vm.warp(currentTime + 1800);
        uint256 demandFactor2 = PricingMath.calculateDemandFactor(lastPurchaseTime, totalPurchases);

        assertLt(demandFactor2, demandFactor1, "Demand should decay over time");

        // Stage 3: Demand fully decays after 1 hour
        vm.warp(currentTime + 3600);
        uint256 demandFactor3 = PricingMath.calculateDemandFactor(lastPurchaseTime, totalPurchases);

        assertEq(demandFactor3, 0, "Demand should fully decay after decay time");
    }

    function test_calculateUtilizationRate_PrecisionEdgeCases() public {
        // Test with very small values
        uint256 rate1 = PricingMath.calculateUtilizationRate(1, 1000);
        assertEq(rate1, 1e18 / 1000, "Should handle small fractions");

        // Test with very large values
        uint256 rate2 = PricingMath.calculateUtilizationRate(1e18, 1e19);
        assertEq(rate2, 1e17, "Should handle large values");

        // Test exact fractions
        uint256 rate3 = PricingMath.calculateUtilizationRate(1, 3);
        uint256 expected = 333333333333333333; // 1e18 / 3
        assertEq(rate3, expected, "Should handle division with remainders");
    }

    function test_calculateDemandFactor_TimeBoundaries() public {
        uint256 currentTime = block.timestamp;
        uint256 totalPurchases = 5;

        // Exactly at 1 hour boundary
        uint256 lastPurchaseTime = currentTime - DEMAND_DECAY_TIME;
        uint256 demandFactor = PricingMath.calculateDemandFactor(lastPurchaseTime, totalPurchases);

        assertEq(demandFactor, 0, "At exactly decay time boundary, demand should be 0");

        // Just before 1 hour
        lastPurchaseTime = currentTime - (DEMAND_DECAY_TIME - 1);
        demandFactor = PricingMath.calculateDemandFactor(lastPurchaseTime, totalPurchases);

        assertGt(demandFactor, 0, "Just before decay time, demand should be positive");
        assertLt(demandFactor, 1e17, "Just before decay time, demand should be very low");
    }

    function test_calculatePrice_MultiplicativeNotAdditive() public {
        uint256 utilizationRate = 0.5e18; // 50%
        uint256 demandFactor = 2e18; // 2x
        uint256 basePrice = BASE_PRICE;

        // supplyMultiplier = 1e18 + (0.5e18 / 2) = 1.25e18
        // demandMultiplier = 1e18 + ((2e18 - 1e18) / 10) = 1.1e18
        // totalMultiplier = 1.25e18 * 1.1e18 / 1e18 = 1.375e18 (multiplicative)
        // If additive: 1.25e18 + 0.1e18 = 1.35e18 (different)

        uint256 price = PricingMath.calculatePrice(utilizationRate, demandFactor, basePrice);
        uint256 expectedPrice = (basePrice * 1375) / 1000; // 1.375x

        assertEq(price, expectedPrice, "Multipliers should combine multiplicatively");
    }

    function test_PriceDecay_Monotonic() public {
        uint256 currentPrice = BASE_PRICE * 10;
        uint256 lastUpdateTime = block.timestamp;

        uint256 price0 = PricingMath.calculatePriceDecay(currentPrice, lastUpdateTime);

        vm.warp(block.timestamp + 100);
        uint256 price1 = PricingMath.calculatePriceDecay(currentPrice, lastUpdateTime);

        vm.warp(block.timestamp + 100);
        uint256 price2 = PricingMath.calculatePriceDecay(currentPrice, lastUpdateTime);

        vm.warp(block.timestamp + 100);
        uint256 price3 = PricingMath.calculatePriceDecay(currentPrice, lastUpdateTime);

        // Prices should be monotonically decreasing
        assertEq(price0, currentPrice, "No time elapsed, no decay");
        assertLe(price1, price0, "Price should decrease or stay same");
        assertLe(price2, price1, "Price should decrease or stay same");
        assertLe(price3, price2, "Price should decrease or stay same");
        assertGe(price3, BASE_PRICE, "Price should not go below base");
    }

    function test_calculatePrice_WithDifferentBasePrices() public {
        uint256 utilizationRate = 0.5e18;
        uint256 demandFactor = 1.5e18;

        uint256 price1 = PricingMath.calculatePrice(utilizationRate, demandFactor, BASE_PRICE);
        uint256 price2 = PricingMath.calculatePrice(utilizationRate, demandFactor, BASE_PRICE * 2);
        uint256 price3 = PricingMath.calculatePrice(utilizationRate, demandFactor, BASE_PRICE * 10);

        // All prices should have same multiplier ratio
        assertEq(price2, price1 * 2, "Double base price should double final price");
        assertEq(price3, price1 * 10, "10x base price should 10x final price");
    }

    function test_Integration_FullPricingCycle() public {
        uint256 basePrice = BASE_PRICE;
        uint256 currentTime = block.timestamp;

        // Stage 1: Initial state - low utilization, no demand
        uint256 occupied = 10;
        uint256 total = 100;
        uint256 utilizationRate = PricingMath.calculateUtilizationRate(occupied, total);
        uint256 lastPurchaseTime = currentTime - 7200; // 2 hours ago
        uint256 totalPurchases = 0;
        uint256 demandFactor = PricingMath.calculateDemandFactor(lastPurchaseTime, totalPurchases);
        uint256 price = PricingMath.calculatePrice(utilizationRate, demandFactor, basePrice);

        assertLt(price, basePrice * 2, "Initial price should be modest");

        // Stage 2: Purchases increase demand
        vm.warp(currentTime + 100);
        lastPurchaseTime = block.timestamp - 5; // Recent purchase
        totalPurchases = 10;
        demandFactor = PricingMath.calculateDemandFactor(lastPurchaseTime, totalPurchases);
        uint256 price2 = PricingMath.calculatePrice(utilizationRate, demandFactor, basePrice);

        assertGt(price2, price, "Purchases should increase price");

        // Stage 3: Supply increases (higher utilization)
        occupied = 80;
        utilizationRate = PricingMath.calculateUtilizationRate(occupied, total);
        uint256 price3 = PricingMath.calculatePrice(utilizationRate, demandFactor, basePrice);

        assertGt(price3, price2, "Higher utilization should increase price");

        // Stage 4: Time passes, demand decays (use shorter time to avoid full decay in later price decay)
        vm.warp(block.timestamp + 1800); // 30 minutes instead of 2 hours
        demandFactor = PricingMath.calculateDemandFactor(lastPurchaseTime, totalPurchases);
        uint256 price4 = PricingMath.calculatePrice(utilizationRate, demandFactor, basePrice);
        uint256 decayedPrice = PricingMath.calculatePriceDecay(price3, block.timestamp - 1800);

        assertLt(price4, price3, "Demand decay should reduce calculated price");
        assertLt(decayedPrice, price3, "Time decay should reduce actual price");
    }

    function test_calculateUtilizationRate_OverOccupancy() public {
        // Edge case: What if occupied > total? (shouldn't happen but test robustness)
        uint256 occupied = 150;
        uint256 total = 100;

        uint256 rate = PricingMath.calculateUtilizationRate(occupied, total);

        // Should return > 1e18 (over 100%)
        assertGt(rate, 1e18, "Over-occupancy should return > 100%");
        assertEq(rate, 1.5e18, "150/100 should be 1.5e18");
    }

    function test_calculateDemandFactor_WithManyPurchases() public {
        uint256 lastPurchaseTime = block.timestamp - 100; // Recent
        uint256 totalPurchases = 50; // Many purchases

        uint256 demandFactor = PricingMath.calculateDemandFactor(lastPurchaseTime, totalPurchases);

        // purchaseFactor = 1e18 + (50 * 1e17) = 6e18
        // Even with recent time, factor should be high
        assertGt(demandFactor, 5e18, "Many purchases should create high demand");
    }
}
