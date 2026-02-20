// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "solady/auth/Ownable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {BondingCurveMath} from "./libraries/BondingCurveMath.sol";

/**
 * @title CurveParamsComputer
 * @notice Computes bonding curve parameters from a graduation profile and NFT count
 * @dev Extracted from ERC404Factory to reduce bytecode size. Owns all curve weight state and computation.
 *      The factory looks up the profile and passes it in; this contract has no storage dependency on the factory.
 */
contract CurveParamsComputer is Ownable {
    using FixedPointMathLib for uint256;

    // Reference curve shape weights (protocol-configurable)
    uint256 public quarticWeight = 3 gwei;
    uint256 public cubicWeight = 1333333333;
    uint256 public quadraticWeight = 2 gwei;
    uint256 public baseWeight = 0.025 ether;

    event CurveWeightsUpdated();

    constructor(address _protocol) {
        require(_protocol != address(0), "Invalid protocol");
        _initializeOwner(_protocol);
    }

    /**
     * @notice Update curve shape weights (owner only)
     */
    function setCurveWeights(
        uint256 _quarticWeight,
        uint256 _cubicWeight,
        uint256 _quadraticWeight,
        uint256 _baseWeight
    ) external onlyOwner {
        quarticWeight = _quarticWeight;
        cubicWeight = _cubicWeight;
        quadraticWeight = _quadraticWeight;
        baseWeight = _baseWeight;
        emit CurveWeightsUpdated();
    }

    /**
     * @notice Calculate cost to buy `amount` tokens given current supply
     */
    function calculateCost(
        BondingCurveMath.Params calldata params,
        uint256 currentSupply,
        uint256 amount
    ) external pure returns (uint256) {
        return BondingCurveMath.calculateCost(params, currentSupply, amount);
    }

    /**
     * @notice Calculate refund for selling `amount` tokens given current supply
     */
    function calculateRefund(
        BondingCurveMath.Params calldata params,
        uint256 currentSupply,
        uint256 amount
    ) external pure returns (uint256) {
        return BondingCurveMath.calculateRefund(params, currentSupply, amount);
    }

    /**
     * @notice Compute bonding curve parameters from profile data and NFT count
     * @dev Fixed shape, scaled amplitude. Computes normalizationFactor dynamically
     *      to keep math in safe uint256 range, then scales coefficients to hit targetETH.
     * @param nftCount Number of NFTs in the collection
     * @param targetETH Target ETH to raise through the bonding curve
     * @param unitPerNFT Token units per NFT (e.g. 1e6 means 1M tokens/NFT)
     * @param liquidityReserveBps Bps of total supply reserved for liquidity (e.g. 2000 = 20%)
     * @return params Computed BondingCurveMath.Params
     */
    function computeCurveParams(
        uint256 nftCount,
        uint256 targetETH,
        uint256 unitPerNFT,
        uint256 liquidityReserveBps
    ) public view returns (BondingCurveMath.Params memory params) {
        uint256 totalSupply = nftCount * unitPerNFT * 1e18;
        uint256 liquidityReserve = (totalSupply * liquidityReserveBps) / 10000;
        uint256 maxBondingSupply = totalSupply - liquidityReserve;

        // Compute normalization factor: scale supply down to ~1-1000 range for safe math
        uint256 normFactor = maxBondingSupply / 1e18;
        if (normFactor == 0) normFactor = 1;

        // Compute reference integral with unit weights
        BondingCurveMath.Params memory refParams = BondingCurveMath.Params({
            initialPrice: baseWeight,
            quarticCoeff: quarticWeight,
            cubicCoeff: cubicWeight,
            quadraticCoeff: quadraticWeight,
            normalizationFactor: normFactor
        });

        uint256 referenceArea = BondingCurveMath.calculateCost(refParams, 0, maxBondingSupply);
        require(referenceArea > 0, "Reference area is zero");

        // Scale factor: targetETH / referenceArea (in wad)
        uint256 scaleFactor = targetETH.divWad(referenceArea);

        // Apply scale to each coefficient
        params = BondingCurveMath.Params({
            initialPrice: baseWeight.mulWad(scaleFactor),
            quarticCoeff: quarticWeight.mulWad(scaleFactor),
            cubicCoeff: cubicWeight.mulWad(scaleFactor),
            quadraticCoeff: quadraticWeight.mulWad(scaleFactor),
            normalizationFactor: normFactor
        });
    }
}
