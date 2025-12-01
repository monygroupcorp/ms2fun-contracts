// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title EditionMessagePacking
 * @notice Library for packing and unpacking ERC1155 edition mint message data
 * @dev Packs timestamp, editionId, and amount into a single uint128 value
 */
library EditionMessagePacking {
    /// @notice Packs timestamp, editionId and amount into a single uint128 value
    /// @dev Packs data in the following format:
    ///      - timestamp: highest 32 bits
    ///      - editionId: middle 32 bits
    ///      - amount: lowest 32 bits
    /// @param timestamp The timestamp to pack (32 bits)
    /// @param editionId The edition ID to pack (32 bits)
    /// @param amount The amount to pack (32 bits)
    /// @return packed The packed uint128 containing all data
    function packData(uint32 timestamp, uint32 editionId, uint32 amount) internal pure returns (uint128) {
        require(editionId <= type(uint32).max, "EditionId too large");
        require(amount <= type(uint32).max, "Amount too large");
        
        return uint128(
            (uint128(timestamp) << 96) |  // timestamp in highest 32 bits
            (uint128(editionId) << 64) |  // editionId in middle 32 bits
            (uint128(amount))             // amount in lowest 32 bits
        );
    }

    /// @notice Unpacks a uint128 value into timestamp, editionId and amount components
    /// @dev Unpacks data from the following format:
    ///      - timestamp: highest 32 bits
    ///      - editionId: middle 32 bits
    ///      - amount: lowest 32 bits
    /// @param packed The packed uint128 to unpack
    /// @return timestamp The unpacked timestamp (32 bits)
    /// @return editionId The unpacked edition ID (32 bits)
    /// @return amount The unpacked amount (32 bits)
    function unpackData(uint128 packed) internal pure returns (uint32 timestamp, uint32 editionId, uint32 amount) {
        timestamp = uint32(packed >> 96);
        editionId = uint32((packed >> 64) & 0xFFFFFFFF);
        amount = uint32(packed & 0xFFFFFFFF);
    }
}

