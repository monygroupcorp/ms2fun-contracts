// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {GrandCentral} from "../../src/dao/GrandCentral.sol";
import {MockSafe} from "../mocks/MockSafe.sol";
import {GrandCentralHandler} from "./handlers/GrandCentralHandler.sol";

contract GrandCentralInvariantTest is StdInvariant, Test {
    GrandCentral public dao;
    MockSafe public mockSafe;
    GrandCentralHandler public handler;

    address public founder = address(0xF000);
    address[] public actors;

    uint256 constant INITIAL_SHARES = 100 ether;
    uint32 constant VOTING_PERIOD = 2 days;
    uint32 constant GRACE_PERIOD = 1 days;
    uint256 constant QUORUM = 51;
    uint256 constant SPONSOR_THRESHOLD = 10 ether;
    uint256 constant MIN_RETENTION = 66;

    function setUp() public {
        mockSafe = new MockSafe();
        dao = new GrandCentral(
            address(mockSafe), founder, INITIAL_SHARES,
            VOTING_PERIOD, GRACE_PERIOD, QUORUM,
            SPONSOR_THRESHOLD, MIN_RETENTION
        );

        // Fund the safe so pool operations have ETH to work with
        vm.deal(address(mockSafe), 1000 ether);

        // Enable the DAO as a module on the safe (for ragequit/claim payouts)
        mockSafe.enableModule(address(dao));

        actors.push(founder);
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCAFE));

        handler = new GrandCentralHandler(dao, actors);

        targetContract(address(handler));
    }

    // ── Invariant 1: sum(members[i].shares) == totalShares ──

    function invariant_sharesSumMatchesTotal() public view {
        assertEq(
            handler.ghost_sumShares(),
            dao.totalShares(),
            "sum of member shares != totalShares"
        );
    }

    // ── Invariant 2: sum(members[i].loot) == totalLoot ──

    function invariant_lootSumMatchesTotal() public view {
        assertEq(
            handler.ghost_sumLoot(),
            dao.totalLoot(),
            "sum of member loot != totalLoot"
        );
    }

    // ── Invariant 3: ragequitPool + claimsPoolBalance <= safe.balance ──
    // The reserved pools must never exceed the actual ETH backing.

    function invariant_poolsNeverExceedBacking() public view {
        uint256 reserved = dao.ragequitPool() + dao.claimsPoolBalance();
        assertLe(
            reserved,
            address(mockSafe).balance,
            "ragequitPool + claimsPool > safe.balance"
        );
    }
}
