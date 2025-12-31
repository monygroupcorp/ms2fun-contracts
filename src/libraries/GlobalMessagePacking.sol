// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title GlobalMessagePacking
 * @notice Library for packing/unpacking global message metadata into a single uint256
 * @dev Bit layout (176 bits used, 80 bits reserved):
 *      [0-31]    timestamp (uint32)      - Unix timestamp
 *      [32-39]   factoryType (uint8)     - 0=ERC404, 1=ERC1155, 2=future
 *      [40-47]   actionType (uint8)      - 0=buy, 1=sell, 2=mint, etc.
 *      [48-79]   contextId (uint32)      - editionId for ERC1155, 0 for ERC404
 *      [80-175]  amount (uint96)         - token/ETH amount involved
 *      [176-255] reserved (80 bits)      - future expansion
 */
library GlobalMessagePacking {
    /**
     * @notice Pack message metadata into a single uint256
     * @param timestamp Unix timestamp of the action
     * @param factoryType Factory type (0=ERC404, 1=ERC1155)
     * @param actionType Action type (0=buy, 1=sell, 2=mint, etc.)
     * @param contextId Context ID (editionId for ERC1155, 0 for ERC404)
     * @param amount Token/ETH amount involved in the action
     * @return packed Packed uint256 containing all metadata
     */
    function pack(
        uint32 timestamp,
        uint8 factoryType,
        uint8 actionType,
        uint32 contextId,
        uint96 amount
    ) internal pure returns (uint256 packed) {
        packed = uint256(timestamp);
        packed |= uint256(factoryType) << 32;
        packed |= uint256(actionType) << 40;
        packed |= uint256(contextId) << 48;
        packed |= uint256(amount) << 80;
    }

    /**
     * @notice Unpack message metadata from a uint256
     * @param packed Packed uint256 containing metadata
     * @return timestamp Unix timestamp
     * @return factoryType Factory type
     * @return actionType Action type
     * @return contextId Context ID
     * @return amount Token/ETH amount
     */
    function unpack(uint256 packed) internal pure returns (
        uint32 timestamp,
        uint8 factoryType,
        uint8 actionType,
        uint32 contextId,
        uint96 amount
    ) {
        timestamp = uint32(packed);
        factoryType = uint8(packed >> 32);
        actionType = uint8(packed >> 40);
        contextId = uint32(packed >> 48);
        amount = uint96(packed >> 80);
    }

    /**
     * @notice Extract timestamp from packed data (gas-optimized)
     * @param packed Packed uint256
     * @return timestamp Unix timestamp
     */
    function getTimestamp(uint256 packed) internal pure returns (uint32 timestamp) {
        return uint32(packed);
    }

    /**
     * @notice Extract factory type from packed data (gas-optimized)
     * @param packed Packed uint256
     * @return factoryType Factory type
     */
    function getFactoryType(uint256 packed) internal pure returns (uint8 factoryType) {
        return uint8(packed >> 32);
    }

    /**
     * @notice Extract action type from packed data (gas-optimized)
     * @param packed Packed uint256
     * @return actionType Action type
     */
    function getActionType(uint256 packed) internal pure returns (uint8 actionType) {
        return uint8(packed >> 40);
    }

    /**
     * @notice Extract context ID from packed data (gas-optimized)
     * @param packed Packed uint256
     * @return contextId Context ID
     */
    function getContextId(uint256 packed) internal pure returns (uint32 contextId) {
        return uint32(packed >> 48);
    }

    /**
     * @notice Extract amount from packed data (gas-optimized)
     * @param packed Packed uint256
     * @return amount Token/ETH amount
     */
    function getAmount(uint256 packed) internal pure returns (uint96 amount) {
        return uint96(packed >> 80);
    }
}
