// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GlobalMessageRegistry} from "../../src/registry/GlobalMessageRegistry.sol";
import {GlobalMessagePacking} from "../../src/libraries/GlobalMessagePacking.sol";
import {GlobalMessageTypes} from "../../src/libraries/GlobalMessageTypes.sol";

/**
 * @title GlobalMessagingTestBase
 * @notice Base contract for tests using the global messaging system
 * @dev Provides helper functions for setting up and asserting on global messages
 */
abstract contract GlobalMessagingTestBase is Test {
    GlobalMessageRegistry public globalRegistry;

    /**
     * @notice Set up global messaging system
     * @dev Call this in setUp() after deploying MasterRegistry
     */
    function _setUpGlobalMessaging(address masterRegistry) internal {
        // Deploy global registry with owner and master registry
        globalRegistry = new GlobalMessageRegistry(address(this), masterRegistry);

        // Set in master registry
        (bool success,) = masterRegistry.call(
            abi.encodeWithSignature("setGlobalMessageRegistry(address)", address(globalRegistry))
        );
        require(success, "Failed to set global registry");
    }

    // ┌─────────────────────────┐
    // │   Assertion Helpers     │
    // └─────────────────────────┘

    /**
     * @notice Assert global message contents
     */
    function _assertGlobalMessage(
        uint256 messageId,
        address expectedInstance,
        address expectedSender,
        uint8 expectedFactoryType,
        uint8 expectedActionType,
        uint32 expectedContextId,
        string memory expectedMessage
    ) internal {
        GlobalMessageRegistry.GlobalMessage memory msg = globalRegistry.getMessage(messageId);

        assertEq(msg.instance, expectedInstance, "Wrong instance");
        assertEq(msg.sender, expectedSender, "Wrong sender");
        assertEq(msg.message, expectedMessage, "Wrong message");

        (uint32 ts, uint8 factoryType, uint8 actionType, uint32 contextId, uint96 amount) =
            GlobalMessagePacking.unpack(msg.packedData);

        assertEq(factoryType, expectedFactoryType, "Wrong factory type");
        assertEq(actionType, expectedActionType, "Wrong action type");
        assertEq(contextId, expectedContextId, "Wrong context ID");
        assertTrue(ts > 0, "Invalid timestamp");
        assertTrue(amount > 0, "Invalid amount");
    }

    /**
     * @notice Assert global message with amount check
     */
    function _assertGlobalMessageWithAmount(
        uint256 messageId,
        address expectedInstance,
        address expectedSender,
        uint8 expectedFactoryType,
        uint8 expectedActionType,
        uint32 expectedContextId,
        uint96 expectedAmount,
        string memory expectedMessage
    ) internal {
        GlobalMessageRegistry.GlobalMessage memory msg = globalRegistry.getMessage(messageId);

        assertEq(msg.instance, expectedInstance, "Wrong instance");
        assertEq(msg.sender, expectedSender, "Wrong sender");
        assertEq(msg.message, expectedMessage, "Wrong message");

        (uint32 ts, uint8 factoryType, uint8 actionType, uint32 contextId, uint96 amount) =
            GlobalMessagePacking.unpack(msg.packedData);

        assertEq(factoryType, expectedFactoryType, "Wrong factory type");
        assertEq(actionType, expectedActionType, "Wrong action type");
        assertEq(contextId, expectedContextId, "Wrong context ID");
        assertEq(amount, expectedAmount, "Wrong amount");
        assertTrue(ts > 0, "Invalid timestamp");
    }

    /**
     * @notice Assert message count
     */
    function _assertMessageCount(uint256 expected) internal {
        assertEq(globalRegistry.getMessageCount(), expected, "Wrong global message count");
    }

    /**
     * @notice Assert instance message count
     */
    function _assertInstanceMessageCount(address instance, uint256 expected) internal {
        assertEq(
            globalRegistry.getMessageCountForInstance(instance),
            expected,
            "Wrong instance message count"
        );
    }

    // ┌─────────────────────────┐
    // │    Query Helpers        │
    // └─────────────────────────┘

    /**
     * @notice Get recent messages
     */
    function _getRecentMessages(uint256 count)
        internal
        view
        returns (GlobalMessageRegistry.GlobalMessage[] memory)
    {
        return globalRegistry.getRecentMessages(count);
    }

    /**
     * @notice Get instance messages
     */
    function _getInstanceMessages(address instance, uint256 count)
        internal
        view
        returns (GlobalMessageRegistry.GlobalMessage[] memory)
    {
        return globalRegistry.getInstanceMessages(instance, count);
    }

    /**
     * @notice Get single message
     */
    function _getMessage(uint256 messageId)
        internal
        view
        returns (GlobalMessageRegistry.GlobalMessage memory)
    {
        return globalRegistry.getMessage(messageId);
    }

    /**
     * @notice Unpack message data
     */
    function _unpackMessage(uint256 messageId)
        internal
        view
        returns (
            uint32 timestamp,
            uint8 factoryType,
            uint8 actionType,
            uint32 contextId,
            uint96 amount
        )
    {
        GlobalMessageRegistry.GlobalMessage memory msg = globalRegistry.getMessage(messageId);
        return GlobalMessagePacking.unpack(msg.packedData);
    }

    // ┌─────────────────────────┐
    // │   Validation Helpers    │
    // └─────────────────────────┘

    /**
     * @notice Check if message exists
     */
    function _messageExists(uint256 messageId) internal view returns (bool) {
        return messageId < globalRegistry.getMessageCount();
    }

    /**
     * @notice Verify instance has messages
     */
    function _hasMessages(address instance) internal view returns (bool) {
        return globalRegistry.getMessageCountForInstance(instance) > 0;
    }
}
