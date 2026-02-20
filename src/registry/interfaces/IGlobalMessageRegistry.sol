// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IGlobalMessageRegistry
/// @notice Minimal interface for instances to forward messages
interface IGlobalMessageRegistry {
    function postForAction(address sender, address instance, bytes calldata messageData) external;
}
