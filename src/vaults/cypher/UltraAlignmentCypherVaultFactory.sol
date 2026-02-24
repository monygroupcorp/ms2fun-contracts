// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LibClone} from "solady/utils/LibClone.sol";
import {UltraAlignmentCypherVault} from "./UltraAlignmentCypherVault.sol";

/// @title UltraAlignmentCypherVaultFactory
/// @notice Deploys UltraAlignmentCypherVault clones
contract UltraAlignmentCypherVaultFactory {
    address public immutable vaultImplementation;

    event VaultCreated(address indexed vault, address indexed alignmentToken, address indexed creator);

    constructor(address _vaultImplementation) {
        vaultImplementation = _vaultImplementation;
    }

    function createVault(
        address positionManager,
        address swapRouterAddr,
        address weth,
        address alignmentToken,
        address factoryCreator,
        uint256 creatorYieldCutBps,
        address protocolTreasury,
        address liquidityDeployer
    ) external returns (UltraAlignmentCypherVault vault) {
        vault = UltraAlignmentCypherVault(payable(LibClone.clone(vaultImplementation)));
        vault.initialize(
            positionManager, swapRouterAddr, weth, alignmentToken,
            factoryCreator, creatorYieldCutBps, protocolTreasury, liquidityDeployer
        );
        emit VaultCreated(address(vault), alignmentToken, factoryCreator);
    }
}
