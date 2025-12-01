// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IFeatureRegistry
 * @notice Interface for feature registration and management
 */
interface IFeatureRegistry {
    struct Feature {
        bytes32 featureId;
        string name;
        string description;
        bool active;
        uint256 registrationFee;
        address registrant;
        uint256 registeredAt;
        bytes32[] dependencies;
    }

    event FeatureRegistered(
        bytes32 indexed featureId,
        string name,
        address indexed registrant
    );

    event FeatureActivated(bytes32 indexed featureId);
    event FeatureDeactivated(bytes32 indexed featureId);

    function registerFeature(
        bytes32 featureId,
        string memory name,
        string memory description,
        bytes32[] memory dependencies
    ) external payable;

    function getFeature(
        bytes32 featureId
    ) external view returns (Feature memory);

    function isFeatureActive(bytes32 featureId) external view returns (bool);

    function hasFeature(
        bytes32[] memory features,
        bytes32 featureId
    ) external pure returns (bool);
}

