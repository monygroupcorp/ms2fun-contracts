// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interface used by ERC404BondingInstance to communicate with ERC404StakingModule.
interface IERC404StakingModule {
    /// @notice Activate staking for the calling instance. Irreversible. Caller must be a registered instance.
    function enableStaking() external;

    /// @notice Record that `user` staked `amount` tokens (tokens already transferred to instance).
    function recordStake(address user, uint256 amount) external;

    /// @notice Record that `user` unstaked `amount` tokens. Returns ETH reward instance must pay.
    function recordUnstake(address user, uint256 amount) external returns (uint256 rewardAmount);

    /// @notice Record that `delta` ETH arrived from vault fees (already in instance balance).
    function recordFeesReceived(uint256 delta) external;

    /// @notice Settle and clear `user`'s pending rewards. Returns ETH amount instance must pay.
    function computeClaim(address user) external returns (uint256 rewardAmount);
}
