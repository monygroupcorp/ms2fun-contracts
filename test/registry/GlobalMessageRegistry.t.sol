// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {GlobalMessageRegistry} from "../../src/registry/GlobalMessageRegistry.sol";
import {MockMasterRegistry} from "../mocks/MockMasterRegistry.sol";
import {MessageTypes} from "../../src/libraries/MessageTypes.sol";

contract GlobalMessageRegistryTest is Test {
    GlobalMessageRegistry public registry;
    MockMasterRegistry public masterRegistry;

    address public owner = address(this);
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public instance = address(0x100);

    event MessagePosted(
        uint256 indexed messageId,
        address indexed instance,
        address indexed sender,
        uint8 messageType,
        uint256 refId,
        bytes32 actionRef,
        bytes32 metadata,
        string content
    );

    function setUp() public {
        masterRegistry = new MockMasterRegistry();
        registry = new GlobalMessageRegistry();
        registry.initialize(owner, address(masterRegistry));
    }

    // ── Initialize ──

    function test_constructor() public view {
        assertEq(registry.messageCount(), 0);
        assertEq(address(registry.masterRegistry()), address(masterRegistry));
    }

    function test_initialize_revertZeroOwner() public {
        GlobalMessageRegistry r = new GlobalMessageRegistry();
        vm.expectRevert("Invalid owner");
        r.initialize(address(0), address(masterRegistry));
    }

    function test_initialize_revertZeroRegistry() public {
        GlobalMessageRegistry r = new GlobalMessageRegistry();
        vm.expectRevert("Invalid master registry");
        r.initialize(owner, address(0));
    }

    function test_initialize_revertAlreadyInitialized() public {
        vm.expectRevert("Already initialized");
        registry.initialize(owner, address(masterRegistry));
    }

    // ── postForAction ──

    function test_postForAction_emitsEvent() public {
        bytes memory messageData = abi.encode(
            uint8(MessageTypes.POST), uint256(0), bytes32(0), bytes32(0), "gm"
        );

        vm.expectEmit(true, true, true, true);
        emit MessagePosted(0, instance, user1, MessageTypes.POST, 0, bytes32(0), bytes32(0), "gm");

        vm.prank(instance);
        registry.postForAction(user1, instance, messageData);

        assertEq(registry.messageCount(), 1);
    }

    function test_postForAction_incrementsCount() public {
        bytes memory messageData = abi.encode(uint8(0), uint256(0), bytes32(0), bytes32(0), "a");

        vm.prank(instance);
        registry.postForAction(user1, instance, messageData);

        vm.prank(instance);
        registry.postForAction(user2, instance, messageData);

        assertEq(registry.messageCount(), 2);
    }

    function test_postForAction_revertInstanceNotCaller() public {
        bytes memory messageData = abi.encode(uint8(0), uint256(0), bytes32(0), bytes32(0), "x");

        vm.prank(user1); // user1 is not `instance`
        vm.expectRevert("Instance must be caller");
        registry.postForAction(user1, instance, messageData);
    }

    function test_postForAction_revertZeroSender() public {
        bytes memory messageData = abi.encode(uint8(0), uint256(0), bytes32(0), bytes32(0), "x");

        vm.prank(instance);
        vm.expectRevert("Invalid sender");
        registry.postForAction(address(0), instance, messageData);
    }

    // ── post (direct user call) ──

    function test_post_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit MessagePosted(0, instance, user1, MessageTypes.POST, 0, bytes32(0), bytes32(0), "hello");

        vm.prank(user1);
        registry.post(instance, MessageTypes.POST, 0, bytes32(0), bytes32(0), "hello");

        assertEq(registry.messageCount(), 1);
    }

    function test_post_reply() public {
        // First post
        vm.prank(user1);
        registry.post(instance, MessageTypes.POST, 0, bytes32(0), bytes32(0), "original");

        // Reply to message 0
        vm.expectEmit(true, true, true, true);
        emit MessagePosted(1, instance, user2, MessageTypes.REPLY, 0, bytes32(0), bytes32(0), "reply");

        vm.prank(user2);
        registry.post(instance, MessageTypes.REPLY, 0, bytes32(0), bytes32(0), "reply");

        assertEq(registry.messageCount(), 2);
    }

    function test_post_quote() public {
        vm.prank(user1);
        registry.post(instance, MessageTypes.POST, 0, bytes32(0), bytes32(0), "quotable");

        vm.expectEmit(true, true, true, true);
        emit MessagePosted(1, instance, user2, MessageTypes.QUOTE, 0, bytes32(0), bytes32(0), "quoting this");

        vm.prank(user2);
        registry.post(instance, MessageTypes.QUOTE, 0, bytes32(0), bytes32(0), "quoting this");
    }

    function test_post_react() public {
        vm.prank(user1);
        registry.post(instance, MessageTypes.POST, 0, bytes32(0), bytes32(0), "react to me");

        vm.expectEmit(true, true, true, true);
        emit MessagePosted(1, instance, user2, MessageTypes.REACT, 0, bytes32(0), bytes32(0), "fire");

        vm.prank(user2);
        registry.post(instance, MessageTypes.REACT, 0, bytes32(0), bytes32(0), "fire");
    }

    function test_post_withActionRefAndMetadata() public {
        bytes32 actionRef = keccak256("tx:buy:123");
        bytes32 metadata = bytes32(uint256(42));

        vm.expectEmit(true, true, true, true);
        emit MessagePosted(0, instance, user1, MessageTypes.POST, 0, actionRef, metadata, "bought!");

        vm.prank(user1);
        registry.post(instance, MessageTypes.POST, 0, actionRef, metadata, "bought!");
    }

    // ── post to arbitrary address (groupchat) ──

    function test_post_arbitraryAddress() public {
        address groupchat = address(0xDEAD);

        vm.expectEmit(true, true, true, true);
        emit MessagePosted(0, groupchat, user1, MessageTypes.POST, 0, bytes32(0), bytes32(0), "gm group");

        vm.prank(user1);
        registry.post(groupchat, MessageTypes.POST, 0, bytes32(0), bytes32(0), "gm group");

        assertEq(registry.messageCount(), 1);
    }

    function test_post_zeroAddress() public {
        vm.prank(user1);
        registry.post(address(0), MessageTypes.POST, 0, bytes32(0), bytes32(0), "broadcast");
        assertEq(registry.messageCount(), 1);
    }

    // ── postBatch ──

    function test_postBatch_multipleActions() public {
        GlobalMessageRegistry.PostParams[] memory posts = new GlobalMessageRegistry.PostParams[](3);

        // React to something
        posts[0] = GlobalMessageRegistry.PostParams({
            instance: instance,
            messageType: MessageTypes.REACT,
            refId: 42,
            actionRef: bytes32(0),
            metadata: bytes32(0),
            content: "fire"
        });

        // Reply to something else
        posts[1] = GlobalMessageRegistry.PostParams({
            instance: instance,
            messageType: MessageTypes.REPLY,
            refId: 10,
            actionRef: bytes32(0),
            metadata: bytes32(0),
            content: "great post"
        });

        // Post in a groupchat
        posts[2] = GlobalMessageRegistry.PostParams({
            instance: address(0xDEAD),
            messageType: MessageTypes.POST,
            refId: 0,
            actionRef: bytes32(0),
            metadata: bytes32(0),
            content: "gm"
        });

        vm.prank(user1);
        registry.postBatch(posts);

        assertEq(registry.messageCount(), 3);
    }

    function test_postBatch_emitsCorrectEvents() public {
        GlobalMessageRegistry.PostParams[] memory posts = new GlobalMessageRegistry.PostParams[](2);
        posts[0] = GlobalMessageRegistry.PostParams(instance, MessageTypes.POST, 0, bytes32(0), bytes32(0), "first");
        posts[1] = GlobalMessageRegistry.PostParams(instance, MessageTypes.POST, 0, bytes32(0), bytes32(0), "second");

        vm.expectEmit(true, true, true, true);
        emit MessagePosted(0, instance, user1, MessageTypes.POST, 0, bytes32(0), bytes32(0), "first");
        vm.expectEmit(true, true, true, true);
        emit MessagePosted(1, instance, user1, MessageTypes.POST, 0, bytes32(0), bytes32(0), "second");

        vm.prank(user1);
        registry.postBatch(posts);
    }

    function test_postBatch_emptyReverts() public {
        GlobalMessageRegistry.PostParams[] memory posts = new GlobalMessageRegistry.PostParams[](0);

        vm.prank(user1);
        vm.expectRevert("Empty batch");
        registry.postBatch(posts);
    }

    function test_postBatch_singleItem() public {
        GlobalMessageRegistry.PostParams[] memory posts = new GlobalMessageRegistry.PostParams[](1);
        posts[0] = GlobalMessageRegistry.PostParams(instance, MessageTypes.POST, 0, bytes32(0), bytes32(0), "solo");

        vm.prank(user1);
        registry.postBatch(posts);

        assertEq(registry.messageCount(), 1);
    }

    // ── Configuration ──

    function test_setMasterRegistry() public {
        MockMasterRegistry newRegistry = new MockMasterRegistry();
        registry.setMasterRegistry(address(newRegistry));
        assertEq(address(registry.masterRegistry()), address(newRegistry));
    }

    function test_setMasterRegistry_revertNonOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        registry.setMasterRegistry(address(0x999));
    }

    function test_setMasterRegistry_revertZero() public {
        vm.expectRevert("Invalid master registry");
        registry.setMasterRegistry(address(0));
    }

    function test_withdrawETH() public {
        vm.deal(address(registry), 1 ether);
        uint256 balBefore = address(this).balance;
        registry.withdrawETH();
        assertEq(address(this).balance, balBefore + 1 ether);
    }

    receive() external payable {}

    function test_withdrawETH_revertNoBalance() public {
        vm.expectRevert("No ETH to withdraw");
        registry.withdrawETH();
    }

    function test_withdrawETH_revertNonOwner() public {
        vm.deal(address(registry), 1 ether);
        vm.prank(user1);
        vm.expectRevert();
        registry.withdrawETH();
    }
}
