// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Pluggable gating interface for ERC404 bonding instances.
/// address(0) means open gating — no module deployed.
interface IGatingModule {
    /// @notice Returns true if `user` is allowed to mint `amount` tokens.
    /// @param user    The buyer address.
    /// @param amount  Token amount (not NFT count).
    /// @param data    Arbitrary data — password hash, merkle proof, etc.
    function canMint(address user, uint256 amount, bytes calldata data) external returns (bool);

    /// @notice Record a successful mint. Called by instance after canMint passes.
    /// @param user   The buyer address.
    /// @param amount Token amount minted.
    function onMint(address user, uint256 amount) external;
}
