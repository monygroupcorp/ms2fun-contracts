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

/**
 * @title ERC404Factory
 * @notice Factory contract for deploying ERC404 token instances with ultraalignment
 * @dev Requires vault to have its hook pre-configured (created via UltraAlignmentHookFactory.createVaultWithHook)
 */
contract ERC404Factory is OwnableRoles, ReentrancyGuard, IFactory {
    uint256 public constant PROTOCOL_ROLE = _ROLE_0;  // 1 << 0 = 1
    uint256 public constant CREATOR_ROLE = _ROLE_1;   // 1 << 1 = 2

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

    constructor(
        address _implementation,
        address _masterRegistry,
        address _instanceTemplate,
        address _v4PoolManager,
        address _weth,
        address _protocol,
        address _creator,
        uint256 _creatorFeeBps,
        uint256 _creatorGraduationFeeBps,
        address _stakingModule,
        address _liquidityDeployer,
        address _globalMessageRegistry,
        address _launchManager,
        address _curveComputer
    ) {
        require(_implementation != address(0), "Invalid implementation");
        require(_protocol != address(0), "Invalid protocol");
        require(_stakingModule != address(0), "Invalid staking module");
        require(_liquidityDeployer != address(0), "Invalid liquidity deployer");
        require(_globalMessageRegistry != address(0), "Invalid global message registry");
        require(_launchManager != address(0), "Invalid launch manager");
        require(_curveComputer != address(0), "Invalid curve computer");
        _initializeOwner(_protocol);
        _grantRoles(_protocol, PROTOCOL_ROLE);
        _grantRoles(_creator, CREATOR_ROLE);
        require(_creatorFeeBps <= 10000, "Invalid creator fee bps");
        require(_creatorGraduationFeeBps <= graduationFeeBps, "Creator grad fee exceeds graduation fee");
        implementation = _implementation;
        creator = _creator;
        creatorFeeBps = _creatorFeeBps;
        creatorGraduationFeeBps = _creatorGraduationFeeBps;
        masterRegistry = IMasterRegistry(_masterRegistry);
        globalMessageRegistry = _globalMessageRegistry;
        instanceTemplate = _instanceTemplate;
        v4PoolManager = _v4PoolManager;
        weth = _weth;
        instanceCreationFee = 0.01 ether;
        stakingModule = ERC404StakingModule(_stakingModule);
        liquidityDeployer = LiquidityDeployerModule(payable(_liquidityDeployer));
        launchManager = LaunchManager(_launchManager);
        curveComputer = CurveParamsComputer(_curveComputer);
    }

    /**
     * @notice Create a new ERC404 bonding instance (defaults to STANDARD tier)
     */
    function createInstance(
        string memory name,
        string memory symbol,
        string memory metadataURI,
        uint256 nftCount,
        uint256 profileId,
        ERC404BondingInstance.TierConfig memory tierConfig,
        address instanceCreator,
        address vault,
        address hook,
        string memory styleUri
    ) external payable nonReentrant returns (address instance) {
        return _createInstanceInternal(
            name, symbol, metadataURI, nftCount, profileId,
            tierConfig, instanceCreator, vault, hook, styleUri,
            CreationTier.STANDARD
        );
    }

    /**
     * @notice Create a new ERC404 bonding instance with a specific creation tier
     */
    function createInstance(
        string memory name,
        string memory symbol,
        string memory metadataURI,
        uint256 nftCount,
        uint256 profileId,
        ERC404BondingInstance.TierConfig memory tierConfig,
        address instanceCreator,
        address vault,
        address hook,
        string memory styleUri,
        CreationTier creationTier
    ) external payable nonReentrant returns (address instance) {
        return _createInstanceInternal(
            name, symbol, metadataURI, nftCount, profileId,
            tierConfig, instanceCreator, vault, hook, styleUri,
            creationTier
        );
    }

    function _createInstanceInternal(
        string memory name,
        string memory symbol,
        string memory metadataURI,
        uint256 nftCount,
        uint256 profileId,
        ERC404BondingInstance.TierConfig memory tierConfig,
        address instanceCreator,
        address vault,
        address hook,
        string memory styleUri,
        CreationTier creationTier
    ) internal returns (address instance) {
        // Resolve fee via LaunchManager (maps our enum to theirs via uint8 cast — same ordinal)
        uint256 fee = launchManager.getTierFee(
            LaunchManager.CreationTier(uint8(creationTier)),
            instanceCreationFee
        );

        require(msg.value >= fee, "Insufficient fee");

        // Split fee between protocol and creator
        {
            uint256 creatorCut = (fee * creatorFeeBps) / 10000;
            uint256 protocolCut = fee - creatorCut;
            accumulatedCreatorFees += creatorCut;
            accumulatedProtocolFees += protocolCut;
        }

        require(nftCount > 0, "Invalid NFT count");
        require(bytes(name).length > 0, "Invalid name");
        require(bytes(symbol).length > 0, "Invalid symbol");
        require(instanceCreator != address(0), "Invalid creator");
        require(v4PoolManager != address(0), "V4 pool manager not set");
        require(weth != address(0), "WETH not set");

        // Check namespace availability before deploying (saves gas on collision)
        require(!masterRegistry.isNameTaken(name), "Name already taken");

        // Vault and hook are required for ultraalignment
        require(vault != address(0), "Vault required for ultraalignment");
        require(vault.code.length > 0, "Vault must be a contract");
        require(hook != address(0), "Hook required for ultraalignment");
        require(hook.code.length > 0, "Hook must be a contract");

        // Compute params from profile
        GraduationProfile memory profile = profiles[profileId];
        require(profile.active, "Profile not active");

        uint256 unit = profile.unitPerNFT * 1e18;
        uint256 maxSupply = nftCount * unit;
        uint256 liquidityReservePercent = profile.liquidityReserveBps / 100; // Convert bps to percent

        BondingCurveMath.Params memory curveParams = curveComputer.computeCurveParams(
            nftCount,
            profile.targetETH,
            profile.unitPerNFT,
            profile.liquidityReserveBps
        );

        // Soft capability checks — emit warnings, never revert
        try IAlignmentVault(payable(vault)).supportsCapability(keccak256("YIELD_GENERATION")) returns (bool supported) {
            if (!supported) {
                emit VaultCapabilityWarning(vault, keccak256("YIELD_GENERATION"));
            }
        } catch {
            emit VaultCapabilityWarning(vault, keccak256("YIELD_GENERATION"));
        }

        // Deploy clone and initialize with all params
        instance = LibClone.clone(implementation);
        ERC404BondingInstance(payable(instance)).initialize(
            name,
            symbol,
            maxSupply,
            liquidityReservePercent,
            curveParams,
            tierConfig,
            v4PoolManager,
            hook,
            weth,
            address(this),
            globalMessageRegistry,
            vault,
            instanceCreator,
            styleUri,
            protocolTreasury,
            bondingFeeBps,
            graduationFeeBps,
            polBps,
            creator,
            creatorGraduationFeeBps,
            profile.poolFee,
            profile.tickSpacing,
            unit,
            address(stakingModule),
            address(liquidityDeployer),
            address(curveComputer)
        );

        // Register with master registry
        masterRegistry.registerInstance(
            instance,
            address(this),
            instanceCreator,
            name,
            metadataURI,
            vault
        );

        // Apply tier perks AFTER successful deployment and registration
        launchManager.applyTierPerks(instance, LaunchManager.CreationTier(uint8(creationTier)), instanceCreator);

        // Refund excess
        if (msg.value > fee) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - fee);
        }

        emit InstanceCreated(instance, instanceCreator, name, symbol, vault, hook);

        if (creationTier != CreationTier.STANDARD) {
            emit InstanceCreatedWithTier(instance, creationTier, fee);
        }
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
