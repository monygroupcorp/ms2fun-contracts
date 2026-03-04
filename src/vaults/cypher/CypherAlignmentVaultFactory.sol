// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CypherAlignmentVault} from "./CypherAlignmentVault.sol";
import {ICreateX, CREATEX} from "../../shared/CreateXConstants.sol";

/// @title CypherAlignmentVaultFactory
/// @notice Deploys CypherAlignmentVault clones via CREATE3
contract CypherAlignmentVaultFactory {
    address public immutable vaultImplementation;

    event VaultDeployed(address indexed vault, address indexed alignmentToken);

    // slither-disable-next-line missing-zero-check
    constructor(address _vaultImplementation) {
        vaultImplementation = _vaultImplementation;
    }

    // slither-disable-next-line reentrancy-events
    function createVault(
        bytes32 salt,
        address positionManager,
        address swapRouterAddr,
        address weth,
        address alignmentToken,
        address protocolTreasury,
        address liquidityDeployer
    ) external returns (CypherAlignmentVault vault) {
        bytes memory proxyCreationCode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            vaultImplementation,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        vault = CypherAlignmentVault(payable(ICreateX(CREATEX).deployCreate3(salt, proxyCreationCode)));
        vault.initialize(
            positionManager, swapRouterAddr, weth, alignmentToken,
            protocolTreasury, liquidityDeployer
        );
        emit VaultDeployed(address(vault), alignmentToken);
    }

    /// @notice Preview the deterministic address for a given salt
    function computeVaultAddress(bytes32 salt) external view returns (address) {
        bytes32 guardedSalt = keccak256(abi.encodePacked(uint256(uint160(address(this))), salt));
        return ICreateX(CREATEX).computeCreate3Address(guardedSalt, CREATEX);
    }
}
