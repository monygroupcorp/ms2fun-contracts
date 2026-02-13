// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IFactory
/// @notice Minimal interface every factory must implement.
///         MasterRegistry verifies creator() and protocol() at registration time.
///         Revenue split mechanics are factory-specific — governance verifies during approval.
interface IFactory {
    /// @notice Returns the creator address (the dev who built this factory)
    /// @return The factory creator who receives creator fee share
    function creator() external view returns (address);

    /// @notice Returns the protocol authority address
    /// @return The protocol role with administrative control
    function protocol() external view returns (address);
}
