// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/**
 * @title EditionPricing
 * @notice Library for calculating edition prices
 * @dev Supports fixed and dynamic/exponential pricing models
 */
library EditionPricing {
    using FixedPointMathLib for uint256;

    error PriceCalculationError();

    /**
     * @notice Calculate current price for dynamic pricing model
     * @dev Uses exponential formula: currentPrice = basePrice * (1 + increaseRate/10000) ^ minted
     * @param basePrice Base price of the edition
     * @param priceIncreaseRate Price increase rate in basis points (e.g., 100 = 1%)
     * @param minted Number of tokens already minted
     * @return currentPrice Current price for the next mint
     */
    function calculateDynamicPrice(
        uint256 basePrice,
        uint256 priceIncreaseRate,
        uint256 minted
    ) internal pure returns (uint256 currentPrice) {
        if (minted == 0 || priceIncreaseRate == 0) {
            return basePrice;
        }

        // Calculate: basePrice * ((10000 + rate) / 10000) ^ minted
        // Using rpow with base 1e18 for O(log n) exponentiation instead of O(n) loop
        uint256 multiplierWad = 1e18 + (priceIncreaseRate * 1e14); // e.g., 1.01e18 for 1%
        uint256 result = FixedPointMathLib.rpow(multiplierWad, minted, 1e18);

        currentPrice = basePrice.mulWad(result);

        if (currentPrice < basePrice) revert PriceCalculationError();
    }

    /**
     * @notice Calculate total cost for minting multiple tokens with dynamic pricing
     * @dev Sums up prices for each token in the batch
     * @param basePrice Base price of the edition
     * @param priceIncreaseRate Price increase rate in basis points
     * @param startMinted Number of tokens already minted before this batch
     * @param amount Number of tokens to mint in this batch
     * @return totalCost Total cost for minting the batch
     */
    function calculateBatchCost(
        uint256 basePrice,
        uint256 priceIncreaseRate,
        uint256 startMinted,
        uint256 amount
    ) internal pure returns (uint256 totalCost) {
        if (priceIncreaseRate == 0) {
            return basePrice * amount;
        }

        // Geometric series: sum = basePrice * r^start * (r^amount - 1) / (r - 1)
        // where r = (10000 + rate) / 10000 in WAD
        uint256 r = 1e18 + (priceIncreaseRate * 1e14);
        uint256 rStart = FixedPointMathLib.rpow(r, startMinted, 1e18); // r^start
        uint256 rAmount = FixedPointMathLib.rpow(r, amount, 1e18); // r^amount

        // sum = basePrice * rStart * (rAmount - 1) / (r - 1)
        uint256 numerator = basePrice.mulWad(rStart).mulWad(rAmount - 1e18);
        totalCost = numerator.divWad(r - 1e18);
    }

    /**
     * @notice Get price for a specific mint index
     * @param basePrice Base price of the edition
     * @param priceIncreaseRate Price increase rate in basis points
     * @param mintIndex The index of the mint (0-based)
     * @return price Price for that specific mint
     */
    function getPriceAtMintIndex(
        uint256 basePrice,
        uint256 priceIncreaseRate,
        uint256 mintIndex
    ) internal pure returns (uint256 price) {
        return calculateDynamicPrice(basePrice, priceIncreaseRate, mintIndex);
    }
}

