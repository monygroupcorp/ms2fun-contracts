// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LibClone} from "solady/utils/LibClone.sol";
import {CypherAlignmentVault} from "./CypherAlignmentVault.sol";

/// @title CypherAlignmentVaultFactory
/// @notice Deploys CypherAlignmentVault clones
contract CypherAlignmentVaultFactory {
    address public immutable vaultImplementation;

    event VaultDeployed(address indexed vault, address indexed alignmentToken);

    constructor(address _vaultImplementation) {
        vaultImplementation = _vaultImplementation;
    }

    function createVault(
        address positionManager,
        address swapRouterAddr,
        address weth,
        address alignmentToken,
        address protocolTreasury,
        address liquidityDeployer
    ) external returns (CypherAlignmentVault vault) {
        vault = CypherAlignmentVault(payable(LibClone.clone(vaultImplementation)));
        vault.initialize(
            positionManager, swapRouterAddr, weth, alignmentToken,
            protocolTreasury, liquidityDeployer
        );
        emit VaultDeployed(address(vault), alignmentToken);
    }
}
