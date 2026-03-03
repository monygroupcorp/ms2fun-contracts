// src/factories/erc404/ERC404StakingModule.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMasterRegistryMin {
    function isRegisteredInstance(address instance) external view returns (bool);
}

/**
 * @title ERC404StakingModule
 * @notice Factory-scoped singleton accounting backend for ERC404 staking
 * @dev Holds no ETH or tokens. All state keyed by instance address.
 *      Only registered instances (via MasterRegistry) can write to this module.
 *      ETH custody and token custody remain in the instance contract.
 *
 *      Authorization: msg.sender must be a registered instance in MasterRegistry.
 *      This is the same pattern used by GlobalMessageRegistry.
 *
 *      Accounting: rewardPerToken (Synthetix) model — rewardPerTokenStored
 *      accumulates ETH-per-staked-token (scaled 1e18) each time fees arrive.
 *      Each user checkpoint (rewardPerTokenPaid) records the rate at their last
 *      interaction, so late joiners cannot claim retroactive fees.
 */
contract ERC404StakingModule {
    error NotRegisteredInstance();
    error InvalidAddress();
    error AlreadyEnabled();
    error StakingNotEnabled();
    error AmountMustBePositive();
    error InsufficientStakedBalance();
    error NoStakedBalance();
    error NoPendingRewards();

    IMasterRegistryMin public immutable masterRegistry;

    // Per-instance state (all mappings keyed by instance address)
    mapping(address => bool) public stakingEnabled;
    mapping(address => mapping(address => uint256)) public stakedBalance;   // instance => user => amount
    mapping(address => uint256) public totalStaked;                          // instance => total

    // rewardPerToken accounting (replaces totalFeesAccumulated / feesAlreadyClaimed)
    mapping(address => uint256) public rewardPerTokenStored;                          // instance => cumulative ETH per staked token (scaled 1e18)
    mapping(address => mapping(address => uint256)) public rewardPerTokenPaid;        // instance => user => checkpoint
    mapping(address => mapping(address => uint256)) public rewardsAccrued;            // instance => user => unclaimed ETH

    event StakingEnabled(address indexed instance);
    event Staked(address indexed instance, address indexed user, uint256 amount, uint256 newTotal);
    event Unstaked(address indexed instance, address indexed user, uint256 amount, uint256 newTotal);
    event FeesReceived(address indexed instance, uint256 delta, uint256 newCumulative);
    event RewardsClaimed(address indexed instance, address indexed user, uint256 amount);

    modifier onlyRegisteredInstance() {
        if (!masterRegistry.isRegisteredInstance(msg.sender)) revert NotRegisteredInstance();
        _;
    }

    constructor(address _masterRegistry) {
        if (_masterRegistry == address(0)) revert InvalidAddress();
        masterRegistry = IMasterRegistryMin(_masterRegistry);
    }

    // ── Internal helpers ─────────────────────────────────────────────────────

    function _earned(address instance, address user) private view returns (uint256) {
        uint256 staked = stakedBalance[instance][user];
        uint256 rpt = rewardPerTokenStored[instance];
        uint256 paid = rewardPerTokenPaid[instance][user];
        return rewardsAccrued[instance][user] + (staked * (rpt - paid)) / 1e18; // round down: favors pool
    }

    // ── Write functions (instance-only) ──────────────────────────────────────

    /// @notice Enable staking for the calling instance. Irreversible.
    function enableStaking() external onlyRegisteredInstance {
        if (stakingEnabled[msg.sender]) revert AlreadyEnabled();
        stakingEnabled[msg.sender] = true;
        emit StakingEnabled(msg.sender);
    }

    /// @notice Record that `user` has staked `amount` tokens (tokens already in instance)
    function recordStake(address user, uint256 amount) external onlyRegisteredInstance {
        if (!stakingEnabled[msg.sender]) revert StakingNotEnabled();
        if (amount == 0) revert AmountMustBePositive();

        address instance = msg.sender;

        // Checkpoint: freeze user's entitlement at current rate before changing their balance
        rewardsAccrued[instance][user] = _earned(instance, user);
        rewardPerTokenPaid[instance][user] = rewardPerTokenStored[instance];

        // Now update balance
        stakedBalance[instance][user] += amount;
        totalStaked[instance] += amount;

        emit Staked(instance, user, amount, totalStaked[instance]);
    }

    /// @notice Record that `user` has unstaked `amount` tokens. Returns pending reward amount.
    /// @dev Caller (instance) must pay the returned rewardAmount to `user` in ETH.
    function recordUnstake(address user, uint256 amount)
        external
        onlyRegisteredInstance
        returns (uint256 rewardAmount)
    {
        if (!stakingEnabled[msg.sender]) revert StakingNotEnabled();
        if (amount == 0) revert AmountMustBePositive();
        if (stakedBalance[msg.sender][user] < amount) revert InsufficientStakedBalance();

        address instance = msg.sender;

        // Checkpoint before changing balance
        rewardsAccrued[instance][user] = _earned(instance, user);
        rewardPerTokenPaid[instance][user] = rewardPerTokenStored[instance];

        // Auto-claim
        rewardAmount = rewardsAccrued[instance][user];
        if (rewardAmount > 0) {
            rewardsAccrued[instance][user] = 0;
            emit RewardsClaimed(instance, user, rewardAmount);
        }

        stakedBalance[instance][user] -= amount;
        totalStaked[instance] -= amount;

        emit Unstaked(instance, user, amount, totalStaked[instance]);
    }

    /// @notice Record that `delta` ETH was received from vault (already in instance).
    /// @dev Instance calls this after vault.claimFees() transfers ETH to instance.
    ///      If totalStaked == 0, delta is silently unclaimable (held in instance, owner can withdrawDust).
    function recordFeesReceived(uint256 delta) external onlyRegisteredInstance {
        if (!stakingEnabled[msg.sender]) revert StakingNotEnabled();
        address instance = msg.sender;
        if (totalStaked[instance] > 0) {
            rewardPerTokenStored[instance] += (delta * 1e18) / totalStaked[instance]; // round down: dust stays in instance
        }
        emit FeesReceived(instance, delta, rewardPerTokenStored[instance]);
    }

    /// @notice Compute and record a claim for `user`. Returns ETH amount instance must pay.
    /// @dev Instance calls this, then transfers the returned amount to user in ETH.
    function computeClaim(address user)
        external
        onlyRegisteredInstance
        returns (uint256 rewardAmount)
    {
        address instance = msg.sender;
        if (!stakingEnabled[instance]) revert StakingNotEnabled();
        if (stakedBalance[instance][user] == 0) revert NoStakedBalance();

        rewardAmount = _earned(instance, user);
        if (rewardAmount == 0) revert NoPendingRewards();

        rewardsAccrued[instance][user] = 0;
        rewardPerTokenPaid[instance][user] = rewardPerTokenStored[instance];

        emit RewardsClaimed(instance, user, rewardAmount);
    }

    // ── View functions (public) ───────────────────────────────────────────────

    /// @notice Estimate pending rewards for a user without changing state
    function calculatePendingRewards(address instance, address user)
        external
        view
        returns (uint256)
    {
        if (!stakingEnabled[instance]) return 0;
        if (stakedBalance[instance][user] == 0) return 0;
        return _earned(instance, user);
    }

    /// @notice Get all staking stats for an instance+user pair
    function getStakingInfo(address instance, address user)
        external
        view
        returns (
            bool enabled,
            uint256 userStaked,
            uint256 globalTotalStaked,
            uint256 userProportion,  // basis points
            uint256 pendingRewards
        )
    {
        enabled = stakingEnabled[instance];
        userStaked = stakedBalance[instance][user];
        globalTotalStaked = totalStaked[instance];
        userProportion = globalTotalStaked > 0
            ? (userStaked * 10000) / globalTotalStaked // round down: view-only, no value transfer
            : 0;
        pendingRewards = _earned(instance, user);
    }
}
