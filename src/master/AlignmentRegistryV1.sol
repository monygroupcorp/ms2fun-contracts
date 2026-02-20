// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {IAlignmentRegistry} from "./interfaces/IAlignmentRegistry.sol";

/**
 * @title AlignmentRegistryV1
 * @notice Manages alignment targets and ambassadors for the ms2.fun protocol
 * @dev UUPS upgradeable. Owner is the DAO (GrandCentral + Safe).
 */
contract AlignmentRegistryV1 is UUPSUpgradeable, Ownable, IAlignmentRegistry {
    // ── State ──
    bool private _initialized;
    uint256 public nextAlignmentTargetId;
    mapping(uint256 => AlignmentTarget) public alignmentTargets;
    mapping(uint256 => AlignmentAsset[]) internal alignmentTargetAssets;
    mapping(uint256 => address[]) public alignmentTargetAmbassadors;
    mapping(uint256 => mapping(address => bool)) internal _isAmbassador;
    mapping(address => uint256[]) public tokenToTargetIds;

    constructor() {
        _initializeOwner(msg.sender);
    }

    /**
     * @notice Initialize the contract with a single owner (DAO address)
     * @param _owner Address of the DAO or owner
     */
    function initialize(address _owner) public {
        require(!_initialized, "Already initialized");
        require(_owner != address(0), "Invalid owner");

        _initialized = true;
        _setOwner(_owner);
    }

    // ============ Alignment Target Functions ============

    function registerAlignmentTarget(
        string memory title,
        string memory description,
        string memory metadataURI,
        AlignmentAsset[] memory assets
    ) external override onlyOwner returns (uint256) {
        require(bytes(title).length > 0 && bytes(title).length <= 256, "Invalid title");
        require(assets.length > 0, "Must have at least one asset");

        uint256 targetId = ++nextAlignmentTargetId;

        alignmentTargets[targetId] = AlignmentTarget({
            id: targetId,
            title: title,
            description: description,
            metadataURI: metadataURI,
            approvedAt: block.timestamp,
            active: true
        });

        for (uint256 i = 0; i < assets.length; i++) {
            require(assets[i].token != address(0), "Invalid asset token");
            alignmentTargetAssets[targetId].push(assets[i]);
            tokenToTargetIds[assets[i].token].push(targetId);
        }

        emit AlignmentTargetRegistered(targetId, title);
        return targetId;
    }

    function getAlignmentTarget(uint256 targetId) external view override returns (AlignmentTarget memory) {
        require(alignmentTargets[targetId].approvedAt > 0, "Target not found");
        return alignmentTargets[targetId];
    }

    function getAlignmentTargetAssets(uint256 targetId) external view override returns (AlignmentAsset[] memory) {
        require(alignmentTargets[targetId].approvedAt > 0, "Target not found");
        return alignmentTargetAssets[targetId];
    }

    function isAlignmentTargetActive(uint256 targetId) external view override returns (bool) {
        return alignmentTargets[targetId].active;
    }

    function deactivateAlignmentTarget(uint256 targetId) external override onlyOwner {
        require(alignmentTargets[targetId].approvedAt > 0, "Target not found");
        alignmentTargets[targetId].active = false;
        emit AlignmentTargetDeactivated(targetId);
    }

    function updateAlignmentTarget(
        uint256 targetId,
        string memory description,
        string memory metadataURI
    ) external override onlyOwner {
        require(alignmentTargets[targetId].approvedAt > 0, "Target not found");

        alignmentTargets[targetId].description = description;
        alignmentTargets[targetId].metadataURI = metadataURI;

        emit AlignmentTargetUpdated(targetId);
    }

    // ============ Ambassador Functions ============

    function addAmbassador(uint256 targetId, address ambassador) external override onlyOwner {
        require(alignmentTargets[targetId].approvedAt > 0, "Target not found");
        require(ambassador != address(0), "Invalid ambassador");
        require(!_isAmbassador[targetId][ambassador], "Already ambassador");

        _isAmbassador[targetId][ambassador] = true;
        alignmentTargetAmbassadors[targetId].push(ambassador);

        emit AmbassadorAdded(targetId, ambassador);
    }

    function removeAmbassador(uint256 targetId, address ambassador) external override onlyOwner {
        require(_isAmbassador[targetId][ambassador], "Not ambassador");

        _isAmbassador[targetId][ambassador] = false;

        address[] storage ambassadors = alignmentTargetAmbassadors[targetId];
        for (uint256 i = 0; i < ambassadors.length; i++) {
            if (ambassadors[i] == ambassador) {
                ambassadors[i] = ambassadors[ambassadors.length - 1];
                ambassadors.pop();
                break;
            }
        }

        emit AmbassadorRemoved(targetId, ambassador);
    }

    function getAmbassadors(uint256 targetId) external view override returns (address[] memory) {
        return alignmentTargetAmbassadors[targetId];
    }

    function isAmbassador(uint256 targetId, address account) external view override returns (bool) {
        return _isAmbassador[targetId][account];
    }

    // ============ Token Lookup ============

    function isTokenInTarget(uint256 targetId, address token) external view override returns (bool) {
        AlignmentAsset[] storage assets = alignmentTargetAssets[targetId];
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i].token == token) return true;
        }
        return false;
    }

    // ============ UUPS ============

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
