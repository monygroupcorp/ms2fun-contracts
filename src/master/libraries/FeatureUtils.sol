// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title FeatureUtils
 * @notice Utility functions for feature matrix operations
 */
library FeatureUtils {
    // Feature constants for ERC404
    bytes32 public constant BONDING_CURVE = keccak256("BONDING_CURVE");
    bytes32 public constant LIQUIDITY_POOL = keccak256("LIQUIDITY_POOL");
    bytes32 public constant CHAT = keccak256("CHAT");
    bytes32 public constant BALANCE_MINT = keccak256("BALANCE_MINT");
    bytes32 public constant PORTFOLIO = keccak256("PORTFOLIO");

    /**
     * @notice Check if a feature array contains a specific feature
     * @param features Array of feature IDs
     * @param featureId Feature ID to check
     * @return True if feature is present
     */
    function hasFeature(
        bytes32[] memory features,
        bytes32 featureId
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < features.length; i++) {
            if (features[i] == featureId) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Validate feature dependencies
     * @param features Array of feature IDs
     * @param dependencies Array of required dependencies
     * @return True if all dependencies are met
     */
    function validateDependencies(
        bytes32[] memory features,
        bytes32[] memory dependencies
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < dependencies.length; i++) {
            if (!hasFeature(features, dependencies[i])) {
                return false;
            }
        }
        return true;
    }

    /**
     * @notice Merge two feature arrays (no duplicates)
     * @param features1 First feature array
     * @param features2 Second feature array
     * @return Merged feature array
     */
    function mergeFeatures(
        bytes32[] memory features1,
        bytes32[] memory features2
    ) internal pure returns (bytes32[] memory) {
        bytes32[] memory merged = new bytes32[](features1.length + features2.length);
        uint256 count = 0;

        // Add features from first array
        for (uint256 i = 0; i < features1.length; i++) {
            merged[count++] = features1[i];
        }

        // Add features from second array (skip duplicates)
        for (uint256 i = 0; i < features2.length; i++) {
            bool exists = false;
            for (uint256 j = 0; j < count; j++) {
                if (merged[j] == features2[i]) {
                    exists = true;
                    break;
                }
            }
            if (!exists) {
                merged[count++] = features2[i];
            }
        }

        // Resize array
        bytes32[] memory result = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = merged[i];
        }

        return result;
    }
}

