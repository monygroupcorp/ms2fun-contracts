// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {IMasterRegistry} from "../../master/interfaces/IMasterRegistry.sol";
import {IFactory} from "../../interfaces/IFactory.sol";
import {FeatureUtils} from "../../master/libraries/FeatureUtils.sol";
import {ERC404CypherBondingInstance} from "./ERC404CypherBondingInstance.sol";
import {CypherLiquidityDeployerModule} from "./CypherLiquidityDeployerModule.sol";
import {CypherAlignmentVaultFactory} from "../../vaults/cypher/CypherAlignmentVaultFactory.sol";
import {CypherAlignmentVault} from "../../vaults/cypher/CypherAlignmentVault.sol";
import {CurveParamsComputer} from "../erc404/CurveParamsComputer.sol";
import {BondingCurveMath} from "../erc404/libraries/BondingCurveMath.sol";
import {IdentityParams} from "../../interfaces/IFactoryTypes.sol";
import {PasswordTierGatingModule} from "../../gating/PasswordTierGatingModule.sol";
import {IComponentRegistry} from "../../registry/interfaces/IComponentRegistry.sol";

/**
 * @title ERC404CypherFactory
 * @notice Factory for ERC404 bonding instances that graduate into Algebra V2 (Cypher AMM) full-range LP pools.
 *         Creates one vault per instance at creation time.
 */
