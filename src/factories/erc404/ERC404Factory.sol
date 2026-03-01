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
import {ERC404BondingInstance} from "./ERC404BondingInstance.sol";
import {ERC404StakingModule} from "./ERC404StakingModule.sol";
import {LiquidityDeployerModule} from "./LiquidityDeployerModule.sol";
import {LaunchManager} from "./LaunchManager.sol";
import {CurveParamsComputer} from "./CurveParamsComputer.sol";
import {BondingCurveMath} from "./libraries/BondingCurveMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {IdentityParams} from "../../interfaces/IFactoryTypes.sol";
import {PasswordTierGatingModule} from "../../gating/PasswordTierGatingModule.sol";
import {IGatingModule} from "../../gating/IGatingModule.sol";

interface IUltraAlignmentVaultV1 {
    function hook() external view returns (address);
}

/**
 * @title ERC404Factory
 * @notice Factory contract for deploying ERC404 token instances with ultraalignment
 * @dev Requires vault to have its hook pre-configured (created via UltraAlignmentHookFactory.createVaultWithHook)
 */
contract ERC404Factory is OwnableRoles, ReentrancyGuard, IFactory {
    uint256 public constant PROTOCOL_ROLE = _ROLE_0;  // 1 << 0 = 1
    uint256 public constant CREATOR_ROLE = _ROLE_1;   // 1 << 1 = 2

    /// @dev Packs constructor params into structs to stay within the 16-local Yul stack limit.
    struct CoreConfig {
        address implementation;
        address masterRegistry;
        address instanceTemplate;
        address v4PoolManager;
        address weth;
        address protocol;
        address creator;
        uint256 creatorFeeBps;
        uint256 creatorGraduationFeeBps;
    }
    struct ModuleConfig {
        address stakingModule;
        address liquidityDeployer;
        address globalMessageRegistry;
        address launchManager;
        address curveComputer;
        address tierGatingModule;
    }

    IMasterRegistry public masterRegistry;
    address public immutable globalMessageRegistry;
    address public instanceTemplate;
    address public implementation;
    uint256 public instanceCreationFee;
    address public v4PoolManager;
    address public weth;

    // Protocol revenue
    address public protocolTreasury;
    uint256 public bondingFeeBps = 100; // 1% default
    uint256 public graduationFeeBps = 200; // 2% default
    uint256 public polBps = 100; // 1% default — protocol-owned liquidity

    // Creator incentives
    address public immutable creator;
    uint256 public immutable creatorFeeBps;
    uint256 public immutable creatorGraduationFeeBps;
    uint256 public accumulatedCreatorFees;
    uint256 public accumulatedProtocolFees;

    // Modules
    ERC404StakingModule public immutable stakingModule;
    LiquidityDeployerModule public immutable liquidityDeployer;
    LaunchManager public immutable launchManager;
    CurveParamsComputer public immutable curveComputer;
    PasswordTierGatingModule public immutable tierGatingModule;

    // Tiered creation — enum kept here for backward-compatible external ABI
    enum CreationTier { STANDARD, PREMIUM, LAUNCH }

    // Feature matrix
    bytes32[] public features = [
        FeatureUtils.BONDING_CURVE,
        FeatureUtils.LIQUIDITY_POOL,
        FeatureUtils.CHAT,
        FeatureUtils.PORTFOLIO
    ];

    // Graduation profiles (protocol-defined)
    struct GraduationProfile {
        uint256 targetETH;
        uint256 unitPerNFT;
        uint24 poolFee;
        int24 tickSpacing;
        uint256 liquidityReserveBps;
        bool active;
    }

    mapping(uint256 => GraduationProfile) public profiles;

    event ProfileUpdated(uint256 indexed profileId, uint256 targetETH, bool active);
    event InstanceCreated(
        address indexed instance,
        address indexed creator,
        string name,
        string symbol,
        address indexed vault,
        address hook
    );
    event InstanceCreationFeeUpdated(uint256 newFee);
    event VaultCapabilityWarning(address indexed vault, bytes32 indexed capability);
    event ProtocolTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ProtocolFeesWithdrawn(address indexed treasury, uint256 amount);
    event CreatorFeesWithdrawn(address indexed creator, uint256 amount);
    event BondingFeeUpdated(uint256 newBps);
    event GraduationFeeUpdated(uint256 newBps);
    event POLConfigUpdated(uint256 newBps);
    event InstanceCreatedWithTier(address indexed instance, CreationTier tier, uint256 fee);

    constructor(CoreConfig memory core, ModuleConfig memory modules) {
        require(core.implementation != address(0), "Invalid implementation");
        require(core.protocol != address(0), "Invalid protocol");
        require(modules.stakingModule != address(0), "Invalid staking module");
        require(modules.liquidityDeployer != address(0), "Invalid liquidity deployer");
        require(modules.globalMessageRegistry != address(0), "Invalid global message registry");
        require(modules.launchManager != address(0), "Invalid launch manager");
        require(modules.curveComputer != address(0), "Invalid curve computer");
        _initializeOwner(core.protocol);
        _grantRoles(core.protocol, PROTOCOL_ROLE);
        _grantRoles(core.creator, CREATOR_ROLE);
        require(core.creatorFeeBps <= 10000, "Invalid creator fee bps");
        require(core.creatorGraduationFeeBps <= graduationFeeBps, "Creator grad fee exceeds graduation fee");
        implementation = core.implementation;
        creator = core.creator;
        creatorFeeBps = core.creatorFeeBps;
        creatorGraduationFeeBps = core.creatorGraduationFeeBps;
        masterRegistry = IMasterRegistry(core.masterRegistry);
        globalMessageRegistry = modules.globalMessageRegistry;
        instanceTemplate = core.instanceTemplate;
        v4PoolManager = core.v4PoolManager;
        weth = core.weth;
        instanceCreationFee = 0.01 ether;
        stakingModule = ERC404StakingModule(modules.stakingModule);
        liquidityDeployer = LiquidityDeployerModule(payable(modules.liquidityDeployer));
        launchManager = LaunchManager(modules.launchManager);
        curveComputer = CurveParamsComputer(modules.curveComputer);
        tierGatingModule = PasswordTierGatingModule(modules.tierGatingModule);
    }

    /// @notice Create an instance with open gating (no password tiers).
    function createInstance(
        IdentityParams calldata identity,
        string calldata metadataURI,
        CreationTier creationTier
    ) external payable nonReentrant returns (address instance) {
        PasswordTierGatingModule.TierConfig memory emptyConfig;
        return _createInstanceInternal(identity, metadataURI, emptyConfig, creationTier);
    }

    /// @notice Create an instance with password-tier gating.
    function createInstanceWithTiers(
        IdentityParams calldata identity,
        string calldata metadataURI,
        PasswordTierGatingModule.TierConfig calldata tiers,
        CreationTier creationTier
    ) external payable nonReentrant returns (address instance) {
        return _createInstanceInternal(identity, metadataURI, tiers, creationTier);
    }

    function _createInstanceInternal(
        IdentityParams calldata identity,
        string calldata metadataURI,
        PasswordTierGatingModule.TierConfig memory tiers,
        CreationTier creationTier
    ) internal returns (address instance) {
        // Fee
        uint256 fee = launchManager.getTierFee(
            LaunchManager.CreationTier(uint8(creationTier)),
            instanceCreationFee
        );
        require(msg.value >= fee, "Insufficient fee");
        {
            uint256 creatorCut = (fee * creatorFeeBps) / 10000;
            uint256 protocolCut = fee - creatorCut;
            accumulatedCreatorFees += creatorCut;
            accumulatedProtocolFees += protocolCut;
        }

        // Validate identity
        require(identity.nftCount > 0, "Invalid NFT count");
        require(bytes(identity.name).length > 0, "Invalid name");
        require(bytes(identity.symbol).length > 0, "Invalid symbol");
        require(identity.owner != address(0), "Invalid owner");
        require(identity.vault != address(0), "Vault required");
        require(identity.vault.code.length > 0, "Vault must be a contract");
        require(!masterRegistry.isNameTaken(identity.name), "Name already taken");

        // Resolve hook from vault
        address hook;
        try IUltraAlignmentVaultV1(payable(identity.vault)).hook() returns (address h) {
            hook = h;
        } catch {}
        require(hook != address(0) && hook.code.length > 0, "Vault hook required");

        // Soft vault capability check
        try IAlignmentVault(payable(identity.vault)).supportsCapability(keccak256("YIELD_GENERATION"))
            returns (bool supported) {
            if (!supported) emit VaultCapabilityWarning(identity.vault, keccak256("YIELD_GENERATION"));
        } catch {
            emit VaultCapabilityWarning(identity.vault, keccak256("YIELD_GENERATION"));
        }

        // Compute BondingParams from profile
        ERC404BondingInstance.BondingParams memory bonding = _computeBondingParams(identity.nftCount, identity.profileId);

        // Assemble ProtocolParams
        ERC404BondingInstance.ProtocolParams memory protocol = _getProtocolParams();

        // Deploy clone
        instance = LibClone.clone(implementation);

        // Configure gating module (before initialize)
        address gatingModuleAddr = _configureGating(instance, tiers);

        _initializeInstance(instance, identity.owner, identity.vault, bonding, protocol, hook, gatingModuleAddr);
        _setMetadata(instance, identity);
        _finalizeInstance(instance, identity, metadataURI, hook, creationTier, fee);
    }

    function _finalizeInstance(
        address instance,
        IdentityParams calldata identity,
        string calldata metadataURI,
        address hook,
        CreationTier creationTier,
        uint256 fee
    ) private {
        masterRegistry.registerInstance(
            instance, address(this), identity.owner, identity.name, metadataURI, identity.vault
        );
        launchManager.applyTierPerks(instance, LaunchManager.CreationTier(uint8(creationTier)), identity.owner);
        if (msg.value > fee) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - fee);
        }
        emit InstanceCreated(instance, identity.owner, identity.name, identity.symbol, identity.vault, hook);
        if (creationTier != CreationTier.STANDARD) {
            emit InstanceCreatedWithTier(instance, creationTier, fee);
        }
    }

    function _configureGating(
        address instance,
        PasswordTierGatingModule.TierConfig memory tiers
    ) private returns (address gatingModuleAddr) {
        if (tiers.passwordHashes.length > 0) {
            tierGatingModule.configureFor(instance, tiers);
            gatingModuleAddr = address(tierGatingModule);
        }
    }

    function _initializeInstance(
        address instance,
        address owner,
        address vault_,
        ERC404BondingInstance.BondingParams memory bonding,
        ERC404BondingInstance.ProtocolParams memory protocol,
        address hook,
        address gatingModuleAddr
    ) private {
        ERC404BondingInstance(payable(instance)).initialize(owner, vault_, bonding, hook, gatingModuleAddr);
        ERC404BondingInstance(payable(instance)).initializeProtocol(protocol);
    }

    function _setMetadata(address instance, IdentityParams calldata identity) private {
        ERC404BondingInstance(payable(instance)).initializeMetadata(
            identity.name, identity.symbol, identity.styleUri
        );
    }

    function _computeBondingParams(
        uint256 nftCount,
        uint8 profileId
    ) private view returns (ERC404BondingInstance.BondingParams memory bonding) {
        GraduationProfile memory profile = profiles[profileId];
        require(profile.active, "Profile not active");
        uint256 unit = profile.unitPerNFT * 1e18;
        bonding = ERC404BondingInstance.BondingParams({
            maxSupply: nftCount * unit,
            unit: unit,
            liquidityReservePercent: profile.liquidityReserveBps / 100,
            curve: curveComputer.computeCurveParams(
                nftCount, profile.targetETH, profile.unitPerNFT, profile.liquidityReserveBps
            ),
            poolFee: profile.poolFee,
            tickSpacing: profile.tickSpacing
        });
    }

    function _getProtocolParams() private view returns (ERC404BondingInstance.ProtocolParams memory) {
        return ERC404BondingInstance.ProtocolParams({
            globalMessageRegistry: globalMessageRegistry,
            protocolTreasury: protocolTreasury,
            masterRegistry: address(masterRegistry),
            stakingModule: address(stakingModule),
            liquidityDeployer: address(liquidityDeployer),
            curveComputer: address(curveComputer),
            v4PoolManager: v4PoolManager,
            weth: weth,
            bondingFeeBps: bondingFeeBps,
            graduationFeeBps: graduationFeeBps,
            polBps: polBps,
            factoryCreator: creator,
            creatorGraduationFeeBps: creatorGraduationFeeBps
        });
    }

    /**
     * @notice Get factory features
     */
    function getFeatures() external view returns (bytes32[] memory) {
        return features;
    }

    /**
     * @notice Set instance creation fee (owner only)
     */
    function setInstanceCreationFee(uint256 _fee) external onlyRoles(PROTOCOL_ROLE) {
        instanceCreationFee = _fee;
        emit InstanceCreationFeeUpdated(_fee);
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

    function withdrawCreatorFees() external onlyRoles(CREATOR_ROLE) {
        uint256 amount = accumulatedCreatorFees;
        require(amount > 0, "No creator fees");
        accumulatedCreatorFees = 0;
        SafeTransferLib.safeTransferETH(creator, amount);
        emit CreatorFeesWithdrawn(creator, amount);
    }

    function protocol() external view returns (address) {
        return owner();
    }

    function setBondingFeeBps(uint256 _bps) external onlyRoles(PROTOCOL_ROLE) {
        require(_bps <= 300, "Max 3%");
        bondingFeeBps = _bps;
        emit BondingFeeUpdated(_bps);
    }

    function setGraduationFeeBps(uint256 _bps) external onlyRoles(PROTOCOL_ROLE) {
        require(_bps <= 500, "Max 5%");
        graduationFeeBps = _bps;
        emit GraduationFeeUpdated(_bps);
    }

    function setPolBps(uint256 _bps) external onlyRoles(PROTOCOL_ROLE) {
        require(_bps <= 300, "Max 3%");
        polBps = _bps;
        emit POLConfigUpdated(_bps);
    }

    function setProfile(uint256 profileId, GraduationProfile calldata profile) external onlyRoles(PROTOCOL_ROLE) {
        require(profile.targetETH > 0, "Invalid target ETH");
        require(profile.unitPerNFT > 0, "Invalid unit");
        // poolFee > 0 allows both static fees (e.g. 3000) and DYNAMIC_FEE_FLAG (0x800000)
        require(profile.poolFee > 0, "Invalid pool fee");
        require(profile.tickSpacing > 0, "Invalid tick spacing");
        require(profile.liquidityReserveBps > 0 && profile.liquidityReserveBps < 10000, "Invalid reserve bps");
        profiles[profileId] = profile;
        emit ProfileUpdated(profileId, profile.targetETH, profile.active);
    }
}
