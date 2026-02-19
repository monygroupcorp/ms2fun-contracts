// test/factories/erc404/ERC404StakingModule.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC404StakingModule} from "../../../src/factories/erc404/ERC404StakingModule.sol";

contract MockMasterRegistry {
    mapping(address => bool) public instances;
    function setInstance(address a, bool v) external { instances[a] = v; }
    function isRegisteredInstance(address a) external view returns (bool) { return instances[a]; }
}

contract ERC404StakingModuleTest is Test {
    ERC404StakingModule public module;
    MockMasterRegistry public registry;

    address public instance1 = address(0xA1);
    address public instance2 = address(0xA2);
    address public user1 = address(0xB1);
    address public user2 = address(0xB2);

    function setUp() public {
        registry = new MockMasterRegistry();
        module = new ERC404StakingModule(address(registry));
        registry.setInstance(instance1, true);
        registry.setInstance(instance2, true);
    }

    function test_enableStaking_onlyRegisteredInstance() public {
        // Unregistered address cannot enable staking
        vm.prank(address(0xDEAD));
        vm.expectRevert("Not registered instance");
        module.enableStaking();
    }

    function test_enableStaking_setsFlag() public {
        vm.prank(instance1);
        module.enableStaking();
        assertTrue(module.stakingEnabled(instance1));
    }

    function test_enableStaking_irreversible() public {
        vm.prank(instance1);
        module.enableStaking();
        vm.prank(instance1);
        vm.expectRevert("Already enabled");
        module.enableStaking();
    }

    function test_recordStake_requiresStakingEnabled() public {
        vm.prank(instance1);
        vm.expectRevert("Staking not enabled");
        module.recordStake(user1, 100 ether);
    }

    function test_recordStake_updatesBalances() public {
        vm.prank(instance1);
        module.enableStaking();

        vm.prank(instance1);
        module.recordStake(user1, 100 ether);

        assertEq(module.stakedBalance(instance1, user1), 100 ether);
        assertEq(module.totalStaked(instance1), 100 ether);
    }

    function test_recordStake_twoUsers() public {
        vm.prank(instance1);
        module.enableStaking();

        vm.prank(instance1);
        module.recordStake(user1, 100 ether);
        vm.prank(instance1);
        module.recordStake(user2, 300 ether);

        assertEq(module.totalStaked(instance1), 400 ether);
    }

    function test_recordUnstake_reducesBalances() public {
        vm.prank(instance1);
        module.enableStaking();
        vm.prank(instance1);
        module.recordStake(user1, 100 ether);
        vm.prank(instance1);
        module.recordUnstake(user1, 40 ether);

        assertEq(module.stakedBalance(instance1, user1), 60 ether);
        assertEq(module.totalStaked(instance1), 60 ether);
    }

    function test_recordUnstake_insufficientBalance_reverts() public {
        vm.prank(instance1);
        module.enableStaking();
        vm.prank(instance1);
        module.recordStake(user1, 100 ether);

        vm.prank(instance1);
        vm.expectRevert("Insufficient staked balance");
        module.recordUnstake(user1, 101 ether);
    }

    function test_recordFeesReceived_updatesRewardPerToken() public {
        vm.prank(instance1);
        module.enableStaking();
        vm.prank(instance1);
        module.recordStake(user1, 100 ether);  // need a staker for rate to update

        vm.prank(instance1);
        module.recordFeesReceived(50 ether);

        // rewardPerTokenStored = (50 ETH * 1e18) / 100 ether = 0.5 ETH per token (scaled)
        assertEq(module.rewardPerTokenStored(instance1), 0.5 ether);
    }

    function test_computeClaim_twoStakers_shareBasedAccounting() public {
        // Reproduce the share-based accounting scenario from ERC404StakingAccounting.t.sol
        vm.prank(instance1);
        module.enableStaking();

        // Both stake equal amounts
        vm.prank(instance1);
        module.recordStake(user1, 100 ether);
        vm.prank(instance1);
        module.recordStake(user2, 100 ether);

        // Vault sends 100 ETH in fees
        vm.prank(instance1);
        module.recordFeesReceived(100 ether);

        // User1 claims — should get 50 ETH
        vm.prank(instance1);
        uint256 user1Payout = module.computeClaim(user1);
        assertEq(user1Payout, 50 ether);

        // Vault sends 100 more ETH (200 cumulative)
        vm.prank(instance1);
        module.recordFeesReceived(100 ether);

        // User2 claims — should get 100 ETH (full 50% of 200 total, nothing claimed yet)
        vm.prank(instance1);
        uint256 user2Payout = module.computeClaim(user2);
        assertEq(user2Payout, 100 ether);

        // User1 claims again — should get 50 ETH (50% of 200 = 100, minus 50 already claimed)
        vm.prank(instance1);
        uint256 user1SecondPayout = module.computeClaim(user1);
        assertEq(user1SecondPayout, 50 ether);
    }

    function test_recordStake_lateJoiner_doesNotDilutePriorStaker() public {
        vm.prank(instance1);
        module.enableStaking();

        // user1 stakes first
        vm.prank(instance1);
        module.recordStake(user1, 100 ether);

        // Fees arrive while user1 is sole staker — user1 entitled to all of it
        vm.prank(instance1);
        module.recordFeesReceived(100 ether);

        // user2 joins late
        vm.prank(instance1);
        module.recordStake(user2, 100 ether);

        // More fees arrive, now 50/50
        vm.prank(instance1);
        module.recordFeesReceived(100 ether);

        // user1: 100 ETH (sole epoch) + 50 ETH (shared epoch) = 150 ETH
        vm.prank(instance1);
        uint256 user1Payout = module.computeClaim(user1);
        assertEq(user1Payout, 150 ether);

        // user2: 0 ETH (before stake) + 50 ETH (shared epoch) = 50 ETH
        vm.prank(instance1);
        uint256 user2Payout = module.computeClaim(user2);
        assertEq(user2Payout, 50 ether);
    }

    function test_computeClaim_noPendingRewards_reverts() public {
        vm.prank(instance1);
        module.enableStaking();
        vm.prank(instance1);
        module.recordStake(user1, 100 ether);

        vm.prank(instance1);
        vm.expectRevert("No pending rewards");
        module.computeClaim(user1);
    }

    function test_instancesAreIsolated() public {
        // instance1 staking state should not affect instance2
        vm.prank(instance1);
        module.enableStaking();
        vm.prank(instance1);
        module.recordStake(user1, 100 ether);

        assertEq(module.stakingEnabled(instance2), false);
        assertEq(module.stakedBalance(instance2, user1), 0);
        assertEq(module.totalStaked(instance2), 0);
    }

    function test_calculatePendingRewards_viewOnly() public {
        vm.prank(instance1);
        module.enableStaking();
        vm.prank(instance1);
        module.recordStake(user1, 100 ether);
        vm.prank(instance1);
        module.recordFeesReceived(100 ether);

        // View function should return 100 ETH pending without changing state
        uint256 pending = module.calculatePendingRewards(instance1, user1);
        assertEq(pending, 100 ether);

        // State should be unchanged — calling again returns same value
        assertEq(module.calculatePendingRewards(instance1, user1), 100 ether);
    }
}
