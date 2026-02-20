// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MessageTypes
/// @notice Message type constants for the global messaging system V2
library MessageTypes {
    uint8 internal constant POST = 0;
    uint8 internal constant REPLY = 1;
    uint8 internal constant QUOTE = 2;
    uint8 internal constant REACT = 3;
}
