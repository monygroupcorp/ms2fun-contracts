// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAlignmentRegistry
 * @notice Interface for the Alignment Registry — manages alignment targets and ambassadors
 */
interface IAlignmentRegistry {
    struct AlignmentTarget {
        uint256 id;
        string title;
        string description;
        string metadataURI;
        uint256 approvedAt;
        bool active;
    }

    struct AlignmentAsset {
        address token;
        string symbol;
        string info;
        string metadataURI;
    }

    // Events
    event AlignmentTargetRegistered(uint256 indexed targetId, string title);
    event AlignmentTargetDeactivated(uint256 indexed targetId);
    event AlignmentTargetUpdated(uint256 indexed targetId);
    event AmbassadorAdded(uint256 indexed targetId, address indexed ambassador);
    event AmbassadorRemoved(uint256 indexed targetId, address indexed ambassador);

    // Alignment Target Functions
    function registerAlignmentTarget(
        string memory title,
        string memory description,
        string memory metadataURI,
        AlignmentAsset[] memory assets
    ) external returns (uint256);

    function getAlignmentTarget(uint256 targetId) external view returns (AlignmentTarget memory);

    function getAlignmentTargetAssets(uint256 targetId) external view returns (AlignmentAsset[] memory);

    function isAlignmentTargetActive(uint256 targetId) external view returns (bool);

    function deactivateAlignmentTarget(uint256 targetId) external;

    function updateAlignmentTarget(
        uint256 targetId,
        string memory description,
        string memory metadataURI
    ) external;

    // Ambassador Functions
    function addAmbassador(uint256 targetId, address ambassador) external;
    function removeAmbassador(uint256 targetId, address ambassador) external;
    function getAmbassadors(uint256 targetId) external view returns (address[] memory);
    function isAmbassador(uint256 targetId, address account) external view returns (bool);

    // Token Lookup
    function isTokenInTarget(uint256 targetId, address token) external view returns (bool);
}
