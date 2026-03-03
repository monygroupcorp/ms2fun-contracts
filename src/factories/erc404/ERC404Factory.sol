// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {IMasterRegistry} from "../../master/interfaces/IMasterRegistry.sol";
import {FeatureUtils} from "../../master/libraries/FeatureUtils.sol";
import {IAlignmentVault} from "../../interfaces/IAlignmentVault.sol";
import {IFactory} from "../../interfaces/IFactory.sol";
import {ICurveComputer} from "../../interfaces/ICurveComputer.sol";
import {ERC404BondingInstance} from "./ERC404BondingInstance.sol";
import {LaunchManager} from "./LaunchManager.sol";
import {PasswordTierGatingModule} from "../../gating/PasswordTierGatingModule.sol";
import {IComponentRegistry} from "../../registry/interfaces/IComponentRegistry.sol";
import {IdentityParams, FreeMintParams} from "../../interfaces/IFactoryTypes.sol";
import {GatingScope} from "../../gating/IGatingModule.sol";

/**
 * @title ERC404Factory
 * @notice Factory contract for deploying ERC404 token instances.
 * @dev Artists supply their chosen liquidity deployer and optional gating module at call time.
 *      Components are validated against ComponentRegistry. Bonding params are derived from
 *      a LaunchManager preset identified by identity.presetId.
 */
