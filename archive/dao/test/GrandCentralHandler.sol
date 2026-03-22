// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {GrandCentral} from "../../../src/dao/GrandCentral.sol";

/// @notice Invariant handler for GrandCentral share/loot/pool accounting
contract GrandCentralHandler is Test {
    GrandCentral public dao;
    address public safe;

    address[] public actors;
    mapping(address => bool) public isActor;

    // Ghost variables: sum of all individual shares/loot across actors
    uint256 public ghost_sumShares;
    uint256 public ghost_sumLoot;

    // Counters
    uint256 public ghost_mintSharesCalls;
    uint256 public ghost_mintLootCalls;
    uint256 public ghost_ragequitCalls;
    uint256 public ghost_claimCalls;

    constructor(GrandCentral _dao, address[] memory _actors) {
        dao = _dao;
        safe = _dao.safe();
        for (uint256 i = 0; i < _actors.length; i++) {
            actors.push(_actors[i]);
            isActor[_actors[i]] = true;
        }
        // Seed ghost with founder's initial shares
        for (uint256 i = 0; i < _actors.length; i++) {
            ghost_sumShares += dao.shares(_actors[i]);
            ghost_sumLoot += dao.loot(_actors[i]);
        }
    }

    function _getActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // ── Mint shares to a random actor ──

    function mintShares(uint256 actorSeed, uint256 amount) external {
        address to = _getActor(actorSeed);
        amount = bound(amount, 1, 1000 ether);

        address[] memory tos = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tos[0] = to;
        amounts[0] = amount;

        vm.prank(address(dao));
        dao.mintShares(tos, amounts);

        ghost_sumShares += amount;
        ghost_mintSharesCalls++;
    }

    // ── Burn shares from a random actor ──

    function burnShares(uint256 actorSeed, uint256 amount) external {
        address from = _getActor(actorSeed);
        uint256 bal = dao.shares(from);
        if (bal == 0) return;

        amount = bound(amount, 1, bal);

        address[] memory froms = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        froms[0] = from;
        amounts[0] = amount;

        vm.prank(address(dao));
        dao.burnShares(froms, amounts);

        ghost_sumShares -= amount;
    }

    // ── Mint loot to a random actor ──

    function mintLoot(uint256 actorSeed, uint256 amount) external {
        address to = _getActor(actorSeed);
        amount = bound(amount, 1, 1000 ether);

        address[] memory tos = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tos[0] = to;
        amounts[0] = amount;

        vm.prank(address(dao));
        dao.mintLoot(tos, amounts);

        ghost_sumLoot += amount;
        ghost_mintLootCalls++;
    }

    // ── Burn loot from a random actor ──

    function burnLoot(uint256 actorSeed, uint256 amount) external {
        address from = _getActor(actorSeed);
        uint256 bal = dao.loot(from);
        if (bal == 0) return;

        amount = bound(amount, 1, bal);

        address[] memory froms = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        froms[0] = from;
        amounts[0] = amount;

        vm.prank(address(dao));
        dao.burnLoot(froms, amounts);

        ghost_sumLoot -= amount;
    }

    // ── Fund ragequit pool from general funds ──

    function fundRagequitPool(uint256 amount) external {
        uint256 available = dao.generalFunds();
        if (available == 0) return;

        amount = bound(amount, 1, available);

        vm.prank(address(dao));
        dao.fundRagequitPool(amount);
    }

    // ── Fund claims pool from general funds ──

    function fundClaimsPool(uint256 amount) external {
        uint256 totalWeight = dao.totalShares() + dao.totalLoot();
        if (totalWeight == 0) return;

        uint256 available = dao.generalFunds();
        if (available == 0) return;

        amount = bound(amount, 1, available);

        vm.prank(address(dao));
        dao.fundClaimsPool(amount);
    }

    // ── Ragequit: burn shares+loot, receive proportional ragequit pool payout ──

    function ragequit(uint256 actorSeed, uint256 sharesToBurn, uint256 lootToBurn) external {
        address actor = _getActor(actorSeed);
        uint256 sharesBal = dao.shares(actor);
        uint256 lootBal = dao.loot(actor);

        if (sharesBal + lootBal == 0) return;

        sharesToBurn = bound(sharesToBurn, 0, sharesBal);
        lootToBurn = bound(lootToBurn, 0, lootBal);
        if (sharesToBurn + lootToBurn == 0) return;

        vm.prank(actor);
        dao.ragequit(sharesToBurn, lootToBurn);

        ghost_sumShares -= sharesToBurn;
        ghost_sumLoot -= lootToBurn;
        ghost_ragequitCalls++;
    }

    // ── Claim accumulated rewards ──

    function claim(uint256 actorSeed) external {
        address actor = _getActor(actorSeed);
        uint256 pending = dao.pendingClaim(actor);
        if (pending == 0) return;

        vm.prank(actor);
        dao.claim();

        ghost_claimCalls++;
    }

    function getActors() external view returns (address[] memory) {
        return actors;
    }
}
