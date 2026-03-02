// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BondingCurveMath} from "../factories/erc404/libraries/BondingCurveMath.sol";

/// @notice Interface for bonding curve parameter computers.
///         Implementations are registered in ComponentRegistry under keccak256("curve").
///         Called once at instance creation time — address is NOT stored on the instance.
interface ICurveComputer {
    /// @notice Compute bonding curve parameters from graduation preset inputs.
    function computeCurveParams(
        uint256 nftCount,
        uint256 targetETH,
        uint256 unitPerNFT,
        uint256 liquidityReserveBps
    ) external view returns (BondingCurveMath.Params memory);
}
