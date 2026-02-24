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
import {UltraAlignmentCypherVaultFactory} from "../../vaults/cypher/UltraAlignmentCypherVaultFactory.sol";
import {UltraAlignmentCypherVault} from "../../vaults/cypher/UltraAlignmentCypherVault.sol";
import {CurveParamsComputer} from "../erc404/CurveParamsComputer.sol";
import {BondingCurveMath} from "../erc404/libraries/BondingCurveMath.sol";

/**
 * @title ERC404CypherFactory
 * @notice Factory for ERC404 bonding instances that graduate into Algebra V2 (Cypher AMM) full-range LP pools.
 *         Creates one vault per instance at creation time.
 */
contract ERC404CypherFactory is OwnableRoles, ReentrancyGuard, IFactory {
    uint256 public constant PROTOCOL_ROLE = _ROLE_0;
    uint256 public constant CREATOR_ROLE  = _ROLE_1;

    // ── Immutables ────────────────────────────────────────────────────────────
    address public immutable globalMessageRegistry;
    address public immutable creator;
    uint256 public immutable creatorFeeBps;
    uint256 public immutable creatorGraduationFeeBps;

    // Algebra V2 config (immutable after construction)
    address public immutable algebraFactory;
    address public immutable positionManager;
    address public immutable swapRouter;
    address public immutable weth;

    // ── Config ────────────────────────────────────────────────────────────────
    IMasterRegistry public masterRegistry;
    address public implementation;
    address public protocolTreasury;
    uint256 public instanceCreationFee = 0.01 ether;

    uint256 public bondingFeeBps = 100;      // 1%
    uint256 public graduationFeeBps = 200;   // 2%

    CypherLiquidityDeployerModule public immutable liquidityDeployer;
    UltraAlignmentCypherVaultFactory public immutable vaultFactory;
    CurveParamsComputer public immutable curveComputer;

    // Accumulated fees
    uint256 public accumulatedCreatorFees;
    uint256 public accumulatedProtocolFees;

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
    event InstanceCreationFeeUpdated(uint256 newFee);

    constructor(
        address _implementation,
        address _masterRegistry,
        address _vaultFactory,
        address _liquidityDeployer,
        address _algebraFactory,
        address _positionManager,
        address _swapRouter,
        address _weth,
        address _protocol,
        address _creator,
        uint256 _creatorFeeBps,
        uint256 _creatorGraduationFeeBps,
        address _globalMessageRegistry,
        address _curveComputer
    ) {
        require(_implementation != address(0), "Invalid implementation");
        require(_vaultFactory != address(0), "Invalid vault factory");
        require(_liquidityDeployer != address(0), "Invalid deployer");
        require(_weth != address(0), "Invalid weth");
        // _algebraFactory, _positionManager, _swapRouter may be address(0) for placeholder deployments
        require(_protocol != address(0), "Invalid protocol");
        require(_creator != address(0), "Invalid creator");
        require(_globalMessageRegistry != address(0), "Invalid GMR");
        require(_curveComputer != address(0), "Invalid curveComputer");
        require(_creatorFeeBps <= 10000, "Invalid creator fee");
        require(_creatorGraduationFeeBps <= 10000, "Invalid creator grad fee");

        _initializeOwner(_protocol);
        _grantRoles(_protocol, PROTOCOL_ROLE);
        _grantRoles(_creator, CREATOR_ROLE);

        implementation = _implementation;
        masterRegistry = IMasterRegistry(_masterRegistry);
        creator = _creator;
        creatorFeeBps = _creatorFeeBps;
        creatorGraduationFeeBps = _creatorGraduationFeeBps;
        liquidityDeployer = CypherLiquidityDeployerModule(payable(_liquidityDeployer));
        vaultFactory = UltraAlignmentCypherVaultFactory(_vaultFactory);
        globalMessageRegistry = _globalMessageRegistry;
        curveComputer = CurveParamsComputer(_curveComputer);
        algebraFactory = _algebraFactory;
        positionManager = _positionManager;
        swapRouter = _swapRouter;
        weth = _weth;

        features.push(FeatureUtils.BONDING_CURVE);
        features.push(FeatureUtils.LIQUIDITY_POOL);
        features.push(FeatureUtils.CHAT);
        features.push(FeatureUtils.PORTFOLIO);
    }

    /**
     * @notice Create a new ERC404 Cypher bonding instance with a dedicated vault.
     * @param alignmentTarget The alignment token address used in the vault.
     */
    function createInstance(
        string memory name,
        string memory symbol,
        string memory metadataURI,
        uint256 nftCount,
        uint256 profileId,
        ERC404CypherBondingInstance.TierConfig memory tierConfig,
        address instanceCreator,
        address alignmentTarget,
        string memory styleUri
    ) external payable nonReentrant returns (address instance) {
        require(msg.value >= instanceCreationFee, "Insufficient fee");
        require(nftCount > 0, "Invalid NFT count");
        require(bytes(name).length > 0, "Invalid name");
        require(instanceCreator != address(0), "Invalid creator");
        require(alignmentTarget != address(0), "Invalid alignment target");
        require(!masterRegistry.isNameTaken(name), "Name taken");

        // Fee split
        {
            uint256 creatorCut = (instanceCreationFee * creatorFeeBps) / 10000;
            accumulatedCreatorFees += creatorCut;
            accumulatedProtocolFees += instanceCreationFee - creatorCut;
        }

        GraduationProfile memory profile = profiles[profileId];
        require(profile.active, "Profile not active");

        uint256 unit = profile.unitPerNFT * 1e18;
        uint256 maxSupply = nftCount * unit;
        uint256 liquidityReservePercent = profile.liquidityReserveBps / 100;

        BondingCurveMath.Params memory curveParams = curveComputer.computeCurveParams(
            nftCount,
            profile.targetETH,
            profile.unitPerNFT,
            profile.liquidityReserveBps
        );

        // Clone the instance implementation
        instance = LibClone.clone(implementation);

        // Deploy a dedicated vault for this instance
        UltraAlignmentCypherVault vault = vaultFactory.createVault(
            positionManager,
            swapRouter,
            weth,
            alignmentTarget,
            creator,
            creatorGraduationFeeBps,
            protocolTreasury != address(0) ? protocolTreasury : owner(),
            address(liquidityDeployer)
        );

        // Factory calls initialize — factory address must match for DN404Mirror link
        ERC404CypherBondingInstance(payable(instance)).initialize(
            name,
            symbol,
            maxSupply,
            liquidityReservePercent,
            curveParams,
            tierConfig,
            address(this),
            globalMessageRegistry,
            address(vault),
            instanceCreator,
            styleUri,
            protocolTreasury,
            bondingFeeBps,
            graduationFeeBps,
            creatorGraduationFeeBps,
            creator,
            unit,
            address(liquidityDeployer),
            address(curveComputer),
            address(masterRegistry),
            weth,
            algebraFactory,
            positionManager
        );

        masterRegistry.registerInstance(instance, address(this), instanceCreator, name, metadataURI, address(vault));

        if (msg.value > instanceCreationFee) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - instanceCreationFee);
        }

        emit InstanceCreated(instance, instanceCreator, name, symbol, address(vault));
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

    function setInstanceCreationFee(uint256 fee) external onlyRoles(PROTOCOL_ROLE) {
        instanceCreationFee = fee;
        emit InstanceCreationFeeUpdated(fee);
    }

    function withdrawProtocolFees() external onlyRoles(PROTOCOL_ROLE) {
        require(protocolTreasury != address(0), "No treasury");
        uint256 amt = accumulatedProtocolFees;
        require(amt > 0, "No fees");
        accumulatedProtocolFees = 0;
        SafeTransferLib.safeTransferETH(protocolTreasury, amt);
    }

    function withdrawCreatorFees() external onlyRoles(CREATOR_ROLE) {
        uint256 amt = accumulatedCreatorFees;
        require(amt > 0, "No fees");
        accumulatedCreatorFees = 0;
        SafeTransferLib.safeTransferETH(creator, amt);
    }

    function getFeatures() external view returns (bytes32[] memory) { return features; }
    function protocol() external view returns (address) { return owner(); }
}
