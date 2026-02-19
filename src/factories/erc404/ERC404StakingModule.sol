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
 *      Accounting: Share-based watermark model — see ERC404StakingAccounting.t.sol
 *      for detailed explanation of the algorithm.
 */
contract ERC404StakingModule {
    IMasterRegistryMin public immutable masterRegistry;

    // Per-instance state (all mappings keyed by instance address)
    mapping(address => bool) public stakingEnabled;
    mapping(address => mapping(address => uint256)) public stakedBalance;   // instance => user => amount
    mapping(address => uint256) public totalStaked;                          // instance => total
    mapping(address => uint256) public totalFeesAccumulated;                 // instance => cumulative fees
    mapping(address => mapping(address => uint256)) public feesAlreadyClaimed; // instance => user => watermark

    event StakingEnabled(address indexed instance);
    event Staked(address indexed instance, address indexed user, uint256 amount, uint256 newTotal);
    event Unstaked(address indexed instance, address indexed user, uint256 amount, uint256 newTotal);
    event FeesReceived(address indexed instance, uint256 delta, uint256 newCumulative);
    event RewardsClaimed(address indexed instance, address indexed user, uint256 amount);

    modifier onlyRegisteredInstance() {
        require(masterRegistry.isRegisteredInstance(msg.sender), "Not registered instance");
        _;
    }

    constructor(address _masterRegistry) {
        require(_masterRegistry != address(0), "Invalid registry");
        masterRegistry = IMasterRegistryMin(_masterRegistry);
    }

    // ── Write functions (instance-only) ──────────────────────────────────────

    /// @notice Enable staking for the calling instance. Irreversible.
    function enableStaking() external onlyRegisteredInstance {
        require(!stakingEnabled[msg.sender], "Already enabled");
        stakingEnabled[msg.sender] = true;
        emit StakingEnabled(msg.sender);
    }

    /// @notice Record that `user` has staked `amount` tokens (tokens already in instance)
    function recordStake(address user, uint256 amount) external onlyRegisteredInstance {
        require(stakingEnabled[msg.sender], "Staking not enabled");
        require(amount > 0, "Amount must be positive");

        address instance = msg.sender;

        // If user has no prior stake and fees have accumulated, initialize their
        // watermark to their future entitlement so they don't claim retroactive fees.
        if (stakedBalance[instance][user] == 0 && totalFeesAccumulated[instance] > 0) {
            // After this stake, their share = amount / (totalStaked + amount)
            // Set watermark to that proportion of accumulated fees
            uint256 newTotal = totalStaked[instance] + amount;
            feesAlreadyClaimed[instance][user] =
                (totalFeesAccumulated[instance] * amount) / newTotal;
        }

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
        require(stakingEnabled[msg.sender], "Staking not enabled");
        require(stakedBalance[msg.sender][user] >= amount, "Insufficient staked balance");

        address instance = msg.sender;

        // Auto-claim pending rewards before reducing stake
        if (totalStaked[instance] > 0 && totalFeesAccumulated[instance] > 0) {
            uint256 entitlement =
                (totalFeesAccumulated[instance] * stakedBalance[instance][user]) / totalStaked[instance];
            uint256 alreadyClaimed = feesAlreadyClaimed[instance][user];
            if (entitlement > alreadyClaimed) {
                rewardAmount = entitlement - alreadyClaimed;
                feesAlreadyClaimed[instance][user] = entitlement;
                emit RewardsClaimed(instance, user, rewardAmount);
            }
        }

        stakedBalance[instance][user] -= amount;
        totalStaked[instance] -= amount;

        emit Unstaked(instance, user, amount, totalStaked[instance]);
    }

    /// @notice Record that `delta` ETH was received from vault (already in instance).
    /// @dev Instance calls this after vault.claimFees() transfers ETH to instance.
    function recordFeesReceived(uint256 delta) external onlyRegisteredInstance {
        require(stakingEnabled[msg.sender], "Staking not enabled");
        totalFeesAccumulated[msg.sender] += delta;
        emit FeesReceived(msg.sender, delta, totalFeesAccumulated[msg.sender]);
    }

    /// @notice Compute and record a claim for `user`. Returns ETH amount instance must pay.
    /// @dev Instance calls this, then transfers the returned amount to user in ETH.
    function computeClaim(address user)
        external
        onlyRegisteredInstance
        returns (uint256 rewardAmount)
    {
        address instance = msg.sender;
        require(stakingEnabled[instance], "Staking not enabled");
        require(stakedBalance[instance][user] > 0, "No staked balance");
        require(totalStaked[instance] > 0, "No stakers");

        uint256 entitlement =
            (totalFeesAccumulated[instance] * stakedBalance[instance][user]) / totalStaked[instance];
        uint256 alreadyClaimed = feesAlreadyClaimed[instance][user];

        require(entitlement > alreadyClaimed, "No pending rewards");

        rewardAmount = entitlement - alreadyClaimed;
        feesAlreadyClaimed[instance][user] = entitlement;

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
        if (totalStaked[instance] == 0) return 0;

        uint256 entitlement =
            (totalFeesAccumulated[instance] * stakedBalance[instance][user]) / totalStaked[instance];
        uint256 alreadyClaimed = feesAlreadyClaimed[instance][user];

        return entitlement > alreadyClaimed ? entitlement - alreadyClaimed : 0;
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
            ? (userStaked * 10000) / globalTotalStaked
            : 0;
        pendingRewards = this.calculatePendingRewards(instance, user);
    }
}
