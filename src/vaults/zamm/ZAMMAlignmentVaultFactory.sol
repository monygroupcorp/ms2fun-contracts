// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {LibClone} from "solady/utils/LibClone.sol";
import {IZAMM, ZAMMAlignmentVault} from "./ZAMMAlignmentVault.sol";

/// @title ZAMMAlignmentVaultFactory
/// @notice Deploys ZAMMAlignmentVault clones. No peripherals — just zamm + zRouter singletons.
contract ZAMMAlignmentVaultFactory {
    address public immutable vaultImplementation;
    address public immutable zamm;
    address public immutable zRouter;
    address public immutable protocolTreasury;

    event VaultDeployed(address indexed vault, address indexed alignmentToken, address indexed creator);

    constructor(address _zamm, address _zRouter, address _protocolTreasury) {
        zamm = _zamm;
        zRouter = _zRouter;
        protocolTreasury = _protocolTreasury;
        vaultImplementation = address(new ZAMMAlignmentVault());
    }

    /// @notice Deploy a new ZAMM-backed vault clone
    /// @param alignmentToken The token this vault aligns to
    /// @param poolKey ZAMM pool key for the ETH/alignmentToken pool
    /// @param factoryCreator Address receiving the creator yield cut
    /// @param creatorYieldCutBps Creator yield cut in bps (max 500)
    /// @return vault Address of the deployed vault clone
    function deployVault(
        address alignmentToken,
        IZAMM.PoolKey calldata poolKey,
        address factoryCreator,
        uint256 creatorYieldCutBps
    ) external returns (address vault) {
        vault = LibClone.clone(vaultImplementation);
        ZAMMAlignmentVault(payable(vault)).initialize(
            zamm,
            zRouter,
            alignmentToken,
            poolKey,
            factoryCreator,
            creatorYieldCutBps,
            protocolTreasury
        );
        emit VaultDeployed(vault, alignmentToken, factoryCreator);
    }
}
