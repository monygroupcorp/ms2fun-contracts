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
import {IComponentRegistry} from "../../registry/interfaces/IComponentRegistry.sol";
import {FreeMintParams} from "../../interfaces/IFactoryTypes.sol";
import {GatingScope} from "../../gating/IGatingModule.sol";
import {ICreateX, CREATEX} from "../../shared/CreateXConstants.sol";

/**
 * @title ERC404Factory
 * @notice Deploys and registers ERC404 bonding token instances.
 *         Single responsibility: validate → deploy via CREATE3 → register.
 *         Protocol fees flow directly to treasury — no custody.
 *         Bonding curve params are derived from LaunchManager presets.
 */
contract ERC404Factory is OwnableRoles, ReentrancyGuard, IFactory {
    uint256 public constant PROTOCOL_ROLE = _ROLE_0;  // 1 << 0 = 1

    /// @dev Infrastructure only — no AMM-specific addresses.
    struct CoreConfig {
        address implementation;
        address masterRegistry;
        address protocol;
        address weth;
    }

    /// @dev Module addresses.
    struct ModuleConfig {
        address globalMessageRegistry;
        address componentRegistry;
        address launchManager;
    }

    /// @notice Parameters for instance creation.
    struct CreateParams {
        bytes32 salt;
        string name;
        string symbol;
        string styleUri;
        address owner;
        address vault;
        uint256 nftCount;
        uint8 presetId;
        address stakingModule; // address(0) = staking not available for this instance
    }

    // slither-disable-next-line immutable-states
    IMasterRegistry public masterRegistry;
    address public immutable globalMessageRegistry;
    // slither-disable-next-line immutable-states
    address public implementation;

    address public protocolTreasury;
    address public weth;
    uint256 public bondingFeeBps = 100; // 1% default

    LaunchManager public immutable launchManager;
    IComponentRegistry public immutable componentRegistry;

    bytes32[] internal _features = [FeatureUtils.GATING, FeatureUtils.LIQUIDITY_DEPLOYER, FeatureUtils.STAKING];

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
    error UnapprovedStakingModule();
    error UnapprovedCurveComputer();
    error MaxBondingFeeExceeded();
    error NotAuthorizedAgent();

    event ProtocolTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
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
        weth = core.weth;
        globalMessageRegistry = modules.globalMessageRegistry;
        launchManager = LaunchManager(modules.launchManager);
        componentRegistry = IComponentRegistry(modules.componentRegistry);
    }

    /// @notice Transfer PROTOCOL_ROLE to a new address.
    function transferProtocolRole(address newProtocol) external onlyRoles(PROTOCOL_ROLE) {
        if (newProtocol == address(0)) revert InvalidAddress();
        _removeRoles(msg.sender, PROTOCOL_ROLE);
        _grantRoles(newProtocol, PROTOCOL_ROLE);
    }

    /// @dev Prevent owner from granting/revoking PROTOCOL_ROLE via base OwnableRoles.
    function grantRoles(address user, uint256 roles) public payable override onlyOwner {
        if (roles & PROTOCOL_ROLE != 0) revert ProtocolRoleNotTransferable();
        super.grantRoles(user, roles);
    }

    /// @dev Prevent owner from granting/revoking PROTOCOL_ROLE via base OwnableRoles.
    function revokeRoles(address user, uint256 roles) public payable override onlyOwner {
        if (roles & PROTOCOL_ROLE != 0) revert ProtocolRoleNotTransferable();
        super.revokeRoles(user, roles);
    }

    /// @notice Create an instance with a caller-supplied liquidity deployer and optional gating module.
    ///         Any ETH forwarded goes directly to treasury — factory holds no ETH.
    function createInstance(
        CreateParams calldata params,
        string calldata metadataURI,
        address liquidityDeployer,
        address gatingModule,
        FreeMintParams calldata freeMint
    ) external payable nonReentrant returns (address instance) {
        if (gatingModule != address(0)) {
            if (!componentRegistry.isApprovedComponent(gatingModule)) revert UnapprovedGatingModule();
        }
        if (params.stakingModule != address(0)) {
            if (!componentRegistry.isApprovedComponent(params.stakingModule)) revert UnapprovedStakingModule();
        }

        // Forward fee directly to treasury — factory holds no ETH
        if (msg.value > 0 && protocolTreasury != address(0)) {
            SafeTransferLib.safeTransferETH(protocolTreasury, msg.value);
        }

        // Validate params
        if (params.nftCount == 0) revert InvalidNftCount();
        if (bytes(params.name).length == 0) revert InvalidName();
        if (bytes(params.symbol).length == 0) revert InvalidSymbol();
        if (params.owner == address(0)) revert InvalidOwner();
        if (params.vault == address(0)) revert VaultRequired();
        if (params.vault.code.length == 0) revert VaultMustBeContract();

        // Agent-on-behalf-of check
        bool agentCreated = false;
        if (msg.sender != params.owner) {
            if (!masterRegistry.isAgent(msg.sender)) revert NotAuthorizedAgent();
            agentCreated = true;
        }

        if (masterRegistry.isNameTaken(params.name)) revert NameAlreadyTaken();
        if (freeMint.allocation >= params.nftCount) revert FreeMintAllocationExceedsNftCount();

        // Validate liquidity deployer
        if (!componentRegistry.isApprovedComponent(liquidityDeployer)) revert UnapprovedLiquidityDeployer();

        // Soft vault capability check — YIELD_GENERATION is expected for ERC404 staking rewards
        try IAlignmentVault(payable(params.vault)).supportsCapability(keccak256("YIELD_GENERATION"))
            returns (bool supported) {
            if (!supported) emit VaultCapabilityWarning(params.vault, keccak256("YIELD_GENERATION"));
        } catch {
            emit VaultCapabilityWarning(params.vault, keccak256("YIELD_GENERATION"));
        }

        instance = _deployAndInitialize(params, liquidityDeployer, gatingModule, freeMint, agentCreated);
        masterRegistry.registerInstance(
            instance, address(this), params.owner, params.name, metadataURI, params.vault
        );
        // Staking wired after registration — module's enableStaking checks isRegisteredInstance
        if (params.stakingModule != address(0)) {
            ERC404BondingInstance(payable(instance)).initializeStaking(params.stakingModule);
        }
        emit InstanceCreated(instance, params.owner, params.name, params.symbol, params.vault);
    }

    function _deployAndInitialize(
        CreateParams calldata params,
        address liquidityDeployer,
        address gatingModule,
        FreeMintParams calldata freeMint,
        bool agentCreated
    ) private returns (address instance) {
        // Fetch preset and validate its curve computer
        LaunchManager.Preset memory preset = launchManager.getPreset(params.presetId);
        if (!componentRegistry.isApprovedComponent(preset.curveComputer)) revert UnapprovedCurveComputer();

        uint256 unit = preset.unitPerNFT * 1e18;
        uint256 curveNftCount = params.nftCount - freeMint.allocation;
        ERC404BondingInstance.BondingParams memory bonding = ERC404BondingInstance.BondingParams({
            maxSupply: params.nftCount * unit,
            unit: unit,
            liquidityReserveBps: preset.liquidityReserveBps,
            curve: ICurveComputer(preset.curveComputer).computeCurveParams(
                curveNftCount,
                preset.targetETH,
                preset.unitPerNFT,
                preset.liquidityReserveBps
            )
        });

        // Deploy EIP-1167 minimal proxy via CREATE3.
        // Bind salt to msg.sender to prevent front-running.
        bytes memory proxyCreationCode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            implementation,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        bytes32 senderBoundSalt = keccak256(abi.encodePacked(msg.sender, params.salt));
        instance = ICreateX(CREATEX).deployCreate3(senderBoundSalt, proxyCreationCode);

        ERC404BondingInstance(payable(instance)).initialize(
            params.owner, params.vault, bonding, liquidityDeployer, gatingModule
        );
        ERC404BondingInstance(payable(instance)).initializeProtocol(
            ERC404BondingInstance.ProtocolParams({
                globalMessageRegistry: globalMessageRegistry,
                protocolTreasury: protocolTreasury,
                masterRegistry: address(masterRegistry),
                bondingFeeBps: bondingFeeBps,
                weth: weth
            })
        );
        ERC404BondingInstance(payable(instance)).initializeMetadata(
            params.name, params.symbol, params.styleUri
        );
        ERC404BondingInstance(payable(instance)).initializeFreeMint(
            freeMint.allocation, freeMint.scope
        );
        if (agentCreated) {
            ERC404BondingInstance(payable(instance)).setAgentDelegationFromFactory();
        }
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setProtocolTreasury(address _treasury) external onlyRoles(PROTOCOL_ROLE) {
        if (_treasury == address(0)) revert InvalidAddress();
        address old = protocolTreasury;
        protocolTreasury = _treasury;
        emit ProtocolTreasuryUpdated(old, _treasury);
    }

    function setWeth(address _weth) external onlyRoles(PROTOCOL_ROLE) {
        if (_weth == address(0)) revert InvalidAddress();
        weth = _weth;
    }

    function setBondingFeeBps(uint256 _bps) external onlyRoles(PROTOCOL_ROLE) {
        if (_bps > 300) revert MaxBondingFeeExceeded();
        bondingFeeBps = _bps;
        emit BondingFeeUpdated(_bps);
    }

    // ── IFactory ─────────────────────────────────────────────────────────────

    function protocol() external view returns (address) {
        return owner();
    }

    function features() external view returns (bytes32[] memory) {
        return _features;
    }

    function requiredFeatures() external pure returns (bytes32[] memory) {
        bytes32[] memory req = new bytes32[](1);
        req[0] = FeatureUtils.LIQUIDITY_DEPLOYER;
        return req;
    }

    // ── Utilities ────────────────────────────────────────────────────────────

    /// @notice Preview the deterministic address for a given (creator, salt) pair.
    function computeInstanceAddress(address creator, bytes32 salt) external view returns (address) {
        bytes32 senderBoundSalt = keccak256(abi.encodePacked(creator, salt));
        bytes32 guardedSalt = keccak256(abi.encodePacked(uint256(uint160(address(this))), senderBoundSalt));
        return ICreateX(CREATEX).computeCreate3Address(guardedSalt, CREATEX);
    }
}
