// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IZAMM, ZAMMAlignmentVault} from "./ZAMMAlignmentVault.sol";
import {ICreateX, CREATEX} from "../../shared/CreateXConstants.sol";

/// @title ZAMMAlignmentVaultFactory
/// @notice Deploys ZAMMAlignmentVault clones via CREATE3. No peripherals — just zamm + zRouter singletons.
contract ZAMMAlignmentVaultFactory {
    address public immutable vaultImplementation;
    address public immutable zamm;
    address public immutable zRouter;
    address public immutable protocolTreasury;

    event VaultDeployed(address indexed vault, address indexed alignmentToken);

    constructor(address _zamm, address _zRouter, address _protocolTreasury) {
        zamm = _zamm;
        zRouter = _zRouter;
        protocolTreasury = _protocolTreasury;
        vaultImplementation = address(new ZAMMAlignmentVault());
    }

    /// @notice Deploy a new ZAMM-backed vault clone via CREATE3
    /// @param salt CREATE3 deployment salt for deterministic vanity address
    /// @param alignmentToken The token this vault aligns to
    /// @param poolKey ZAMM pool key for the ETH/alignmentToken pool
    /// @return vault Address of the deployed vault clone
    function deployVault(
        bytes32 salt,
        address alignmentToken,
        IZAMM.PoolKey calldata poolKey
    ) external returns (address vault) {
        bytes memory proxyCreationCode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            vaultImplementation,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        vault = ICreateX(CREATEX).deployCreate3(salt, proxyCreationCode);
        ZAMMAlignmentVault(payable(vault)).initialize(
            zamm,
            zRouter,
            alignmentToken,
            poolKey,
            protocolTreasury
        );
        emit VaultDeployed(vault, alignmentToken);
    }

    /// @notice Preview the deterministic address for a given salt
    function computeVaultAddress(bytes32 salt) external view returns (address) {
        bytes32 guardedSalt = keccak256(abi.encodePacked(uint256(uint160(address(this))), salt));
        return ICreateX(CREATEX).computeCreate3Address(guardedSalt, CREATEX);
    }
}
