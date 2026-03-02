// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibClone} from "solady/utils/LibClone.sol";
import {UniAlignmentVault} from "./UniAlignmentVault.sol";
import {IVaultPriceValidator} from "../../interfaces/IVaultPriceValidator.sol";

/// @title UniAlignmentVaultFactory
/// @notice Deploys UniAlignmentVault clones; zRouter config is shared across all vaults.
contract UniAlignmentVaultFactory {
    address public immutable vaultImplementation;
    IVaultPriceValidator public immutable defaultPriceValidator;

    address public immutable weth;
    address public immutable poolManager;
    address public immutable zRouter;
    uint24  public immutable zRouterFee;
    int24   public immutable zRouterTickSpacing;

    event VaultDeployed(address indexed vault, address indexed alignmentToken);

    constructor(
        address _weth,
        address _poolManager,
        address _zRouter,
        uint24  _zRouterFee,
        int24   _zRouterTickSpacing,
        IVaultPriceValidator _defaultPriceValidator
    ) {
        weth = _weth;
        poolManager = _poolManager;
        zRouter = _zRouter;
        zRouterFee = _zRouterFee;
        zRouterTickSpacing = _zRouterTickSpacing;
        defaultPriceValidator = _defaultPriceValidator;
        vaultImplementation = address(new UniAlignmentVault());
    }

    /// @notice Deploy a new vault clone
    /// @param alignmentToken The token this vault aligns to
    /// @param priceValidator Custom price validator; uses defaultPriceValidator if address(0)
    /// @return vault Address of the deployed vault clone
    function deployVault(
        address alignmentToken,
        IVaultPriceValidator priceValidator
    ) external returns (address vault) {
        vault = LibClone.clone(vaultImplementation);

        UniAlignmentVault(payable(vault)).initialize(
            weth,
            poolManager,
            alignmentToken,
            zRouter,
            zRouterFee,
            zRouterTickSpacing,
            priceValidator == IVaultPriceValidator(address(0)) ? defaultPriceValidator : priceValidator
        );

        emit VaultDeployed(vault, alignmentToken);
    }
}
