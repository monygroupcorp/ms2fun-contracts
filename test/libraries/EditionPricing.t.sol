// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EditionPricing} from "../../src/factories/erc1155/libraries/EditionPricing.sol";

contract EditionPricingTest is Test {
    /// @notice Price must be non-decreasing as minted increases when rate > 0
    function testFuzz_DynamicPriceMonotonic(
        uint256 basePrice,
        uint256 rate,
        uint256 mintedA,
        uint256 mintedB
    ) public pure {
        basePrice = bound(basePrice, 0.001 ether, 1 ether);
        rate = bound(rate, 1, 500); // 0.01% to 5%
        mintedA = bound(mintedA, 0, 499);
        mintedB = bound(mintedB, mintedA + 1, 500);

        uint256 priceA = EditionPricing.calculateDynamicPrice(basePrice, rate, mintedA);
        uint256 priceB = EditionPricing.calculateDynamicPrice(basePrice, rate, mintedB);

        assertGe(priceB, priceA, "price must not decrease as minted increases");
    }

    /// @notice Batch cost must equal the sum of individual prices
    function testFuzz_BatchCostEqualsIndividualSum(
        uint256 basePrice,
        uint256 rate,
        uint256 startMinted,
        uint256 n
    ) public pure {
        basePrice = bound(basePrice, 0.001 ether, 1 ether);
        rate = bound(rate, 1, 300); // up to 3%
        startMinted = bound(startMinted, 0, 200);
        n = bound(n, 1, 20);

        uint256 batchCost = EditionPricing.calculateBatchCost(basePrice, rate, startMinted, n);

        uint256 individualSum;
        for (uint256 i; i < n; i++) {
            individualSum += EditionPricing.calculateDynamicPrice(basePrice, rate, startMinted + i);
        }

        // Allow 1% relative tolerance for rounding between geometric series and iterative sum
        assertApproxEqRel(batchCost, individualSum, 0.01e18, "batch cost must approximate individual sum");
    }

    /// @notice When rate is zero, price is always basePrice regardless of minted
    function testFuzz_ZeroRateConstantPrice(
        uint128 basePrice,
        uint32 minted
    ) public pure {
        vm.assume(basePrice > 0);

        uint256 price = EditionPricing.calculateDynamicPrice(basePrice, 0, minted);
        assertEq(price, basePrice, "zero rate must yield constant basePrice");
    }
}
