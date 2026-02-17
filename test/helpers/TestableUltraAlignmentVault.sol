// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UltraAlignmentVault} from "../../src/vaults/UltraAlignmentVault.sol";

/// @notice Test-only vault that overrides swap/LP with mock behavior.
/// @dev Mirrors the mock stubs that were removed from production code.
contract TestableUltraAlignmentVault is UltraAlignmentVault {
    constructor(
        address _weth,
        address _poolManager,
        address _v3Router,
        address _v2Router,
        address _v2Factory,
        address _v3Factory,
        address _alignmentToken,
        address _factoryCreator,
        uint256 _creatorYieldCutBps
    )
        UltraAlignmentVault(
            _weth,
            _poolManager,
            _v3Router,
            _v2Router,
            _v2Factory,
            _v3Factory,
            _alignmentToken,
            _factoryCreator,
            _creatorYieldCutBps
        )
    {}

    function _swapETHForTarget(uint256 ethAmount, uint256 minOutTarget)
        internal
        override
        returns (uint256 tokenReceived)
    {
        // Simulate swap with 0.3% slippage (same as removed stub)
        tokenReceived = (ethAmount * 997) / 1000;
        require(tokenReceived >= minOutTarget, "Slippage too high");
    }

    /// @notice Simulate protocol fee accrual for testing withdrawProtocolFees happy path
    function simulateProtocolFeeAccrual(uint256 amount) external payable {
        require(msg.value == amount, "Must send exact ETH");
        accumulatedProtocolFees += amount;
    }

    function _addToLpPosition(
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper
    ) internal override returns (uint128 liquidityUnits) {
        require(amount0 > 0 && amount1 > 0, "Amounts must be positive");
        lastTickLower = tickLower;
        lastTickUpper = tickUpper;
        liquidityUnits = uint128((amount0 + amount1) / 2);
    }
}
