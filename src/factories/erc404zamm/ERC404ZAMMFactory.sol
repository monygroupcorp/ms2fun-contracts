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

/**
 * @title ERC404ZAMMFactory
 * @notice Factory for ERC404 bonding instances that graduate into ZAMM pools.
 *         Independent developer factory — no V4 dependencies.
 */
contract ERC404ZAMMFactory is OwnableRoles, ReentrancyGuard, IFactory {
    uint256 public constant PROTOCOL_ROLE = _ROLE_0;
    uint256 public constant CREATOR_ROLE  = _ROLE_1;

    // ── Immutables ────────────────────────────────────────────────────────────
    address public immutable globalMessageRegistry;
    address public immutable creator;
    uint256 public immutable creatorFeeBps;
    uint256 public immutable creatorGraduationFeeBps;

    // ── Config ────────────────────────────────────────────────────────────────
    IMasterRegistry public masterRegistry;
    address public implementation;
    address public zamm;
    address public zRouter;       // for future routing if needed
    uint256 public feeOrHook;     // ZAMM pool feeOrHook for all instances
    uint256 public taxBps;        // post-graduation transfer tax (e.g. 100 = 1%)
    address public protocolTreasury;
    uint256 public instanceCreationFee = 0.01 ether;

    uint256 public bondingFeeBps = 100;      // 1%
    uint256 public graduationFeeBps = 200;   // 2%

    ZAMMLiquidityDeployerModule public immutable liquidityDeployer;
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
    event TaxBpsUpdated(uint256 newBps);

    constructor(
        address _implementation,
        address _masterRegistry,
        address _zamm,
        address _zRouter,
        uint256 _feeOrHook,
        uint256 _taxBps,
        address _protocol,
        address _creator,
        uint256 _creatorFeeBps,
        uint256 _creatorGraduationFeeBps,
        address _liquidityDeployer,
        address _globalMessageRegistry,
        address _curveComputer
    ) {
        require(_implementation != address(0), "Invalid implementation");
        require(_zamm != address(0), "Invalid zamm");
        require(_protocol != address(0), "Invalid protocol");
        require(_creator != address(0), "Invalid creator");
        require(_liquidityDeployer != address(0), "Invalid deployer");
        require(_globalMessageRegistry != address(0), "Invalid GMR");
        require(_curveComputer != address(0), "Invalid curveComputer");
        require(_creatorFeeBps <= 10000, "Invalid creator fee");
        require(_creatorGraduationFeeBps <= 10000, "Invalid creator grad fee");

        _initializeOwner(_protocol);
        _grantRoles(_protocol, PROTOCOL_ROLE);
        _grantRoles(_creator, CREATOR_ROLE);

        implementation = _implementation;
        masterRegistry = IMasterRegistry(_masterRegistry);
        zamm = _zamm;
        zRouter = _zRouter;
        feeOrHook = _feeOrHook;
        taxBps = _taxBps;
        creator = _creator;
        creatorFeeBps = _creatorFeeBps;
        creatorGraduationFeeBps = _creatorGraduationFeeBps;
        liquidityDeployer = ZAMMLiquidityDeployerModule(payable(_liquidityDeployer));
        globalMessageRegistry = _globalMessageRegistry;
        curveComputer = CurveParamsComputer(_curveComputer);

        features.push(FeatureUtils.BONDING_CURVE);
        features.push(FeatureUtils.LIQUIDITY_POOL);
        features.push(FeatureUtils.CHAT);
        features.push(FeatureUtils.PORTFOLIO);
    }

    function createInstance(
        string memory name,
        string memory symbol,
        string memory metadataURI,
        uint256 nftCount,
        uint256 profileId,
        ERC404ZAMMBondingInstance.TierConfig memory tierConfig,
        address instanceCreator,
        address vault,
        string memory styleUri
    ) external payable nonReentrant returns (address instance) {
        require(msg.value >= instanceCreationFee, "Insufficient fee");
        require(nftCount > 0, "Invalid NFT count");
        require(bytes(name).length > 0, "Invalid name");
        require(instanceCreator != address(0), "Invalid creator");
        require(vault != address(0), "Vault required");
        require(vault.code.length > 0, "Vault must be contract");
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

        instance = LibClone.clone(implementation);

        // Factory calls initialize — factory address must equal msg.sender per DN404Mirror link requirement
        ERC404ZAMMBondingInstance(payable(instance)).initialize(
            name,
            symbol,
            maxSupply,
            liquidityReservePercent,
            curveParams,
            tierConfig,
            address(this),
            globalMessageRegistry,
            vault,
            instanceCreator,
            styleUri,
            protocolTreasury,
            bondingFeeBps,
            graduationFeeBps,
            creatorGraduationFeeBps,
            creator,
            unit,
            address(liquidityDeployer),
            address(curveComputer)
        );

        masterRegistry.registerInstance(instance, address(this), instanceCreator, name, metadataURI, vault);

        if (msg.value > instanceCreationFee) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - instanceCreationFee);
        }

        emit InstanceCreated(instance, instanceCreator, name, symbol, vault);
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

    function withdrawCreatorFees() external onlyRoles(CREATOR_ROLE) {
        uint256 amt = accumulatedCreatorFees;
        require(amt > 0, "No fees");
        accumulatedCreatorFees = 0;
        SafeTransferLib.safeTransferETH(creator, amt);
    }

    function getFeatures() external view returns (bytes32[] memory) { return features; }
    function protocol() external view returns (address) { return owner(); }
}
