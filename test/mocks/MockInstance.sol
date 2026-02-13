// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal IFactoryInstance mock for testing registry enforcement
contract MockInstance {
    address public vault;
    address public protocolTreasury;
    constructor(address _vault) {
        vault = _vault;
        protocolTreasury = address(0xFEE);
    }
}
