// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MessagePacking
 * @notice Library for packing and unpacking bonding curve message data
 * @dev Packs timestamp, amount, and buy flag into a single uint128 value
 */
library MessagePacking {
    /// @notice Packs timestamp, amount and buy flag into a single uint128 value
    /// @dev Packs data in the following format:
    ///      - timestamp: highest 32 bits
    ///      - amount: middle 95 bits (in ether, can store up to ~3.94e28 ether)
    ///      - isBuy flag: lowest bit
    /// @param timestamp The timestamp to pack (32 bits)
    /// @param amount The amount to pack (95 bits)
    /// @param isBuy The buy flag to pack (1 bit)
    /// @return packed The packed uint128 containing all data
    function packData(uint32 timestamp, uint96 amount, bool isBuy) internal pure returns (uint128) {
        return uint128(
            (uint128(timestamp) << 96) |  // timestamp in highest 32 bits
            (uint128(amount) << 1) |      // amount in middle 95 bits
            (isBuy ? 1 : 0)              // isBuy flag in lowest bit
        );
    }

    /// @notice Unpacks a uint128 value into timestamp, amount and buy flag components
    /// @dev Unpacks data from the following format:
    ///      - timestamp: highest 32 bits
    ///      - amount: middle 95 bits
    ///      - isBuy flag: lowest bit
    /// @param packed The packed uint128 to unpack
    /// @return timestamp The unpacked timestamp (32 bits)
    /// @return amount The unpacked amount (95 bits)
    /// @return isBuy The unpacked buy flag (1 bit)
    function unpackData(uint128 packed) internal pure returns (uint32 timestamp, uint96 amount, bool isBuy) {
        timestamp = uint32(packed >> 96);
        uint256 amountMask = (uint256(1) << 95) - 1;
        amount = uint96((packed >> 1) & amountMask);
        isBuy = (packed & 1) == 1;
    }
}

