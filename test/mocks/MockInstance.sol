// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IInstanceLifecycle, TYPE_ERC404} from "../../src/interfaces/IInstanceLifecycle.sol";

/// @notice Minimal IFactoryInstance + IInstanceLifecycle mock for testing registry enforcement
contract MockInstance is IInstanceLifecycle {
    address public vault;
    address public protocolTreasury;
    address public globalMessageRegistryAddr;

    constructor(address _vault) {
        vault = _vault;
        protocolTreasury = address(0xFEE);
    }

    function getGlobalMessageRegistry() external view returns (address) {
        return globalMessageRegistryAddr;
    }

    function instanceType() external pure override returns (bytes32) {
        return TYPE_ERC404;
    }
}
