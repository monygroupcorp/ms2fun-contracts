// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IFactory
/// @notice Minimal interface every factory must implement.
///         MasterRegistry verifies protocol() at registration time.
///         Revenue split mechanics are factory-specific — governance verifies during approval.
interface IFactory {
    /// @notice Returns the protocol authority address
    /// @return The protocol role with administrative control
    function protocol() external view returns (address);
}
