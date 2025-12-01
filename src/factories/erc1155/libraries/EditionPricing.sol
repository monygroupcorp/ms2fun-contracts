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
        if (minted == 0) {
            return basePrice;
        }

        if (priceIncreaseRate == 0) {
            return basePrice;
        }

        // Calculate: (1 + increaseRate/10000) ^ minted
        // Convert multiplier to WAD: (10000 + rate) / 10000 = 1 + rate/10000
        // In WAD: (1e18 * (10000 + rate)) / 10000 = 1e18 + (rate * 1e14)
        uint256 multiplierWad = 1e18 + (priceIncreaseRate * 1e14); // e.g., 1.01e18 for 1% increase
        
        // Start with 1.0 in WAD format
        uint256 result = 1e18;
        
        // Calculate multiplier ^ minted using repeated multiplication
        // This is gas-intensive for large minted values, but practical for most use cases
        // For very large minted values, consider using logarithms or lookup tables
        for (uint256 i = 0; i < minted; i++) {
            result = result.mulWad(multiplierWad);
        }
        
        // Multiply base price by the result
        // Result is already in WAD format, so mulWad handles it correctly
        currentPrice = basePrice.mulWad(result);
        
        // Ensure price doesn't underflow
        require(currentPrice >= basePrice, "Price calculation error");
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
            // Fixed price: simple multiplication
            return basePrice * amount;
        }

        // Calculate cost for each token in the batch
        for (uint256 i = 0; i < amount; i++) {
            totalCost += calculateDynamicPrice(basePrice, priceIncreaseRate, startMinted + i);
        }
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

