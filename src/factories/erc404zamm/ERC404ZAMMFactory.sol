// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {IMasterRegistry} from "../../master/interfaces/IMasterRegistry.sol";
import {IFactory} from "../../interfaces/IFactory.sol";
import {FeatureUtils} from "../../master/libraries/FeatureUtils.sol";
import {ERC404ZAMMBondingInstance} from "./ERC404ZAMMBondingInstance.sol";
import {ZAMMLiquidityDeployerModule} from "./ZAMMLiquidityDeployerModule.sol";
import {CurveParamsComputer} from "../erc404/CurveParamsComputer.sol";
import {BondingCurveMath} from "../erc404/libraries/BondingCurveMath.sol";
import {IdentityParams} from "../../interfaces/IFactoryTypes.sol";
import {PasswordTierGatingModule} from "../../gating/PasswordTierGatingModule.sol";
import {IComponentRegistry} from "../../registry/interfaces/IComponentRegistry.sol";

/**
 * @title ERC404ZAMMFactory
 * @notice Factory for ERC404 bonding instances that graduate into ZAMM pools.
 *         Independent developer factory — no V4 dependencies.
 */
contract ERC404ZAMMFactory is OwnableRoles, ReentrancyGuard, IFactory {
    uint256 public constant PROTOCOL_ROLE = _ROLE_0;

    /// @dev Packs constructor params to stay within 16-local Yul stack limit.
    struct CoreConfig {
        address implementation;
        address masterRegistry;
        address zamm;
        address zRouter;
        uint256 feeOrHook;
        uint256 taxBps;
        address protocol;
    }
    struct ModuleConfig {
        address globalMessageRegistry;
        address curveComputer;
        address liquidityDeployer;
        address tierGatingModule;
        address componentRegistry;
    }

    // ── Immutables ────────────────────────────────────────────────────────────
    address public immutable globalMessageRegistry;

    // ── Config ────────────────────────────────────────────────────────────────
    IMasterRegistry public masterRegistry;
    address public implementation;
    address public zamm;
    address public zRouter;
    uint256 public feeOrHook;
    uint256 public taxBps;
    address public protocolTreasury;
    uint256 public accumulatedProtocolFees;

    uint256 public bondingFeeBps = 100;      // 1%

    ZAMMLiquidityDeployerModule public immutable liquidityDeployer;
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
    bytes32[] internal _features;

    // ── Events ────────────────────────────────────────────────────────────────
    event InstanceCreated(address indexed instance, address indexed instanceCreator, string name, string symbol, address indexed vault);
    event ProfileUpdated(uint256 indexed profileId, uint256 targetETH, bool active);
    event ProtocolTreasuryUpdated(address indexed old, address indexed next);
    event TaxBpsUpdated(uint256 newBps);

    constructor(CoreConfig memory core, ModuleConfig memory modules) {
        require(core.implementation != address(0), "Invalid implementation");
        require(core.zamm != address(0), "Invalid zamm");
        require(core.protocol != address(0), "Invalid protocol");
        require(modules.liquidityDeployer != address(0), "Invalid deployer");
        require(modules.globalMessageRegistry != address(0), "Invalid GMR");
        require(modules.curveComputer != address(0), "Invalid curveComputer");

        _initializeOwner(core.protocol);
        _grantRoles(core.protocol, PROTOCOL_ROLE);

        implementation = core.implementation;
        masterRegistry = IMasterRegistry(core.masterRegistry);
        zamm = core.zamm;
        zRouter = core.zRouter;
        feeOrHook = core.feeOrHook;
        taxBps = core.taxBps;
        liquidityDeployer = ZAMMLiquidityDeployerModule(payable(modules.liquidityDeployer));
        globalMessageRegistry = modules.globalMessageRegistry;
        curveComputer = CurveParamsComputer(modules.curveComputer);
        tierGatingModule = PasswordTierGatingModule(modules.tierGatingModule);
        componentRegistry = IComponentRegistry(modules.componentRegistry);

        _features.push(FeatureUtils.BONDING_CURVE);
        _features.push(FeatureUtils.LIQUIDITY_POOL);
        _features.push(FeatureUtils.CHAT);
        _features.push(FeatureUtils.PORTFOLIO);
        _features.push(FeatureUtils.GATING);
    }

    /**
     * @notice Create a new ERC404 ZAMM bonding instance with open gating (no password tiers).
     */
    function createInstance(
        IdentityParams calldata identity,
        string calldata metadataURI,
        address vault
    ) external payable nonReentrant returns (address instance) {
        return _createInstanceCore(identity, metadataURI, address(0), vault);
    }

    /**
     * @notice Create a new ERC404 ZAMM bonding instance with any DAO-approved gating component.
     * @param gatingModule address(0) = open gating; otherwise must be approved in ComponentRegistry.
     */
    function createInstance(
        IdentityParams calldata identity,
        string calldata metadataURI,
        address gatingModule,
        address vault
    ) external payable nonReentrant returns (address instance) {
        if (gatingModule != address(0)) {
            require(componentRegistry.isApprovedComponent(gatingModule), "Unapproved component");
        }
        return _createInstanceCore(identity, metadataURI, gatingModule, vault);
    }

    /**
     * @notice Create a new ERC404 ZAMM bonding instance with password-tier gating.
     */
    function createInstanceWithTiers(
        IdentityParams calldata identity,
        string calldata metadataURI,
        address vault,
        PasswordTierGatingModule.TierConfig calldata tiers
    ) external payable nonReentrant returns (address instance) {
        return _createInstanceInternalWithTiers(identity, metadataURI, vault, tiers);
    }

    /// @dev New path: accepts a pre-resolved gatingModule address, skips configureFor.
    function _createInstanceCore(
        IdentityParams calldata identity,
        string calldata metadataURI,
        address gatingModule,
        address vault
    ) internal returns (address instance) {
        accumulatedProtocolFees += msg.value;
        require(identity.nftCount > 0, "Invalid NFT count");
        require(bytes(identity.name).length > 0, "Invalid name");
        require(identity.owner != address(0), "Invalid creator");
        require(vault != address(0), "Vault required");
        require(vault.code.length > 0, "Vault must be contract");
        require(!masterRegistry.isNameTaken(identity.name), "Name taken");

        ERC404ZAMMBondingInstance.BondingParams memory bonding = _computeBondingParams(identity.nftCount, identity.profileId);
        instance = LibClone.clone(implementation);

        // gatingModule is pre-resolved — no configureFor call
        ERC404ZAMMBondingInstance(payable(instance)).initialize(identity.owner, vault, bonding, gatingModule);
        ERC404ZAMMBondingInstance(payable(instance)).initializeProtocol(_buildProtocolParams());
        _setMetadata(instance, identity);
        _finalizeInstance(instance, identity, metadataURI, vault);
    }

    /// @dev Legacy path: accepts TierConfig, calls configureFor after clone deployment.
    function _createInstanceInternalWithTiers(
        IdentityParams calldata identity,
        string calldata metadataURI,
        address vault,
        PasswordTierGatingModule.TierConfig memory tiers
    ) internal returns (address instance) {
        accumulatedProtocolFees += msg.value;
        require(identity.nftCount > 0, "Invalid NFT count");
        require(bytes(identity.name).length > 0, "Invalid name");
        require(identity.owner != address(0), "Invalid creator");
        require(vault != address(0), "Vault required");
        require(vault.code.length > 0, "Vault must be contract");
        require(!masterRegistry.isNameTaken(identity.name), "Name taken");

        ERC404ZAMMBondingInstance.BondingParams memory bonding = _computeBondingParams(identity.nftCount, identity.profileId);
        instance = LibClone.clone(implementation);

        address gatingModuleAddr;
        if (tiers.passwordHashes.length > 0) {
            tierGatingModule.configureFor(instance, tiers);
            gatingModuleAddr = address(tierGatingModule);
        }

        ERC404ZAMMBondingInstance(payable(instance)).initialize(identity.owner, vault, bonding, gatingModuleAddr);
        ERC404ZAMMBondingInstance(payable(instance)).initializeProtocol(_buildProtocolParams());
        _setMetadata(instance, identity);
        _finalizeInstance(instance, identity, metadataURI, vault);
    }

    function _computeBondingParams(uint256 nftCount, uint8 profileId) private view
        returns (ERC404ZAMMBondingInstance.BondingParams memory bonding)
    {
        GraduationProfile memory profile = profiles[profileId];
        require(profile.active, "Profile not active");
        uint256 unit = profile.unitPerNFT * 1e18;
        bonding = ERC404ZAMMBondingInstance.BondingParams({
            maxSupply: nftCount * unit,
            unit: unit,
            liquidityReservePercent: profile.liquidityReserveBps / 100,
            curve: curveComputer.computeCurveParams(
                nftCount, profile.targetETH, profile.unitPerNFT, profile.liquidityReserveBps
            )
        });
    }

    function _buildProtocolParams() private view returns (ERC404ZAMMBondingInstance.ProtocolParams memory) {
        return ERC404ZAMMBondingInstance.ProtocolParams({
            globalMessageRegistry: globalMessageRegistry,
            protocolTreasury: protocolTreasury,
            masterRegistry: address(masterRegistry),
            liquidityDeployer: address(liquidityDeployer),
            curveComputer: address(curveComputer),
            bondingFeeBps: bondingFeeBps
        });
    }

    function _setMetadata(address instance, IdentityParams calldata identity) private {
        ERC404ZAMMBondingInstance(payable(instance)).initializeMetadata(
            identity.name, identity.symbol, identity.styleUri
        );
    }

    function _finalizeInstance(
        address instance,
        IdentityParams calldata identity,
        string calldata metadataURI,
        address vault
    ) private {
        masterRegistry.registerInstance(instance, address(this), identity.owner, identity.name, metadataURI, vault);
        if (msg.value > 0) {
            // Refund excess (none expected since fee is free, but keep pattern)
        }
        emit InstanceCreated(instance, identity.owner, identity.name, identity.symbol, vault);
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

    function setTaxBps(uint256 bps) external onlyRoles(PROTOCOL_ROLE) {
        require(bps <= 300, "Max 3%");
        taxBps = bps;
        emit TaxBpsUpdated(bps);
    }

    function withdrawProtocolFees() external onlyRoles(PROTOCOL_ROLE) {
        require(protocolTreasury != address(0), "No treasury");
        uint256 amt = accumulatedProtocolFees;
        require(amt > 0, "No fees");
        accumulatedProtocolFees = 0;
        SafeTransferLib.safeTransferETH(protocolTreasury, amt);
    }

    function getFeatures() external view returns (bytes32[] memory) { return _features; }
    function protocol() external view returns (address) { return owner(); }

    function features() external view returns (bytes32[] memory) { return _features; }
}
