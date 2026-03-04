// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ZAMMAlignmentVault, IZAMM} from "../../../src/vaults/zamm/ZAMMAlignmentVault.sol";
import {MockZAMM} from "../../mocks/MockZAMM.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @notice Invariant handler for ZAMMAlignmentVault share accounting
contract ZAMMVaultHandler is Test {
    ZAMMAlignmentVault public vault;
    MockZAMM public mockZamm;

    address[] public actors;
    mapping(address => bool) public isActor;

    // Ghost variables for tracking
    uint256 public ghost_totalContributed;
    mapping(address => uint256) public ghost_actorContributed;
    uint256 public ghost_totalClaimed;
    bool public ghost_hasLP;
    uint256 public ghost_conversions;

    constructor(ZAMMAlignmentVault _vault, MockZAMM _mockZamm, address[] memory _actors) {
        vault = _vault;
        mockZamm = _mockZamm;
        for (uint256 i = 0; i < _actors.length; i++) {
            actors.push(_actors[i]);
            isActor[_actors[i]] = true;
        }
    }

    function _getActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function contribute(uint256 actorSeed, uint256 amount) external {
        amount = bound(amount, 0.01 ether, 10 ether);
        address actor = _getActor(actorSeed);

        vm.deal(actor, actor.balance + amount);
        vm.prank(actor);
        vault.receiveContribution{value: amount}(Currency.wrap(address(0)), amount, actor);

        ghost_totalContributed += amount;
        ghost_actorContributed[actor] += amount;
    }

    function contributeViaReceive(uint256 actorSeed, uint256 amount) external {
        amount = bound(amount, 0.01 ether, 10 ether);
        address actor = _getActor(actorSeed);

        vm.deal(actor, actor.balance + amount);
        vm.prank(actor);
        (bool ok,) = address(vault).call{value: amount}("");
        require(ok, "send failed");

        ghost_totalContributed += amount;
        ghost_actorContributed[actor] += amount;
    }

    function convertAndAddLiquidity() external {
        if (vault.pendingETH() == 0) return;

        // Ensure pool has reserves for the swap math
        uint256 pid = vault.poolId();
        IZAMM.Pool memory pool = IZAMM(vault.zamm()).pools(pid);
        if (pool.reserve0 == 0) {
            mockZamm.setPool(pid, 10 ether, 10_000e18, 1000 ether);
        }

        vault.convertAndAddLiquidity(0, 0, 0);
        ghost_hasLP = true;
        ghost_conversions++;
    }

    function harvest() external {
        if (vault.totalContributions() == 0) return;
        if (!ghost_hasLP) return;

        // Simulate fee growth by setting ethPerLp higher
        mockZamm.setEthPerLp(0.002 ether);
        mockZamm.setTokenPerLp(0.002 ether);
        vm.deal(address(mockZamm), 100 ether);

        vault.harvest(0);

        // Reset to normal
        mockZamm.setEthPerLp(1e15);
        mockZamm.setTokenPerLp(1e15);
    }

    function claimFees(uint256 actorSeed) external {
        address actor = _getActor(actorSeed);
        if (vault.benefactorContribution(actor) == 0) return;

        uint256 claimable = vault.calculateClaimableAmount(actor);
        if (claimable == 0) return;

        vm.prank(actor);
        uint256 claimed = vault.claimFees();
        ghost_totalClaimed += claimed;
    }

    function withdrawProtocolFees() external {
        if (vault.accumulatedProtocolFees() == 0) return;
        vault.withdrawProtocolFees();
    }

    function getActors() external view returns (address[] memory) {
        return actors;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}
