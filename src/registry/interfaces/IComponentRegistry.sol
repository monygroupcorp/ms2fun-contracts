// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Protocol-level registry for DAO-approved, user-selectable singleton contracts.
/// @dev Factories consult this at instance creation time to validate component selections.
///      Components are registered with an opaque tag (e.g. keccak256("gating")) for off-chain
///      filtering and a human-readable name for frontend display.
///      Type semantics live in factories and interfaces — the registry is type-agnostic.
interface IComponentRegistry {
    event ComponentApproved(address indexed component, bytes32 indexed tag, string name);
    event ComponentRevoked(address indexed component);

    // ── DAO-only mutations ─────────────────────────────────────────────────────

    /// @notice Approve a component for factory use.
    /// @param component The contract address to whitelist.
    /// @param tag       Opaque category tag, e.g. keccak256("gating").
    /// @param name      Human-readable label for frontends.
    function approveComponent(address component, bytes32 tag, string calldata name) external;

    /// @notice Revoke a previously approved component. Does not affect existing deployed instances.
    function revokeComponent(address component) external;

    // ── Factory validation ─────────────────────────────────────────────────────

    /// @notice Returns true if the component is currently approved.
    function isApprovedComponent(address component) external view returns (bool);

    // ── Frontend enumeration ──────────────────────────────────────────────────

    /// @notice Returns all currently approved component addresses.
    function getApprovedComponents() external view returns (address[] memory);

    /// @notice Returns all currently approved components matching the given tag.
    function getApprovedComponentsByTag(bytes32 tag) external view returns (address[] memory);
}
