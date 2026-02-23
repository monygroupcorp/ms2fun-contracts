// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {LibClone} from "solady/utils/LibClone.sol";
import {UltraAlignmentVault} from "./UltraAlignmentVault.sol";
import {UniswapVaultSwapRouter} from "../peripherals/UniswapVaultSwapRouter.sol";
import {UniswapVaultPriceValidator} from "../peripherals/UniswapVaultPriceValidator.sol";
import {IVaultSwapRouter} from "../interfaces/IVaultSwapRouter.sol";
import {IVaultPriceValidator} from "../interfaces/IVaultPriceValidator.sol";

/// @title UltraAlignmentVaultFactory
/// @notice Deploys UltraAlignmentVault clones with shared peripheral singletons
contract UltraAlignmentVaultFactory {
    address public immutable vaultImplementation;
    IVaultSwapRouter public immutable defaultSwapRouter;
    IVaultPriceValidator public immutable defaultPriceValidator;

    address public immutable weth;
    address public immutable poolManager;
    address public immutable v3Router;
    address public immutable v2Router;
    address public immutable v2Factory;
    address public immutable v3Factory;

    event VaultDeployed(address indexed vault, address indexed alignmentToken, address indexed creator);

    constructor(
        address _weth,
        address _poolManager,
        address _v3Router,
        address _v2Router,
        address _v2Factory,
        address _v3Factory
    ) {
        weth = _weth;
        poolManager = _poolManager;
        v3Router = _v3Router;
        v2Router = _v2Router;
        v2Factory = _v2Factory;
        v3Factory = _v3Factory;

        defaultSwapRouter = new UniswapVaultSwapRouter(
            _weth, _poolManager, _v3Router, _v2Router, _v2Factory, _v3Factory, 3000
        );
        defaultPriceValidator = new UniswapVaultPriceValidator(
            _weth, _v2Factory, _v3Factory, _poolManager, 500
        );
        vaultImplementation = address(new UltraAlignmentVault());
    }

    /// @notice Deploy a new vault clone
    /// @param alignmentToken The token this vault aligns to
    /// @param factoryCreator Address that receives creator yield cut
    /// @param creatorYieldCutBps Creator yield cut in basis points (max 500)
    /// @param swapRouter Custom swap router; uses defaultSwapRouter if address(0)
    /// @param priceValidator Custom price validator; uses defaultPriceValidator if address(0)
    /// @return vault Address of the deployed vault clone
    function deployVault(
        address alignmentToken,
        address factoryCreator,
        uint256 creatorYieldCutBps,
        IVaultSwapRouter swapRouter,
        IVaultPriceValidator priceValidator
    ) external returns (address vault) {
        vault = LibClone.clone(vaultImplementation);

        UltraAlignmentVault(payable(vault)).initialize(
            weth,
            poolManager,
            v3Router,
            v2Router,
            v2Factory,
            v3Factory,
            alignmentToken,
            factoryCreator,
            creatorYieldCutBps,
            swapRouter == IVaultSwapRouter(address(0)) ? defaultSwapRouter : swapRouter,
            priceValidator == IVaultPriceValidator(address(0)) ? defaultPriceValidator : priceValidator
        );

        emit VaultDeployed(vault, alignmentToken, factoryCreator);
    }
}
