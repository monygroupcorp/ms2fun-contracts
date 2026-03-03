// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title RevenueSplitLib
/// @notice Canonical 1/19/80 revenue split used across all instance types.
library RevenueSplitLib {
    struct Split {
        uint256 protocolCut; // 1%
        uint256 vaultCut;    // 19%
        uint256 remainder;   // ~80%
    }

    /// @notice Compute the 1/19/80 split for a given amount.
    /// @dev Protocol = amount / 100 (floor), vault = amount * 19 / 100 (floor),
    ///      remainder = amount - protocol - vault (absorbs rounding dust).
    function split(uint256 amount) internal pure returns (Split memory s) {
        s.protocolCut = amount / 100;
        s.vaultCut = (amount * 19) / 100;
        s.remainder = amount - s.protocolCut - s.vaultCut;
    }
}
