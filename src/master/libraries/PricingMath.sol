// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title PricingMath
 * @notice Library for dynamic pricing calculations
 */
library PricingMath {
    uint256 public constant PRICE_DECAY_RATE = 1e15; // 0.1% per second
    uint256 public constant DEMAND_DECAY_TIME = 3600; // 1 hour
    uint256 public constant BASE_PRICE = 0.01 ether;
    uint256 public constant MAX_PRICE_MULTIPLIER = 100; // 100x base price
    uint256 public constant MIN_PRICE_MULTIPLIER = 1; // 1x base price

    /**
     * @notice Calculate utilization rate (0-1e18 scale)
     * @param occupied Number of occupied spots
     * @param total Total available spots
     */
    function calculateUtilizationRate(
        uint256 occupied,
        uint256 total
    ) internal pure returns (uint256) {
        if (total == 0) return 0;
        return (occupied * 1e18) / total;
    }

    /**
     * @notice Calculate demand factor based on recent purchases
     * @param lastPurchaseTime Timestamp of last purchase
     * @param totalPurchases Total number of purchases
     */
    function calculateDemandFactor(
        uint256 lastPurchaseTime,
        uint256 totalPurchases
    ) internal view returns (uint256) {
        uint256 timeSinceLastPurchase = block.timestamp > lastPurchaseTime
            ? block.timestamp - lastPurchaseTime
            : 0;

        // Demand decays over time
        uint256 timeDecay = timeSinceLastPurchase > DEMAND_DECAY_TIME
            ? 1e18
            : (timeSinceLastPurchase * 1e18) / DEMAND_DECAY_TIME;

        // Base demand factor from purchase count
        uint256 purchaseFactor = totalPurchases > 0
            ? 1e18 + (totalPurchases * 1e17) // +0.1 per purchase, capped
            : 1e18;

        // Apply time decay
        return purchaseFactor - (purchaseFactor * timeDecay) / 1e18;
    }

    /**
     * @notice Calculate current price based on supply and demand
     * @param utilizationRate Utilization rate (0-1e18)
     * @param demandFactor Demand factor (1e18+)
     * @param basePrice Base price for the tier
     */
    function calculatePrice(
        uint256 utilizationRate,
        uint256 demandFactor,
        uint256 basePrice
    ) internal pure returns (uint256) {
        // Supply component: price increases with utilization
        uint256 supplyMultiplier = 1e18 + (utilizationRate / 2); // Max 1.5x from supply

        // Demand component: price increases with demand
        uint256 demandMultiplier = demandFactor > 1e18
            ? 1e18 + ((demandFactor - 1e18) / 10) // Max additional multiplier from demand
            : 1e18;

        // Combined multiplier
        uint256 totalMultiplier = (supplyMultiplier * demandMultiplier) / 1e18;

        // Apply bounds
        if (totalMultiplier > MAX_PRICE_MULTIPLIER * 1e18) {
            totalMultiplier = MAX_PRICE_MULTIPLIER * 1e18;
        }
        if (totalMultiplier < MIN_PRICE_MULTIPLIER * 1e18) {
            totalMultiplier = MIN_PRICE_MULTIPLIER * 1e18;
        }

        return (basePrice * totalMultiplier) / 1e18;
    }

    /**
     * @notice Calculate price decay over time
     * @param currentPrice Current price
     * @param lastUpdateTime Last update timestamp
     */
    function calculatePriceDecay(
        uint256 currentPrice,
        uint256 lastUpdateTime
    ) internal view returns (uint256) {
        uint256 timeElapsed = block.timestamp > lastUpdateTime
            ? block.timestamp - lastUpdateTime
            : 0;

        uint256 decayAmount = (currentPrice * PRICE_DECAY_RATE * timeElapsed) / 1e18;

        // Don't decay below base price
        uint256 basePrice = BASE_PRICE;
        // Check if decay would go below base price (avoiding underflow)
        if (decayAmount >= currentPrice || currentPrice - decayAmount < basePrice) {
            return basePrice;
        }

        return currentPrice - decayAmount;
    }
}

