// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeOwnableUUPS} from "../shared/SafeOwnableUUPS.sol";
import {IAlignmentRegistry} from "./interfaces/IAlignmentRegistry.sol";

/**
 * @title AlignmentRegistryV1
 * @notice Manages alignment targets and ambassadors for the ms2.fun protocol
 * @dev UUPS upgradeable. Owner is the DAO (GrandCentral + Safe).
 */
contract AlignmentRegistryV1 is SafeOwnableUUPS, IAlignmentRegistry {
    // ── Custom Errors ──
    error InvalidAddress();
    error InvalidTitle();
    error NoAssets();
    error TargetNotFound();
    error AmbassadorAlreadyAssigned();
    error NotAmbassador();

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
        if (_initialized) revert AlreadyInitialized();
        if (_owner == address(0)) revert InvalidAddress();

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
        if (bytes(title).length == 0 || bytes(title).length > 256) revert InvalidTitle();
        if (assets.length == 0) revert NoAssets();

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
            if (assets[i].token == address(0)) revert InvalidAddress();
            alignmentTargetAssets[targetId].push(assets[i]);
            tokenToTargetIds[assets[i].token].push(targetId);
        }

        emit AlignmentTargetRegistered(targetId, title);
        return targetId;
    }

    function getAlignmentTarget(uint256 targetId) external view override returns (AlignmentTarget memory) {
        if (alignmentTargets[targetId].approvedAt == 0) revert TargetNotFound();
        return alignmentTargets[targetId];
    }

    function getAlignmentTargetAssets(uint256 targetId) external view override returns (AlignmentAsset[] memory) {
        if (alignmentTargets[targetId].approvedAt == 0) revert TargetNotFound();
        return alignmentTargetAssets[targetId];
    }

    function isAlignmentTargetActive(uint256 targetId) external view override returns (bool) {
        return alignmentTargets[targetId].active;
    }

    function deactivateAlignmentTarget(uint256 targetId) external override onlyOwner {
        if (alignmentTargets[targetId].approvedAt == 0) revert TargetNotFound();
        alignmentTargets[targetId].active = false;
        emit AlignmentTargetDeactivated(targetId);
    }

    function updateAlignmentTarget(
        uint256 targetId,
        string memory description,
        string memory metadataURI
    ) external override onlyOwner {
        if (alignmentTargets[targetId].approvedAt == 0) revert TargetNotFound();

        alignmentTargets[targetId].description = description;
        alignmentTargets[targetId].metadataURI = metadataURI;

        emit AlignmentTargetUpdated(targetId);
    }

    // ============ Ambassador Functions ============

    function addAmbassador(uint256 targetId, address ambassador) external override onlyOwner {
        if (alignmentTargets[targetId].approvedAt == 0) revert TargetNotFound();
        if (ambassador == address(0)) revert InvalidAddress();
        if (_isAmbassador[targetId][ambassador]) revert AmbassadorAlreadyAssigned();

        _isAmbassador[targetId][ambassador] = true;
        alignmentTargetAmbassadors[targetId].push(ambassador);

        emit AmbassadorAdded(targetId, ambassador);
    }

    function removeAmbassador(uint256 targetId, address ambassador) external override onlyOwner {
        if (!_isAmbassador[targetId][ambassador]) revert NotAmbassador();

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

}
