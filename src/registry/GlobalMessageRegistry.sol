// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "solady/auth/Ownable.sol";
import { GlobalMessagePacking } from "../libraries/GlobalMessagePacking.sol";
import { IMasterRegistry } from "../master/interfaces/IMasterRegistry.sol";

/**
 * @title GlobalMessageRegistry
 * @notice Centralized registry for all protocol messages across instances
 * @dev All message data is emitted via events for off-chain indexing.
 *      Authorization is automatic: any instance created by an approved factory can post messages.
 */
contract GlobalMessageRegistry is Ownable {
    using GlobalMessagePacking for uint256;

    // ┌─────────────────────────┐
    // │      State Variables    │
    // └─────────────────────────┘

    /// @notice Running message counter for unique IDs
    uint256 public messageCount;

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
        uint256 timestamp,
        string message
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

        // Assign message ID
        messageId = messageCount++;

        // Emit event with all data for indexing
        (uint32 timestamp, uint8 factoryType, uint8 actionType, uint32 contextId, ) =
            GlobalMessagePacking.unpack(packedData);

        emit MessageAdded(
            messageId,
            instance,
            sender,
            factoryType,
            actionType,
            contextId,
            timestamp,
            message
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

    /**
     * @notice Get total message count
     * @return count Total number of messages
     */
    function getMessageCount() external view returns (uint256 count) {
        return messageCount;
    }
}
