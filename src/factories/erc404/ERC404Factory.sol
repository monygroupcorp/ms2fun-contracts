// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
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
import {ICreateX, CREATEX} from "../../shared/CreateXConstants.sol";

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

    // slither-disable-next-line immutable-states
    IMasterRegistry public masterRegistry;
    address public immutable globalMessageRegistry;
    // slither-disable-next-line immutable-states
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
    error ProtocolRoleNotTransferable();
    error InvalidAddress();
    error InvalidImplementation();
    error InvalidGlobalMessageRegistry();
    error InvalidLaunchManager();
    error InvalidComponentRegistry();
    error InvalidNftCount();
    error InvalidName();
    error InvalidSymbol();
    error InvalidOwner();
    error VaultRequired();
    error VaultMustBeContract();
    error NameAlreadyTaken();
    error FreeMintAllocationExceedsNftCount();
    error UnapprovedLiquidityDeployer();
    error UnapprovedGatingModule();
    error UnapprovedCurveComputer();
    error TreasuryNotSet();
    error NoProtocolFees();
    error MaxBondingFeeExceeded();
    error NotAuthorizedAgent();

    event ProtocolTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ProtocolFeesWithdrawn(address indexed treasury, uint256 amount);
    event BondingFeeUpdated(uint256 newBps);

    constructor(CoreConfig memory core, ModuleConfig memory modules) {
        if (core.implementation == address(0)) revert InvalidImplementation();
        if (core.protocol == address(0)) revert InvalidAddress();
        if (modules.globalMessageRegistry == address(0)) revert InvalidGlobalMessageRegistry();
        if (modules.launchManager == address(0)) revert InvalidLaunchManager();
        if (modules.componentRegistry == address(0)) revert InvalidComponentRegistry();
        _initializeOwner(core.protocol);
        _grantRoles(core.protocol, PROTOCOL_ROLE);
        implementation = core.implementation;
        masterRegistry = IMasterRegistry(core.masterRegistry);
        globalMessageRegistry = modules.globalMessageRegistry;
        launchManager = LaunchManager(modules.launchManager);
        tierGatingModule = PasswordTierGatingModule(modules.tierGatingModule);
        componentRegistry = IComponentRegistry(modules.componentRegistry);
    }

    /// @notice Transfer PROTOCOL_ROLE to a new address. Only callable by current PROTOCOL_ROLE holder.
    function transferProtocolRole(address newProtocol) external onlyRoles(PROTOCOL_ROLE) {
        if (newProtocol == address(0)) revert InvalidAddress();
        _removeRoles(msg.sender, PROTOCOL_ROLE);
        _grantRoles(newProtocol, PROTOCOL_ROLE);
    }

    /// @dev Prevent owner from granting/revoking PROTOCOL_ROLE via the base OwnableRoles interface.
    function grantRoles(address user, uint256 roles) public payable override onlyOwner {
        if (roles & PROTOCOL_ROLE != 0) revert ProtocolRoleNotTransferable();
        super.grantRoles(user, roles);
    }

    /// @dev Prevent owner from granting/revoking PROTOCOL_ROLE via the base OwnableRoles interface.
    function revokeRoles(address user, uint256 roles) public payable override onlyOwner {
        if (roles & PROTOCOL_ROLE != 0) revert ProtocolRoleNotTransferable();
        super.revokeRoles(user, roles);
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
            if (!componentRegistry.isApprovedComponent(gatingModule)) revert UnapprovedGatingModule();
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
        // slither-disable-next-line uninitialized-local
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
        if (identity.nftCount == 0) revert InvalidNftCount();
        if (bytes(identity.name).length == 0) revert InvalidName();
        if (bytes(identity.symbol).length == 0) revert InvalidSymbol();
        if (identity.owner == address(0)) revert InvalidOwner();
        if (identity.vault == address(0)) revert VaultRequired();
        if (identity.vault.code.length == 0) revert VaultMustBeContract();

        // Agent-on-behalf-of check
        bool agentCreated = false;
        if (msg.sender != identity.owner) {
            if (!masterRegistry.isAgent(msg.sender)) revert NotAuthorizedAgent();
            agentCreated = true;
        }

        if (masterRegistry.isNameTaken(identity.name)) revert NameAlreadyTaken();
        if (freeMint.allocation >= identity.nftCount) revert FreeMintAllocationExceedsNftCount();

        // Validate liquidity deployer
        if (!componentRegistry.isApprovedComponent(liquidityDeployer)) revert UnapprovedLiquidityDeployer();

        // Soft vault capability check
        try IAlignmentVault(payable(identity.vault)).supportsCapability(keccak256("YIELD_GENERATION"))
            returns (bool supported) {
            if (!supported) emit VaultCapabilityWarning(identity.vault, keccak256("YIELD_GENERATION"));
        } catch {
            emit VaultCapabilityWarning(identity.vault, keccak256("YIELD_GENERATION"));
        }

        // Deploy EIP-1167 minimal proxy via CREATE3 for deterministic vanity address
        bytes memory proxyCreationCode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            implementation,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        instance = ICreateX(CREATEX).deployCreate3(identity.salt, proxyCreationCode);
        _initializeInstance(instance, identity, liquidityDeployer, gatingModule, freeMint, agentCreated);
        _finalizeInstance(instance, identity, metadataURI);
    }

    function _initializeInstance(
        address instance,
        IdentityParams calldata identity,
        address liquidityDeployer,
        address gatingModule,
        FreeMintParams calldata freeMint,
        bool agentCreated
    ) private {
        // Fetch preset and validate its curve computer
        LaunchManager.Preset memory preset = launchManager.getPreset(identity.presetId);
        if (!componentRegistry.isApprovedComponent(preset.curveComputer)) revert UnapprovedCurveComputer();

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
        if (agentCreated) {
            ERC404BondingInstance(payable(instance)).setAgentDelegationFromFactory();
        }
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

    function requiredFeatures() external pure returns (bytes32[] memory) {
        bytes32[] memory req = new bytes32[](1);
        req[0] = FeatureUtils.LIQUIDITY_DEPLOYER;
        return req;
    }

    function protocol() external view returns (address) {
        return owner();
    }

    function setProtocolTreasury(address _treasury) external onlyRoles(PROTOCOL_ROLE) {
        if (_treasury == address(0)) revert InvalidAddress();
        address old = protocolTreasury;
        protocolTreasury = _treasury;
        emit ProtocolTreasuryUpdated(old, _treasury);
    }

    function withdrawProtocolFees() external onlyRoles(PROTOCOL_ROLE) {
        if (protocolTreasury == address(0)) revert TreasuryNotSet();
        uint256 amount = accumulatedProtocolFees;
        if (amount == 0) revert NoProtocolFees();
        accumulatedProtocolFees = 0;
        SafeTransferLib.safeTransferETH(protocolTreasury, amount);
        emit ProtocolFeesWithdrawn(protocolTreasury, amount);
    }

    function setBondingFeeBps(uint256 _bps) external onlyRoles(PROTOCOL_ROLE) {
        if (_bps > 300) revert MaxBondingFeeExceeded();
        bondingFeeBps = _bps;
        emit BondingFeeUpdated(_bps);
    }

    /// @notice Preview the deterministic address for a given salt
    function computeInstanceAddress(bytes32 salt) external view returns (address) {
        bytes32 guardedSalt = keccak256(abi.encodePacked(uint256(uint160(address(this))), salt));
        return ICreateX(CREATEX).computeCreate3Address(guardedSalt, CREATEX);
    }
}
