// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "solady/auth/Ownable.sol";
import { GlobalMessagePacking } from "../libraries/GlobalMessagePacking.sol";
import { IMasterRegistry } from "../master/interfaces/IMasterRegistry.sol";

/**
 * @title GlobalMessageRegistry
 * @notice Centralized registry for all protocol messages across instances
 * @dev Enables protocol-wide activity tracking and discovery in a single RPC call
 *      Authorization is automatic: any instance created by an approved factory can post messages
 */
contract GlobalMessageRegistry is Ownable {
    using GlobalMessagePacking for uint256;

    // ┌─────────────────────────┐
    // │         Types           │
    // └─────────────────────────┘

    struct GlobalMessage {
        address instance;      // Which project instance emitted this message
        address sender;        // User who performed the action
        uint256 packedData;    // Packed metadata (timestamp, factory type, action type, context ID, amount)
        string message;        // User-provided message text
    }

    // ┌─────────────────────────┐
    // │      State Variables    │
    // └─────────────────────────┘

    /// @notice All messages in chronological order (append-only)
    GlobalMessage[] public messages;

    /// @notice Index mapping instance => array of message IDs
    mapping(address => uint256[]) private instanceMessageIds;

    /// @notice MasterRegistry for factory parentage verification
    IMasterRegistry public masterRegistry;

    // ┌─────────────────────────┐
    // │         Events          │
    // └─────────────────────────┘

    event MessageAdded(
        uint256 indexed messageId,
        address indexed instance,
        address indexed sender,
        uint8 factoryType,
        uint8 actionType,
        uint32 contextId,
        uint256 timestamp
    );

    event MasterRegistrySet(address indexed masterRegistry);

    // ┌─────────────────────────┐
    // │      Constructor        │
    // └─────────────────────────┘

    constructor(address _owner, address _masterRegistry) {
        require(_owner != address(0), "Invalid owner");
        require(_masterRegistry != address(0), "Invalid master registry");
        _initializeOwner(_owner);
        masterRegistry = IMasterRegistry(_masterRegistry);
    }

    // ┌─────────────────────────┐
    // │    Write Functions      │
    // └─────────────────────────┘

    /**
     * @notice Add a message to the global registry
     * @dev Only callable by instances from approved factories (auto-authorized)
     * @param instance Instance address emitting the message
     * @param sender User who performed the action
     * @param packedData Packed metadata (use GlobalMessagePacking.pack())
     * @param message User-provided message text
     * @return messageId ID of the created message
     */
    function addMessage(
        address instance,
        address sender,
        uint256 packedData,
        string calldata message
    ) external returns (uint256 messageId) {
        // Auto-authorize: check if caller is from an approved factory
        require(
            masterRegistry.isInstanceFromApprovedFactory(msg.sender),
            "Not from approved factory"
        );
        require(instance != address(0), "Invalid instance");
        require(sender != address(0), "Invalid sender");

        // Create message
        messageId = messages.length;
        messages.push(GlobalMessage({
            instance: instance,
            sender: sender,
            packedData: packedData,
            message: message
        }));

        // Index by instance
        instanceMessageIds[instance].push(messageId);

        // Emit event with unpacked data for indexing
        (uint32 timestamp, uint8 factoryType, uint8 actionType, uint32 contextId, ) =
            GlobalMessagePacking.unpack(packedData);

        emit MessageAdded(
            messageId,
            instance,
            sender,
            factoryType,
            actionType,
            contextId,
            timestamp
        );
    }

    // ┌─────────────────────────┐
    // │   Configuration         │
    // └─────────────────────────┘

    /**
     * @notice Set master registry address
     * @dev Only owner can set the master registry
     * @param _masterRegistry New master registry address
     */
    function setMasterRegistry(address _masterRegistry) external onlyOwner {
        require(_masterRegistry != address(0), "Invalid master registry");
        masterRegistry = IMasterRegistry(_masterRegistry);
        emit MasterRegistrySet(_masterRegistry);
    }

    /**
     * @notice Check if an instance is authorized to post messages
     * @dev Checks factory parentage via MasterRegistry (auto-authorization)
     * @param instance Instance address to check
     * @return authorized Whether instance is authorized
     */
    function isAuthorized(address instance) external view returns (bool authorized) {
        return masterRegistry.isInstanceFromApprovedFactory(instance);
    }

    // ┌─────────────────────────┐
    // │    Query Functions      │
    // └─────────────────────────┘

    /**
     * @notice Get a single message by ID
     * @param messageId Message ID
     * @return message The global message
     */
    function getMessage(uint256 messageId) external view returns (GlobalMessage memory message) {
        require(messageId < messages.length, "Message does not exist");
        return messages[messageId];
    }

    /**
     * @notice Get total message count
     * @return count Total number of messages
     */
    function getMessageCount() external view returns (uint256 count) {
        return messages.length;
    }

    /**
     * @notice Get recent messages (most recent first)
     * @param count Number of messages to retrieve
     * @return recentMessages Array of recent messages
     */
    function getRecentMessages(uint256 count) external view returns (GlobalMessage[] memory recentMessages) {
        uint256 totalMessages = messages.length;
        if (totalMessages == 0) {
            return new GlobalMessage[](0);
        }

        uint256 actualCount = count > totalMessages ? totalMessages : count;
        recentMessages = new GlobalMessage[](actualCount);

        for (uint256 i = 0; i < actualCount; i++) {
            recentMessages[i] = messages[totalMessages - 1 - i];
        }
    }

    /**
     * @notice Get paginated messages (supports large queries)
     * @param offset Starting index (0 = most recent)
     * @param limit Number of messages to retrieve
     * @return paginatedMessages Array of messages
     */
    function getRecentMessagesPaginated(
        uint256 offset,
        uint256 limit
    ) external view returns (GlobalMessage[] memory paginatedMessages) {
        uint256 totalMessages = messages.length;
        if (totalMessages == 0 || offset >= totalMessages) {
            return new GlobalMessage[](0);
        }

        uint256 remaining = totalMessages - offset;
        uint256 actualLimit = limit > remaining ? remaining : limit;
        paginatedMessages = new GlobalMessage[](actualLimit);

        for (uint256 i = 0; i < actualLimit; i++) {
            paginatedMessages[i] = messages[totalMessages - 1 - offset - i];
        }
    }

    /**
     * @notice Get message count for a specific instance
     * @param instance Instance address
     * @return count Number of messages from this instance
     */
    function getMessageCountForInstance(address instance) external view returns (uint256 count) {
        return instanceMessageIds[instance].length;
    }

    /**
     * @notice Get recent messages for a specific instance
     * @param instance Instance address
     * @param count Number of messages to retrieve
     * @return instanceMessages Array of messages from this instance
     */
    function getInstanceMessages(
        address instance,
        uint256 count
    ) external view returns (GlobalMessage[] memory instanceMessages) {
        uint256[] storage messageIds = instanceMessageIds[instance];
        uint256 totalInstanceMessages = messageIds.length;

        if (totalInstanceMessages == 0) {
            return new GlobalMessage[](0);
        }

        uint256 actualCount = count > totalInstanceMessages ? totalInstanceMessages : count;
        instanceMessages = new GlobalMessage[](actualCount);

        for (uint256 i = 0; i < actualCount; i++) {
            uint256 messageId = messageIds[totalInstanceMessages - 1 - i];
            instanceMessages[i] = messages[messageId];
        }
    }

    /**
     * @notice Get paginated messages for a specific instance
     * @param instance Instance address
     * @param offset Starting index (0 = most recent)
     * @param limit Number of messages to retrieve
     * @return paginatedMessages Array of messages from this instance
     */
    function getInstanceMessagesPaginated(
        address instance,
        uint256 offset,
        uint256 limit
    ) external view returns (GlobalMessage[] memory paginatedMessages) {
        uint256[] storage messageIds = instanceMessageIds[instance];
        uint256 totalInstanceMessages = messageIds.length;

        if (totalInstanceMessages == 0 || offset >= totalInstanceMessages) {
            return new GlobalMessage[](0);
        }

        uint256 remaining = totalInstanceMessages - offset;
        uint256 actualLimit = limit > remaining ? remaining : limit;
        paginatedMessages = new GlobalMessage[](actualLimit);

        for (uint256 i = 0; i < actualLimit; i++) {
            uint256 messageId = messageIds[totalInstanceMessages - 1 - offset - i];
            paginatedMessages[i] = messages[messageId];
        }
    }

    /**
     * @notice Get all message IDs for a specific instance
     * @dev Use with caution for instances with many messages - prefer pagination
     * @param instance Instance address
     * @return messageIds Array of message IDs
     */
    function getInstanceMessageIds(address instance) external view returns (uint256[] memory messageIds) {
        return instanceMessageIds[instance];
    }

    /**
     * @notice Batch query messages by IDs
     * @param messageIds Array of message IDs to query
     * @return batchMessages Array of messages
     */
    function getMessagesBatch(uint256[] calldata messageIds) external view returns (
        GlobalMessage[] memory batchMessages
    ) {
        batchMessages = new GlobalMessage[](messageIds.length);
        for (uint256 i = 0; i < messageIds.length; i++) {
            require(messageIds[i] < messages.length, "Message does not exist");
            batchMessages[i] = messages[messageIds[i]];
        }
    }
}
