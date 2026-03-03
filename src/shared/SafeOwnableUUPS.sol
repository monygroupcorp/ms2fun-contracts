// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title SafeOwnableUUPS
/// @notice Base for UUPS contracts that forces two-step ownership handover.
/// @dev Disables single-step transferOwnership and renounceOwnership.
///      Use requestOwnershipHandover() + completeOwnershipHandover() instead.
abstract contract SafeOwnableUUPS is UUPSUpgradeable, Ownable {
    error UseRequestOwnershipHandover();
    error RenounceDisabled();

    /// @dev Reverts — use the two-step handover flow instead.
    function transferOwnership(address) public payable override {
        revert UseRequestOwnershipHandover();
    }

    /// @dev Reverts — renouncing ownership on UUPS contracts bricks upgrades.
    function renounceOwnership() public payable override {
        revert RenounceDisabled();
    }

    /// @dev Only the owner can authorize upgrades.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
