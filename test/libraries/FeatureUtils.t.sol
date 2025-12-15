// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {FeatureUtils} from "../../src/master/libraries/FeatureUtils.sol";

/**
 * @title FeatureUtilsTest
 * @notice Comprehensive test suite for FeatureUtils library
 */
contract FeatureUtilsTest is Test {
    // Use the feature constants from FeatureUtils
    bytes32 constant BONDING_CURVE = keccak256("BONDING_CURVE");
    bytes32 constant LIQUIDITY_POOL = keccak256("LIQUIDITY_POOL");
    bytes32 constant CHAT = keccak256("CHAT");
    bytes32 constant BALANCE_MINT = keccak256("BALANCE_MINT");
    bytes32 constant PORTFOLIO = keccak256("PORTFOLIO");

    // Additional test constants
    bytes32 constant TEST_FEATURE_1 = keccak256("TEST_FEATURE_1");
    bytes32 constant TEST_FEATURE_2 = keccak256("TEST_FEATURE_2");

    function setUp() public {
        // No setup needed for pure library functions
    }

    // ============================================
    // hasFeature() Tests (5 tests)
    // ============================================

    function test_hasFeature_WithEmptyArray() public {
        bytes32[] memory features = new bytes32[](0);

        bool result = FeatureUtils.hasFeature(features, BONDING_CURVE);

        assertFalse(result);
    }

    function test_hasFeature_WithSingleMatchingFeature() public {
        bytes32[] memory features = new bytes32[](1);
        features[0] = BONDING_CURVE;

        bool result = FeatureUtils.hasFeature(features, BONDING_CURVE);

        assertTrue(result);
    }

    function test_hasFeature_WithSingleNonMatchingFeature() public {
        bytes32[] memory features = new bytes32[](1);
        features[0] = LIQUIDITY_POOL;

        bool result = FeatureUtils.hasFeature(features, BONDING_CURVE);

        assertFalse(result);
    }

    function test_hasFeature_WithMultipleFeaturesMatch() public {
        bytes32[] memory features = new bytes32[](3);
        features[0] = BONDING_CURVE;
        features[1] = LIQUIDITY_POOL;
        features[2] = CHAT;

        // Test each feature
        assertTrue(FeatureUtils.hasFeature(features, BONDING_CURVE));
        assertTrue(FeatureUtils.hasFeature(features, LIQUIDITY_POOL));
        assertTrue(FeatureUtils.hasFeature(features, CHAT));
    }

    function test_hasFeature_WithMultipleFeaturesNoMatch() public {
        bytes32[] memory features = new bytes32[](3);
        features[0] = BONDING_CURVE;
        features[1] = LIQUIDITY_POOL;
        features[2] = CHAT;

        bool result = FeatureUtils.hasFeature(features, BALANCE_MINT);

        assertFalse(result);
    }

    // ============================================
    // validateDependencies() Tests (5 tests)
    // ============================================

    function test_validateDependencies_WithAllDependenciesMet() public {
        bytes32[] memory features = new bytes32[](3);
        features[0] = BONDING_CURVE;
        features[1] = LIQUIDITY_POOL;
        features[2] = CHAT;

        bytes32[] memory dependencies = new bytes32[](2);
        dependencies[0] = BONDING_CURVE;
        dependencies[1] = LIQUIDITY_POOL;

        bool result = FeatureUtils.validateDependencies(features, dependencies);

        assertTrue(result);
    }

    function test_validateDependencies_WithMissingDependencies() public {
        bytes32[] memory features = new bytes32[](2);
        features[0] = BONDING_CURVE;
        features[1] = LIQUIDITY_POOL;

        bytes32[] memory dependencies = new bytes32[](3);
        dependencies[0] = BONDING_CURVE;
        dependencies[1] = LIQUIDITY_POOL;
        dependencies[2] = CHAT; // This is missing

        bool result = FeatureUtils.validateDependencies(features, dependencies);

        assertFalse(result);
    }

    function test_validateDependencies_WithEmptyDependenciesArray() public {
        bytes32[] memory features = new bytes32[](2);
        features[0] = BONDING_CURVE;
        features[1] = LIQUIDITY_POOL;

        bytes32[] memory dependencies = new bytes32[](0);

        bool result = FeatureUtils.validateDependencies(features, dependencies);

        assertTrue(result);
    }

    function test_validateDependencies_WithEmptyFeatureArray() public {
        bytes32[] memory features = new bytes32[](0);

        bytes32[] memory dependencies = new bytes32[](1);
        dependencies[0] = BONDING_CURVE;

        bool result = FeatureUtils.validateDependencies(features, dependencies);

        assertFalse(result);
    }

    function test_validateDependencies_WithPartialMatch() public {
        bytes32[] memory features = new bytes32[](3);
        features[0] = BONDING_CURVE;
        features[1] = LIQUIDITY_POOL;
        features[2] = CHAT;

        bytes32[] memory dependencies = new bytes32[](4);
        dependencies[0] = BONDING_CURVE;
        dependencies[1] = LIQUIDITY_POOL;
        dependencies[2] = CHAT;
        dependencies[3] = BALANCE_MINT; // This one is missing

        bool result = FeatureUtils.validateDependencies(features, dependencies);

        assertFalse(result);
    }

    // ============================================
    // mergeFeatures() Tests (5 tests)
    // ============================================

    function test_mergeFeatures_WithNoOverlap() public {
        bytes32[] memory features1 = new bytes32[](2);
        features1[0] = BONDING_CURVE;
        features1[1] = LIQUIDITY_POOL;

        bytes32[] memory features2 = new bytes32[](2);
        features2[0] = CHAT;
        features2[1] = BALANCE_MINT;

        bytes32[] memory merged = FeatureUtils.mergeFeatures(features1, features2);

        assertEq(merged.length, 4);
        assertEq(merged[0], BONDING_CURVE);
        assertEq(merged[1], LIQUIDITY_POOL);
        assertEq(merged[2], CHAT);
        assertEq(merged[3], BALANCE_MINT);
    }

    function test_mergeFeatures_WithCompleteOverlap() public {
        bytes32[] memory features1 = new bytes32[](3);
        features1[0] = BONDING_CURVE;
        features1[1] = LIQUIDITY_POOL;
        features1[2] = CHAT;

        bytes32[] memory features2 = new bytes32[](3);
        features2[0] = BONDING_CURVE;
        features2[1] = LIQUIDITY_POOL;
        features2[2] = CHAT;

        bytes32[] memory merged = FeatureUtils.mergeFeatures(features1, features2);

        // Should have same size as array1 since all are duplicates
        assertEq(merged.length, 3);
        assertEq(merged[0], BONDING_CURVE);
        assertEq(merged[1], LIQUIDITY_POOL);
        assertEq(merged[2], CHAT);
    }

    function test_mergeFeatures_WithPartialOverlap() public {
        bytes32[] memory features1 = new bytes32[](3);
        features1[0] = BONDING_CURVE;
        features1[1] = LIQUIDITY_POOL;
        features1[2] = CHAT;

        bytes32[] memory features2 = new bytes32[](3);
        features2[0] = LIQUIDITY_POOL; // Duplicate
        features2[1] = BALANCE_MINT; // New
        features2[2] = PORTFOLIO; // New

        bytes32[] memory merged = FeatureUtils.mergeFeatures(features1, features2);

        // Should be 5: 3 from array1 + 2 new from array2
        assertEq(merged.length, 5);
        assertEq(merged[0], BONDING_CURVE);
        assertEq(merged[1], LIQUIDITY_POOL);
        assertEq(merged[2], CHAT);
        assertEq(merged[3], BALANCE_MINT);
        assertEq(merged[4], PORTFOLIO);
    }

    function test_mergeFeatures_WithEmptyFirstArray() public {
        bytes32[] memory features1 = new bytes32[](0);

        bytes32[] memory features2 = new bytes32[](2);
        features2[0] = BONDING_CURVE;
        features2[1] = LIQUIDITY_POOL;

        bytes32[] memory merged = FeatureUtils.mergeFeatures(features1, features2);

        assertEq(merged.length, 2);
        assertEq(merged[0], BONDING_CURVE);
        assertEq(merged[1], LIQUIDITY_POOL);
    }

    function test_mergeFeatures_WithEmptySecondArray() public {
        bytes32[] memory features1 = new bytes32[](2);
        features1[0] = BONDING_CURVE;
        features1[1] = LIQUIDITY_POOL;

        bytes32[] memory features2 = new bytes32[](0);

        bytes32[] memory merged = FeatureUtils.mergeFeatures(features1, features2);

        assertEq(merged.length, 2);
        assertEq(merged[0], BONDING_CURVE);
        assertEq(merged[1], LIQUIDITY_POOL);
    }

    // ============================================
    // Edge Cases Tests (3 tests)
    // ============================================

    function test_mergeFeatures_BothEmpty() public {
        bytes32[] memory features1 = new bytes32[](0);
        bytes32[] memory features2 = new bytes32[](0);

        bytes32[] memory merged = FeatureUtils.mergeFeatures(features1, features2);

        assertEq(merged.length, 0);
    }

    function test_mergeFeatures_PreservesOrder() public {
        bytes32[] memory features1 = new bytes32[](3);
        features1[0] = BONDING_CURVE;
        features1[1] = LIQUIDITY_POOL;
        features1[2] = CHAT;

        bytes32[] memory features2 = new bytes32[](2);
        features2[0] = BALANCE_MINT;
        features2[1] = PORTFOLIO;

        bytes32[] memory merged = FeatureUtils.mergeFeatures(features1, features2);

        // Verify order: array1 first, then new items from array2
        assertEq(merged.length, 5);
        assertEq(merged[0], BONDING_CURVE);
        assertEq(merged[1], LIQUIDITY_POOL);
        assertEq(merged[2], CHAT);
        assertEq(merged[3], BALANCE_MINT);
        assertEq(merged[4], PORTFOLIO);
    }

    function test_validateDependencies_ComplexScenario() public {
        // Create a complex feature set
        bytes32[] memory features = new bytes32[](5);
        features[0] = BONDING_CURVE;
        features[1] = LIQUIDITY_POOL;
        features[2] = CHAT;
        features[3] = BALANCE_MINT;
        features[4] = PORTFOLIO;

        // Test multiple dependency scenarios

        // Scenario 1: All dependencies present
        bytes32[] memory deps1 = new bytes32[](3);
        deps1[0] = BONDING_CURVE;
        deps1[1] = CHAT;
        deps1[2] = PORTFOLIO;
        assertTrue(FeatureUtils.validateDependencies(features, deps1));

        // Scenario 2: Some dependencies missing
        bytes32[] memory deps2 = new bytes32[](3);
        deps2[0] = BONDING_CURVE;
        deps2[1] = CHAT;
        deps2[2] = TEST_FEATURE_1; // Missing
        assertFalse(FeatureUtils.validateDependencies(features, deps2));

        // Scenario 3: Single dependency check
        bytes32[] memory deps3 = new bytes32[](1);
        deps3[0] = LIQUIDITY_POOL;
        assertTrue(FeatureUtils.validateDependencies(features, deps3));
    }

    // ============================================
    // Additional Integration Tests (3 tests)
    // ============================================

    function test_Integration_MergeAndValidate() public {
        // Create two feature sets
        bytes32[] memory features1 = new bytes32[](2);
        features1[0] = BONDING_CURVE;
        features1[1] = LIQUIDITY_POOL;

        bytes32[] memory features2 = new bytes32[](2);
        features2[0] = CHAT;
        features2[1] = BALANCE_MINT;

        // Merge them
        bytes32[] memory merged = FeatureUtils.mergeFeatures(features1, features2);

        // Validate that all original features are dependencies met
        bytes32[] memory deps = new bytes32[](4);
        deps[0] = BONDING_CURVE;
        deps[1] = LIQUIDITY_POOL;
        deps[2] = CHAT;
        deps[3] = BALANCE_MINT;

        assertTrue(FeatureUtils.validateDependencies(merged, deps));
    }

    function test_Integration_HasFeatureAfterMerge() public {
        bytes32[] memory features1 = new bytes32[](2);
        features1[0] = BONDING_CURVE;
        features1[1] = LIQUIDITY_POOL;

        bytes32[] memory features2 = new bytes32[](1);
        features2[0] = CHAT;

        bytes32[] memory merged = FeatureUtils.mergeFeatures(features1, features2);

        // Verify all features are present
        assertTrue(FeatureUtils.hasFeature(merged, BONDING_CURVE));
        assertTrue(FeatureUtils.hasFeature(merged, LIQUIDITY_POOL));
        assertTrue(FeatureUtils.hasFeature(merged, CHAT));
        assertFalse(FeatureUtils.hasFeature(merged, BALANCE_MINT));
    }

    function test_Integration_MultipleMerges() public {
        // First merge
        bytes32[] memory features1 = new bytes32[](1);
        features1[0] = BONDING_CURVE;

        bytes32[] memory features2 = new bytes32[](1);
        features2[0] = LIQUIDITY_POOL;

        bytes32[] memory merged1 = FeatureUtils.mergeFeatures(features1, features2);
        assertEq(merged1.length, 2);

        // Second merge
        bytes32[] memory features3 = new bytes32[](1);
        features3[0] = CHAT;

        bytes32[] memory merged2 = FeatureUtils.mergeFeatures(merged1, features3);
        assertEq(merged2.length, 3);

        // Third merge with overlap
        bytes32[] memory features4 = new bytes32[](2);
        features4[0] = CHAT; // Duplicate
        features4[1] = BALANCE_MINT; // New

        bytes32[] memory merged3 = FeatureUtils.mergeFeatures(merged2, features4);
        assertEq(merged3.length, 4); // Should not duplicate CHAT

        // Verify all features
        assertTrue(FeatureUtils.hasFeature(merged3, BONDING_CURVE));
        assertTrue(FeatureUtils.hasFeature(merged3, LIQUIDITY_POOL));
        assertTrue(FeatureUtils.hasFeature(merged3, CHAT));
        assertTrue(FeatureUtils.hasFeature(merged3, BALANCE_MINT));
    }
}
