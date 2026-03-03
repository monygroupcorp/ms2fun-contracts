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

    /// @notice Returns the component tag categories this factory supports.
    ///         Each bytes32 is a keccak256 tag matching a ComponentRegistry category
    ///         (e.g. keccak256("gating"), keccak256("agent")).
    ///         The frontend intersects this list with ComponentRegistry to build wizard steps.
    /// @return Array of supported component tag hashes (may be empty)
    function features() external view returns (bytes32[] memory);

    /// @notice Returns which features are mandatory (no address(0) allowed).
    ///         Subset of features(). Frontend hides "None" option for these tags.
    /// @return Array of required component tag hashes (may be empty)
    function requiredFeatures() external view returns (bytes32[] memory);
}
