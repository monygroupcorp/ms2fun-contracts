// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SafeOwnableUUPS } from "../shared/SafeOwnableUUPS.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IMasterRegistry } from "../master/interfaces/IMasterRegistry.sol";
import { IGlobalMessageRegistry } from "./interfaces/IGlobalMessageRegistry.sol";

/**
 * @title GlobalMessageRegistry
 * @notice V2 — standalone social layer (post/reply/quote/react) decoupled from trade execution.
 * @dev Two entry points:
 *      - postForAction: called by registered instances to forward user messages atomically with actions
 *      - post: called directly by users, instance acts as channel
 *      All message data is emitted via events for off-chain indexing.
 *      UUPS upgradeable. Owner is the DAO via Timelock.
 */
contract GlobalMessageRegistry is SafeOwnableUUPS, IGlobalMessageRegistry {

    // ┌─────────────────────────┐
    // │      Custom Errors      │
    // └─────────────────────────┘

    error InvalidAddress();
    error InstanceMustBeCaller();
    error NotFromApprovedFactory();
    error EmptyBatch();
    error NoETHToWithdraw();

    // ┌─────────────────────────┐
    // │      State Variables    │
    // └─────────────────────────┘

    bool private _initialized;
    uint256 public messageCount;
    IMasterRegistry public masterRegistry;

    // ┌─────────────────────────┐
    // │         Events          │
    // └─────────────────────────┘

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

    event MasterRegistrySet(address indexed masterRegistry);
    event ETHWithdrawn(address indexed to, uint256 amount);

    // ┌─────────────────────────┐
    // │      Constructor        │
    // └─────────────────────────┘

    constructor() {
        _initializeOwner(msg.sender);
    }

    function initialize(address _owner, address _masterRegistry) public {
        if (_initialized) revert AlreadyInitialized();
        if (_owner == address(0)) revert InvalidAddress();
        if (_masterRegistry == address(0)) revert InvalidAddress();
        _initialized = true;
        _setOwner(_owner);
        masterRegistry = IMasterRegistry(_masterRegistry);
    }

    // ┌─────────────────────────┐
    // │    Write Functions      │
    // └─────────────────────────┘

    /**
     * @notice Post a message on behalf of a user, called by an instance during an action
     * @dev Auth: msg.sender must be a registered instance, and instance == msg.sender
     * @param sender The user performing the action
     * @param instance The instance forwarding the message (must be msg.sender)
     * @param messageData ABI-encoded (uint8 messageType, uint256 refId, bytes32 actionRef, bytes32 metadata, string content)
     */
    function postForAction(
        address sender,
        address instance,
        bytes calldata messageData
    ) external override {
        if (instance != msg.sender) revert InstanceMustBeCaller();
        if (!masterRegistry.isInstanceFromApprovedFactory(msg.sender)) revert NotFromApprovedFactory();
        if (sender == address(0)) revert InvalidAddress();

        _post(instance, sender, messageData);
    }

    /**
     * @notice Post a message directly as a user — any address acts as channel
     * @dev No auth on `instance` — any address is a valid channel. Indexer decides display.
     * @param instance The channel address (registered instance, EOA, or any address)
     * @param messageType POST=0, REPLY=1, QUOTE=2, REACT=3
     * @param refId Message ID being replied to / quoted / reacted to (0 for POST)
     * @param actionRef Opaque reference for frontend (e.g., trade hash)
     * @param metadata Opaque metadata for frontend
     * @param content Message text
     */
    function post(
        address instance,
        uint8 messageType,
        uint256 refId,
        bytes32 actionRef,
        bytes32 metadata,
        string calldata content
    ) external {
        uint256 messageId = messageCount++;

        emit MessagePosted(
            messageId,
            instance,
            msg.sender,
            messageType,
            refId,
            actionRef,
            metadata,
            content
        );
    }

    struct PostParams {
        address instance;
        uint8 messageType;
        uint256 refId;
        bytes32 actionRef;
        bytes32 metadata;
        string content;
    }

    /**
     * @notice Batch multiple posts in a single transaction
     * @dev All posts are attributed to msg.sender. Useful for batching reactions,
     *      replies, and posts accumulated during a browsing session.
     * @param posts Array of post parameters
     */
    function postBatch(PostParams[] calldata posts) external {
        uint256 len = posts.length;
        if (len == 0) revert EmptyBatch();

        uint256 id = messageCount;
        for (uint256 i; i < len; ++i) {
            emit MessagePosted(
                id++,
                posts[i].instance,
                msg.sender,
                posts[i].messageType,
                posts[i].refId,
                posts[i].actionRef,
                posts[i].metadata,
                posts[i].content
            );
        }
        messageCount = id;
    }

    // ┌─────────────────────────┐
    // │   Configuration         │
    // └─────────────────────────┘

    function setMasterRegistry(address _masterRegistry) external onlyOwner {
        if (_masterRegistry == address(0)) revert InvalidAddress();
        masterRegistry = IMasterRegistry(_masterRegistry);
        emit MasterRegistrySet(_masterRegistry);
    }

    function withdrawETH() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoETHToWithdraw();
        SafeTransferLib.safeTransferETH(msg.sender, balance);
        emit ETHWithdrawn(msg.sender, balance);
    }

    // ┌─────────────────────────┐
    // │   Internal              │
    // └─────────────────────────┘

    function _post(address instance, address sender, bytes calldata messageData) internal {
        (
            uint8 messageType,
            uint256 refId,
            bytes32 actionRef,
            bytes32 metadata,
            string memory content
        ) = abi.decode(messageData, (uint8, uint256, bytes32, bytes32, string));

        uint256 messageId = messageCount++;

        emit MessagePosted(
            messageId,
            instance,
            sender,
            messageType,
            refId,
            actionRef,
            metadata,
            content
        );
    }
}
