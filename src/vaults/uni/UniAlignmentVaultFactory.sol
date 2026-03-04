// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UniAlignmentVault} from "./UniAlignmentVault.sol";
import {IVaultPriceValidator} from "../../interfaces/IVaultPriceValidator.sol";
import {IAlignmentRegistry} from "../../master/interfaces/IAlignmentRegistry.sol";
import {ICreateX, CREATEX} from "../../shared/CreateXConstants.sol";

/// @title UniAlignmentVaultFactory
/// @notice Deploys UniAlignmentVault clones; zRouter config is shared across all vaults.
contract UniAlignmentVaultFactory {
    address public immutable vaultImplementation;
    IVaultPriceValidator public immutable defaultPriceValidator;
    IAlignmentRegistry public immutable alignmentRegistry;

    address public immutable weth;
    address public immutable poolManager;
    address public immutable zRouter;
    uint24  public immutable zRouterFee;
    int24   public immutable zRouterTickSpacing;

    event VaultDeployed(address indexed vault, address indexed alignmentToken);

    constructor(
        // slither-disable-next-line missing-zero-check
        address _weth,
        // slither-disable-next-line missing-zero-check
        address _poolManager,
        // slither-disable-next-line missing-zero-check
        address _zRouter,
        uint24  _zRouterFee,
        int24   _zRouterTickSpacing,
        IVaultPriceValidator _defaultPriceValidator,
        IAlignmentRegistry _alignmentRegistry
    ) {
        weth = _weth;
        poolManager = _poolManager;
        zRouter = _zRouter;
        zRouterFee = _zRouterFee;
        zRouterTickSpacing = _zRouterTickSpacing;
        defaultPriceValidator = _defaultPriceValidator;
        alignmentRegistry = _alignmentRegistry;
        vaultImplementation = address(new UniAlignmentVault());
    }

    /// @notice Deploy a new vault clone via CREATE3
    /// @param salt CREATE3 deployment salt for deterministic vanity address
    /// @param alignmentToken The token this vault aligns to
    /// @param alignmentTargetId The alignment target this vault is bound to
    /// @param priceValidator Custom price validator; uses defaultPriceValidator if address(0)
    /// @return vault Address of the deployed vault clone
    // slither-disable-next-line reentrancy-events
    function deployVault(
        bytes32 salt,
        address alignmentToken,
        uint256 alignmentTargetId,
        IVaultPriceValidator priceValidator
    ) external returns (address vault) {
        bytes memory proxyCreationCode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            vaultImplementation,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        vault = ICreateX(CREATEX).deployCreate3(salt, proxyCreationCode);

        UniAlignmentVault(payable(vault)).initialize(
            weth,
            poolManager,
            alignmentToken,
            zRouter,
            zRouterFee,
            zRouterTickSpacing,
            priceValidator == IVaultPriceValidator(address(0)) ? defaultPriceValidator : priceValidator,
            alignmentRegistry,
            alignmentTargetId
        );

        emit VaultDeployed(vault, alignmentToken);
    }

    /// @notice Preview the deterministic address for a given salt
    function computeVaultAddress(bytes32 salt) external view returns (address) {
        bytes32 guardedSalt = keccak256(abi.encodePacked(uint256(uint160(address(this))), salt));
        return ICreateX(CREATEX).computeCreate3Address(guardedSalt, CREATEX);
    }
}
