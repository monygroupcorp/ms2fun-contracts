// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GlobalMessageRegistry} from "../../src/registry/GlobalMessageRegistry.sol";
import {GlobalMessagePacking} from "../../src/libraries/GlobalMessagePacking.sol";
import {GlobalMessageTypes} from "../../src/libraries/GlobalMessageTypes.sol";

/**
 * @title GlobalMessagingTestBase
 * @notice Base contract for tests using the global messaging system
 * @dev Messages are now emitted as events. Use vm.expectEmit for assertions.
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
     * @notice Assert message count
     */
    function _assertMessageCount(uint256 expected) internal view {
        assertEq(globalRegistry.getMessageCount(), expected, "Wrong global message count");
    }

    // ┌─────────────────────────┐
    // │   Validation Helpers    │
    // └─────────────────────────┘

    /**
     * @notice Check if message exists by ID
     */
    function _messageExists(uint256 messageId) internal view returns (bool) {
        return messageId < globalRegistry.getMessageCount();
    }
}