contract ERC404CypherFactory is OwnableRoles, ReentrancyGuard, IFactory {
    uint256 public constant PROTOCOL_ROLE = _ROLE_0;

    /// @dev Packs constructor params to stay within 16-local Yul stack limit (15 params → 2 structs).
    struct CoreConfig {
        address implementation;
        address masterRegistry;
        address vaultFactory;
        address liquidityDeployer;
        address algebraFactory;
        address positionManager;
        address swapRouter;
        address weth;
        address protocol;
    }
    struct ModuleConfig {
        address globalMessageRegistry;
        address curveComputer;
        address tierGatingModule;
        address componentRegistry;
    }

    // ── Immutables ────────────────────────────────────────────────────────────
    address public immutable globalMessageRegistry;

    // Algebra V2 config (immutable after construction)
    address public immutable algebraFactory;
    address public immutable positionManager;
    address public immutable swapRouter;
    address public immutable weth;

    // ── Config ────────────────────────────────────────────────────────────────
    IMasterRegistry public masterRegistry;
    address public implementation;
    address public protocolTreasury;
    uint256 public accumulatedProtocolFees;

    uint256 public bondingFeeBps = 100;      // 1%

    CypherLiquidityDeployerModule public immutable liquidityDeployer;
    CypherAlignmentVaultFactory public immutable vaultFactory;
    CurveParamsComputer public immutable curveComputer;
    PasswordTierGatingModule public immutable tierGatingModule;
    IComponentRegistry public immutable componentRegistry;

    // Graduation profiles
    struct GraduationProfile {
        uint256 targetETH;
        uint256 unitPerNFT;
        uint256 liquidityReserveBps;
        bool active;
    }
    mapping(uint256 => GraduationProfile) public profiles;

    // Features
    bytes32[] public features;

    // ── Events ────────────────────────────────────────────────────────────────
    event InstanceCreated(address indexed instance, address indexed instanceCreator, string name, string symbol, address indexed vault);
    event ProfileUpdated(uint256 indexed profileId, uint256 targetETH, bool active);
    event ProtocolTreasuryUpdated(address indexed old, address indexed next);

    constructor(CoreConfig memory core, ModuleConfig memory modules) {
        require(core.implementation != address(0), "Invalid implementation");
        require(core.vaultFactory != address(0), "Invalid vault factory");
        require(core.liquidityDeployer != address(0), "Invalid deployer");
        require(core.weth != address(0), "Invalid weth");
        require(core.protocol != address(0), "Invalid protocol");
        require(modules.globalMessageRegistry != address(0), "Invalid GMR");
        require(modules.curveComputer != address(0), "Invalid curveComputer");

        _initializeOwner(core.protocol);
        _grantRoles(core.protocol, PROTOCOL_ROLE);

        implementation = core.implementation;
        masterRegistry = IMasterRegistry(core.masterRegistry);
        liquidityDeployer = CypherLiquidityDeployerModule(payable(core.liquidityDeployer));
        vaultFactory = CypherAlignmentVaultFactory(core.vaultFactory);
        globalMessageRegistry = modules.globalMessageRegistry;
        curveComputer = CurveParamsComputer(modules.curveComputer);
        algebraFactory = core.algebraFactory;
        positionManager = core.positionManager;
        swapRouter = core.swapRouter;
        weth = core.weth;
        tierGatingModule = PasswordTierGatingModule(modules.tierGatingModule);
        componentRegistry = IComponentRegistry(modules.componentRegistry);

        features.push(FeatureUtils.BONDING_CURVE);
        features.push(FeatureUtils.LIQUIDITY_POOL);
        features.push(FeatureUtils.CHAT);
        features.push(FeatureUtils.PORTFOLIO);
    }

    /**
     * @notice Create a new ERC404 Cypher bonding instance with open gating (no password tiers).
     */
    function createInstance(
        IdentityParams calldata identity,
        string calldata metadataURI,
        address alignmentTarget
    ) external payable nonReentrant returns (address instance) {
        return _createInstanceCore(identity, metadataURI, address(0), alignmentTarget);
    }

    /**
     * @notice Create a new ERC404 Cypher bonding instance with any DAO-approved gating component.
     * @param gatingModule address(0) = open gating; otherwise must be approved in ComponentRegistry.
     */
    function createInstance(
        IdentityParams calldata identity,
        string calldata metadataURI,
        address gatingModule,
        address alignmentTarget
    ) external payable nonReentrant returns (address instance) {
        if (gatingModule != address(0)) {
            require(componentRegistry.isApprovedComponent(gatingModule), "Unapproved component");
        }
        return _createInstanceCore(identity, metadataURI, gatingModule, alignmentTarget);
    }

    /**
     * @notice Create a new ERC404 Cypher bonding instance with password-tier gating.
     */
    function createInstanceWithTiers(
        IdentityParams calldata identity,
        string calldata metadataURI,
        address alignmentTarget,
        PasswordTierGatingModule.TierConfig calldata tiers
    ) external payable nonReentrant returns (address instance) {
        return _createInstanceInternalWithTiers(identity, metadataURI, alignmentTarget, tiers);
    }

    /// @dev New path: accepts a pre-resolved gatingModule address, skips _configureGating.
    function _createInstanceCore(
        IdentityParams calldata identity,
        string calldata metadataURI,
        address gatingModule,
        address alignmentTarget
    ) internal returns (address instance) {
        accumulatedProtocolFees += msg.value;
        require(identity.nftCount > 0, "Invalid NFT count");
        require(bytes(identity.name).length > 0, "Invalid name");
        require(identity.owner != address(0), "Invalid creator");
        require(alignmentTarget != address(0), "Invalid alignment target");
        require(!masterRegistry.isNameTaken(identity.name), "Name taken");

        ERC404CypherBondingInstance.BondingParams memory bonding = _computeBondingParams(identity.nftCount, identity.profileId);
        instance = LibClone.clone(implementation);
        address vault = address(_deployVault(alignmentTarget));

        // gatingModule is pre-resolved — no configureFor call
        ERC404CypherBondingInstance(payable(instance)).initialize(identity.owner, vault, bonding, gatingModule);
        ERC404CypherBondingInstance(payable(instance)).initializeProtocol(_buildProtocolParams(vault));
        _setMetadata(instance, identity);
        _finalizeInstance(instance, identity, metadataURI, vault);
    }

    /// @dev Legacy path: accepts TierConfig, calls configureFor after clone deployment.
    function _createInstanceInternalWithTiers(
        IdentityParams calldata identity,
        string calldata metadataURI,
        address alignmentTarget,
        PasswordTierGatingModule.TierConfig memory tiers
    ) internal returns (address instance) {
        accumulatedProtocolFees += msg.value;
        require(identity.nftCount > 0, "Invalid NFT count");
        require(bytes(identity.name).length > 0, "Invalid name");
        require(identity.owner != address(0), "Invalid creator");
        require(alignmentTarget != address(0), "Invalid alignment target");
        require(!masterRegistry.isNameTaken(identity.name), "Name taken");

        ERC404CypherBondingInstance.BondingParams memory bonding = _computeBondingParams(identity.nftCount, identity.profileId);
        instance = LibClone.clone(implementation);
        address vault = address(_deployVault(alignmentTarget));

        address gatingModuleAddr;
        if (tiers.passwordHashes.length > 0) {
            tierGatingModule.configureFor(instance, tiers);
            gatingModuleAddr = address(tierGatingModule);
        }

        ERC404CypherBondingInstance(payable(instance)).initialize(identity.owner, vault, bonding, gatingModuleAddr);
        ERC404CypherBondingInstance(payable(instance)).initializeProtocol(_buildProtocolParams(vault));
        _setMetadata(instance, identity);
        _finalizeInstance(instance, identity, metadataURI, vault);
    }

    function _deployVault(address alignmentTarget) private returns (CypherAlignmentVault) {
        return vaultFactory.createVault(
            positionManager,
            swapRouter,
            weth,
            alignmentTarget,
            protocolTreasury != address(0) ? protocolTreasury : owner(),
            address(liquidityDeployer)
        );
    }

    function _computeBondingParams(uint256 nftCount, uint8 profileId) private view
        returns (ERC404CypherBondingInstance.BondingParams memory bonding)
    {
        GraduationProfile memory profile = profiles[profileId];
        require(profile.active, "Profile not active");
        uint256 unit = profile.unitPerNFT * 1e18;
        bonding = ERC404CypherBondingInstance.BondingParams({
            maxSupply: nftCount * unit,
            unit: unit,
            liquidityReservePercent: profile.liquidityReserveBps / 100,
            curve: curveComputer.computeCurveParams(
                nftCount, profile.targetETH, profile.unitPerNFT, profile.liquidityReserveBps
            )
        });
    }

    function _finalizeInstance(
        address instance,
        IdentityParams calldata identity,
        string calldata metadataURI,
        address vault
    ) private {
        masterRegistry.registerInstance(instance, address(this), identity.owner, identity.name, metadataURI, vault);
        emit InstanceCreated(instance, identity.owner, identity.name, identity.symbol, vault);
    }

    function _buildProtocolParams(address) private view returns (ERC404CypherBondingInstance.ProtocolParams memory) {
        return ERC404CypherBondingInstance.ProtocolParams({
            globalMessageRegistry: globalMessageRegistry,
            protocolTreasury: protocolTreasury,
            masterRegistry: address(masterRegistry),
            liquidityDeployer: address(liquidityDeployer),
            curveComputer: address(curveComputer),
            weth: weth,
            algebraFactory: algebraFactory,
            positionManager: positionManager,
            bondingFeeBps: bondingFeeBps
        });
    }

    function _setMetadata(address instance, IdentityParams calldata identity) private {
        ERC404CypherBondingInstance(payable(instance)).initializeMetadata(
            identity.name, identity.symbol, identity.styleUri
        );
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setProfile(uint256 id, GraduationProfile calldata p) external onlyRoles(PROTOCOL_ROLE) {
        require(p.targetETH > 0, "Invalid targetETH");
        require(p.unitPerNFT > 0, "Invalid unit");
        require(p.liquidityReserveBps > 0 && p.liquidityReserveBps < 10000, "Invalid reserve");
        profiles[id] = p;
        emit ProfileUpdated(id, p.targetETH, p.active);
    }

    function setProtocolTreasury(address t) external onlyRoles(PROTOCOL_ROLE) {
        require(t != address(0), "Invalid treasury");
        emit ProtocolTreasuryUpdated(protocolTreasury, t);
        protocolTreasury = t;
    }

    function withdrawProtocolFees() external onlyRoles(PROTOCOL_ROLE) {
        require(protocolTreasury != address(0), "No treasury");
        uint256 amt = accumulatedProtocolFees;
        require(amt > 0, "No fees");
        accumulatedProtocolFees = 0;
        SafeTransferLib.safeTransferETH(protocolTreasury, amt);
    }

    function getFeatures() external view returns (bytes32[] memory) { return features; }
    function protocol() external view returns (address) { return owner(); }
}
