// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Pluggable gating interface for ms2.fun instances (ERC404 and ERC1155).
/// address(0) means open gating — no module deployed.
/// Implementations are registered in ComponentRegistry under tag keccak256("gating").
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