contract ERC404Factory is OwnableRoles, ReentrancyGuard, IFactory {
    uint256 public constant PROTOCOL_ROLE = _ROLE_0;  // 1 << 0 = 1

    /// @dev Infrastructure only — no AMM-specific addresses.
    struct CoreConfig {
        address implementation;
        address masterRegistry;
        address protocol;
    }

    /// @dev Module addresses — no deployer or curve computer (supplied per call).
    struct ModuleConfig {
        address globalMessageRegistry;
        address componentRegistry;
        address launchManager;
        address tierGatingModule;   // convenience — for createInstanceWithTiers
    }

    IMasterRegistry public masterRegistry;
    address public immutable globalMessageRegistry;
    address public implementation;

    // Protocol revenue
    address public protocolTreasury;
    uint256 public bondingFeeBps = 100; // 1% default
    uint256 public accumulatedProtocolFees;

    // Modules
    LaunchManager public immutable launchManager;
    PasswordTierGatingModule public immutable tierGatingModule;
    IComponentRegistry public immutable componentRegistry;

    // Feature matrix — pluggable choices advertised to the frontend
    bytes32[] internal _features = [FeatureUtils.GATING, FeatureUtils.LIQUIDITY_DEPLOYER];

    event InstanceCreated(
        address indexed instance,
        address indexed creator,
        string name,
        string symbol,
        address indexed vault
    );
    event VaultCapabilityWarning(address indexed vault, bytes32 indexed capability);
    event ProtocolTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ProtocolFeesWithdrawn(address indexed treasury, uint256 amount);
    event BondingFeeUpdated(uint256 newBps);

    constructor(CoreConfig memory core, ModuleConfig memory modules) {
        require(core.implementation != address(0), "Invalid implementation");
        require(core.protocol != address(0), "Invalid protocol");
        require(modules.globalMessageRegistry != address(0), "Invalid global message registry");
        require(modules.launchManager != address(0), "Invalid launch manager");
        require(modules.componentRegistry != address(0), "Invalid component registry");
        _initializeOwner(core.protocol);
        _grantRoles(core.protocol, PROTOCOL_ROLE);
        implementation = core.implementation;
        masterRegistry = IMasterRegistry(core.masterRegistry);
        globalMessageRegistry = modules.globalMessageRegistry;
        launchManager = LaunchManager(modules.launchManager);
        tierGatingModule = PasswordTierGatingModule(modules.tierGatingModule);
        componentRegistry = IComponentRegistry(modules.componentRegistry);
    }

    /// @notice Create an instance with a caller-supplied liquidity deployer and optional gating module.
    /// @param liquidityDeployer Must be approved in ComponentRegistry.
    /// @param gatingModule address(0) = open gating; otherwise must be approved in ComponentRegistry.
    /// @param freeMint Free mint configuration (allocation=0 disables free mints).
    function createInstance(
        IdentityParams calldata identity,
        string calldata metadataURI,
        address liquidityDeployer,
        address gatingModule,
        FreeMintParams calldata freeMint
    ) external payable nonReentrant returns (address instance) {
        if (gatingModule != address(0)) {
            require(componentRegistry.isApprovedComponent(gatingModule), "Unapproved gating module");
        }
        return _createInstanceCore(identity, metadataURI, liquidityDeployer, gatingModule, freeMint);
    }

    /// @notice Convenience wrapper: creates an instance with password-tier gating.
    function createInstanceWithTiers(
        IdentityParams calldata identity,
        string calldata metadataURI,
        address liquidityDeployer,
        PasswordTierGatingModule.TierConfig calldata tiers,
        FreeMintParams calldata freeMint
    ) external payable nonReentrant returns (address instance) {
        address gatingModuleAddr;
        if (tiers.passwordHashes.length > 0) {
            tierGatingModule.configureFor(address(0), tiers);
            gatingModuleAddr = address(tierGatingModule);
        }
        return _createInstanceCore(identity, metadataURI, liquidityDeployer, gatingModuleAddr, freeMint);
    }

    function _createInstanceCore(
        IdentityParams calldata identity,
        string calldata metadataURI,
        address liquidityDeployer,
        address gatingModule,
        FreeMintParams calldata freeMint
    ) internal returns (address instance) {
        accumulatedProtocolFees += msg.value;

        // Validate identity
        require(identity.nftCount > 0, "Invalid NFT count");
        require(bytes(identity.name).length > 0, "Invalid name");
        require(bytes(identity.symbol).length > 0, "Invalid symbol");
        require(identity.owner != address(0), "Invalid owner");
        require(identity.vault != address(0), "Vault required");
        require(identity.vault.code.length > 0, "Vault must be a contract");
        require(!masterRegistry.isNameTaken(identity.name), "Name already taken");
        require(freeMint.allocation < identity.nftCount, "Free mint allocation exceeds NFT count");

        // Validate liquidity deployer
        require(componentRegistry.isApprovedComponent(liquidityDeployer), "Unapproved liquidity deployer");

        // Soft vault capability check
        try IAlignmentVault(payable(identity.vault)).supportsCapability(keccak256("YIELD_GENERATION"))
            returns (bool supported) {
            if (!supported) emit VaultCapabilityWarning(identity.vault, keccak256("YIELD_GENERATION"));
        } catch {
            emit VaultCapabilityWarning(identity.vault, keccak256("YIELD_GENERATION"));
        }

        // Deploy clone and initialize via helpers (avoids stack-too-deep)
        instance = LibClone.clone(implementation);
        _initializeInstance(instance, identity, liquidityDeployer, gatingModule, freeMint);
        _finalizeInstance(instance, identity, metadataURI);
    }

    function _initializeInstance(
        address instance,
        IdentityParams calldata identity,
        address liquidityDeployer,
        address gatingModule,
        FreeMintParams calldata freeMint
    ) private {
        // Fetch preset and validate its curve computer
        LaunchManager.Preset memory preset = launchManager.getPreset(identity.presetId);
        require(componentRegistry.isApprovedComponent(preset.curveComputer), "Unapproved curve computer");

        uint256 unit = preset.unitPerNFT * 1e18;
        // Curve is computed over the paid-bonding portion only (excludes free mint tranche)
        uint256 curveNftCount = identity.nftCount - freeMint.allocation;
        ERC404BondingInstance.BondingParams memory bonding = ERC404BondingInstance.BondingParams({
            maxSupply: identity.nftCount * unit,          // full supply (includes free mint tranche)
            unit: unit,
            liquidityReservePercent: preset.liquidityReserveBps / 100,
            curve: ICurveComputer(preset.curveComputer).computeCurveParams(
                curveNftCount,                             // paid bonding portion
                preset.targetETH,
                preset.unitPerNFT,
                preset.liquidityReserveBps
            )
        });

        ERC404BondingInstance(payable(instance)).initialize(
            identity.owner, identity.vault, bonding, liquidityDeployer, gatingModule
        );
        ERC404BondingInstance(payable(instance)).initializeProtocol(
            ERC404BondingInstance.ProtocolParams({
                globalMessageRegistry: globalMessageRegistry,
                protocolTreasury: protocolTreasury,
                masterRegistry: address(masterRegistry),
                bondingFeeBps: bondingFeeBps
            })
        );
        ERC404BondingInstance(payable(instance)).initializeMetadata(
            identity.name, identity.symbol, identity.styleUri
        );
        // Wire free mint tranche (no-op when allocation == 0)
        ERC404BondingInstance(payable(instance)).initializeFreeMint(
            freeMint.allocation, freeMint.scope
        );
    }

    function _finalizeInstance(
        address instance,
        IdentityParams calldata identity,
        string calldata metadataURI
    ) private {
        masterRegistry.registerInstance(
            instance, address(this), identity.owner, identity.name, metadataURI, identity.vault
        );
        launchManager.applyTierPerks(
            instance,
            LaunchManager.CreationTier(uint8(identity.creationTier)),
            identity.owner
        );
        emit InstanceCreated(instance, identity.owner, identity.name, identity.symbol, identity.vault);
    }

    /**
     * @notice Get factory features
     */
    function getFeatures() external view returns (bytes32[] memory) {
        return _features;
    }

    function features() external view returns (bytes32[] memory) {
        return _features;
    }

    function protocol() external view returns (address) {
        return owner();
    }

    function setProtocolTreasury(address _treasury) external onlyRoles(PROTOCOL_ROLE) {
        require(_treasury != address(0), "Invalid treasury");
        address old = protocolTreasury;
        protocolTreasury = _treasury;
        emit ProtocolTreasuryUpdated(old, _treasury);
    }

    function withdrawProtocolFees() external onlyRoles(PROTOCOL_ROLE) {
        require(protocolTreasury != address(0), "Treasury not set");
        uint256 amount = accumulatedProtocolFees;
        require(amount > 0, "No protocol fees");
        accumulatedProtocolFees = 0;
        SafeTransferLib.safeTransferETH(protocolTreasury, amount);
        emit ProtocolFeesWithdrawn(protocolTreasury, amount);
    }

    function setBondingFeeBps(uint256 _bps) external onlyRoles(PROTOCOL_ROLE) {
        require(_bps <= 300, "Max 3%");
        bondingFeeBps = _bps;
        emit BondingFeeUpdated(_bps);
    }
}
