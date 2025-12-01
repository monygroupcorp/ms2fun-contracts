// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";

/**
 * @title BondingCurveMath
 * @notice Library for calculating bonding curve costs and refunds
 * @dev Uses configurable polynomial formula: P(s) = quarticCoeff * S^4 + cubicCoeff * S^3 + quadraticCoeff * S^2 + initialPrice
 */
library BondingCurveMath {
    using FixedPointMathLib for uint256;

    /**
     * @notice Bonding curve parameters
     * @param initialPrice Base price (e.g., 0.025 ether)
     * @param quarticCoeff Coefficient for S^4 term (e.g., 12e-9 equivalent)
     * @param cubicCoeff Coefficient for S^3 term (e.g., 4e-9 equivalent)
     * @param quadraticCoeff Coefficient for S^2 term (e.g., 4e-9 equivalent)
     * @param normalizationFactor Supply normalization factor (e.g., 10M tokens = 1e7)
     */
    struct Params {
        uint256 initialPrice;
        uint256 quarticCoeff;
        uint256 cubicCoeff;
        uint256 quadraticCoeff;
        uint256 normalizationFactor;
    }

    /**
     * @notice Calculates the integral of the bonding curve price function
     * @dev Uses numerical integration to find the area under the price curve
     * @param params Bonding curve parameters
     * @param lowerBound The lower bound of the supply range to integrate
     * @param upperBound The upper bound of the supply range to integrate
     * @return integral The calculated integral value in ETH
     */
    function calculateIntegral(
        Params memory params,
        uint256 lowerBound,
        uint256 upperBound
    ) internal pure returns (uint256) {
        require(upperBound >= lowerBound, "Invalid bounds");
        return _calculateIntegralFromZero(params, upperBound) - _calculateIntegralFromZero(params, lowerBound);
    }

    /**
     * @notice Calculates the integral of the bonding curve price function from zero to a given supply
     * @dev Uses numerical integration to find the area under the price curve
     * @param params Bonding curve parameters
     * @param supply The upper bound of the supply range to integrate
     * @return integral The calculated integral value in ETH
     */
    function _calculateIntegralFromZero(
        Params memory params,
        uint256 supply
    ) private pure returns (uint256) {
        // Scale down by normalization factor (same as CULTEXEC404)
        uint256 scaledSupplyWad = supply / params.normalizationFactor;
        
        // Base price integral (dewadded by 1e18)
        uint256 basePart = params.initialPrice.mulWad(scaledSupplyWad);
        
        // Calculate integral terms matching CULTEXEC404 formula exactly
        // Original uses: 3 gwei * S^4, 1333333333 * S^3, 2 gwei * S^2
        // Coefficients are pre-adjusted for integration (12/4, 4/3, 4/2)
        
        // Quartic term: coeff * S^4 (coeff should be like 3 gwei = 12/4 * 1 gwei)
        uint256 quarticTerm = params.quarticCoeff.mulWad(
            scaledSupplyWad.mulWad(
                scaledSupplyWad.mulWad(
                    scaledSupplyWad.mulWad(scaledSupplyWad)
                )
            )
        );

        // Cubic term: coeff * S^3 (coeff should be like 1333333333 = 4/3 * 1 gwei)
        uint256 cubicTerm = params.cubicCoeff.mulWad(
            scaledSupplyWad.mulWad(
                scaledSupplyWad.mulWad(scaledSupplyWad)
            )
        );
        
        // Quadratic term: coeff * S^2 (coeff should be like 2 gwei = 4/2 * 1 gwei)
        uint256 quadraticTerm = params.quadraticCoeff.mulWad(
            scaledSupplyWad.mulWad(scaledSupplyWad)
        );
        
        return basePart + quarticTerm + cubicTerm + quadraticTerm;
    }

    /**
     * @notice Calculates the cost to buy a given amount of tokens
     * @param params Bonding curve parameters
     * @param currentSupply Current total bonding supply
     * @param amount Amount of tokens to buy
     * @return cost The ETH cost to buy the tokens
     */
    function calculateCost(
        Params memory params,
        uint256 currentSupply,
        uint256 amount
    ) internal pure returns (uint256) {
        return calculateIntegral(params, currentSupply, currentSupply + amount);
    }

    /**
     * @notice Calculates the refund for selling a given amount of tokens
     * @param params Bonding curve parameters
     * @param currentSupply Current total bonding supply
     * @param amount Amount of tokens to sell
     * @return refund The ETH refund for selling the tokens
     */
    function calculateRefund(
        Params memory params,
        uint256 currentSupply,
        uint256 amount
    ) internal pure returns (uint256) {
        require(amount <= currentSupply, "Amount exceeds supply");
        return calculateIntegral(params, currentSupply - amount, currentSupply);
    }
}

