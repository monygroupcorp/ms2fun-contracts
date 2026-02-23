// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GlobalMessageRegistry} from "../../src/registry/GlobalMessageRegistry.sol";

/**
 * @title GlobalMessagingTestBase
 * @notice Base contract for tests using the global messaging system V2
 * @dev Messages are emitted as events. Use vm.expectEmit for assertions.
 */
abstract contract GlobalMessagingTestBase is Test {
    GlobalMessageRegistry public globalRegistry;

    function _setUpGlobalMessaging(address masterRegistry) internal {
        globalRegistry = new GlobalMessageRegistry();
        globalRegistry.initialize(address(this), masterRegistry);
    }

    function _assertMessageCount(uint256 expected) internal view {
        assertEq(globalRegistry.messageCount(), expected, "Wrong global message count");
    }

    function _messageExists(uint256 messageId) internal view returns (bool) {
        return messageId < globalRegistry.messageCount();
    }

    /// @notice Build encoded messageData for instance passthrough
    function _buildMessageData(
        uint8 messageType,
        uint256 refId,
        bytes32 actionRef,
        bytes32 metadata,
        string memory content
    ) internal pure returns (bytes memory) {
        return abi.encode(messageType, refId, actionRef, metadata, content);
    }

    /// @notice Shorthand: simple POST with content only
    function _buildPostMessage(string memory content) internal pure returns (bytes memory) {
        return abi.encode(uint8(0), uint256(0), bytes32(0), bytes32(0), content);
    }
}
