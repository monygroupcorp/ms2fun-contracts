// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title VotingPower
 * @notice Library for calculating voting power
 */
library VotingPower {
    /**
     * @notice Calculate voting power based on EXEC balance
     * @param balance EXEC token balance
     * @return Voting power (1:1 with balance)
     */
    function calculateVotingPower(uint256 balance) internal pure returns (uint256) {
        return balance; // 1 EXEC = 1 vote
    }

    /**
     * @notice Calculate weighted voting power with time decay
     * @param balance EXEC token balance
     * @param holdingTime Time tokens have been held
     * @param decayPeriod Period for full decay
     * @return Weighted voting power
     */
    function calculateWeightedVotingPower(
        uint256 balance,
        uint256 holdingTime,
        uint256 decayPeriod
    ) internal pure returns (uint256) {
        if (holdingTime >= decayPeriod) {
            return balance; // Full voting power after decay period
        }

        // Linear decay: voting power increases with holding time
        uint256 multiplier = (holdingTime * 1e18) / decayPeriod;
        return (balance * multiplier) / 1e18;
    }

    /**
     * @notice Check if account has minimum voting power
     * @param balance EXEC token balance
     * @param minimum Minimum required voting power
     * @return True if account has sufficient voting power
     */
    function hasMinimumVotingPower(
        uint256 balance,
        uint256 minimum
    ) internal pure returns (bool) {
        return balance >= minimum;
    }
}

