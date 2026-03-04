// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {UniAlignmentVault} from "../../../src/vaults/uni/UniAlignmentVault.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @notice Invariant handler for UniAlignmentVault share accounting
contract UniVaultHandler is Test {
    UniAlignmentVault public vault;

    address[] public actors;
    mapping(address => bool) public isActor;

    // Ghost variables for tracking
    uint256 public ghost_totalContributed;
    mapping(address => uint256) public ghost_actorContributed;
    uint256 public ghost_totalClaimed;
    bool public ghost_hasLP;
    uint256 public ghost_conversions;
    // Snapshot shares at each conversion to track dilution
    mapping(address => uint256) public ghost_sharesSnapshot;
    mapping(address => uint256) public ghost_ethAtConversion;

    constructor(UniAlignmentVault _vault, address[] memory _actors) {
        vault = _vault;
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
        if (vault.totalPendingETH() == 0) return;

        // Snapshot pre-conversion shares
        uint256[] memory preShares = new uint256[](actors.length);
        for (uint256 i = 0; i < actors.length; i++) {
            preShares[i] = vault.benefactorShares(actors[i]);
        }
        uint256 preTotalShares = vault.totalShares();

        vault.convertAndAddLiquidity(0);
        ghost_hasLP = true;
        ghost_conversions++;

        // Track new shares issued this conversion per actor
        uint256 newTotalShares = vault.totalShares() - preTotalShares;
        if (newTotalShares > 0) {
            for (uint256 i = 0; i < actors.length; i++) {
                uint256 newShares = vault.benefactorShares(actors[i]) - preShares[i];
                ghost_sharesSnapshot[actors[i]] += newShares;
                // ethAtConversion tracks how much ETH this actor had pending for this conversion
                // (already captured in ghost_actorContributed)
            }
        }
    }

    function depositFees(uint256 amount) external {
        amount = bound(amount, 0.001 ether, 1 ether);
        if (vault.totalShares() == 0) return;

        vm.deal(vault.owner(), amount);
        vm.prank(vault.owner());
        vault.depositFees{value: amount}();
    }

    function claimFees(uint256 actorSeed) external {
        address actor = _getActor(actorSeed);
        if (vault.benefactorShares(actor) == 0) return;
        if (vault.accumulatedFees() == 0) return;

        uint256 currentShareValue = (vault.accumulatedFees() * vault.benefactorShares(actor)) / vault.totalShares();
        uint256 ethClaimed = currentShareValue > vault.shareValueAtLastClaim(actor)
            ? currentShareValue - vault.shareValueAtLastClaim(actor)
            : 0;
        if (ethClaimed == 0) return;

        vm.prank(actor);
        uint256 claimed = vault.claimFees();
        ghost_totalClaimed += claimed;
    }

    function withdrawProtocolFees() external {
        if (vault.accumulatedProtocolFees() == 0) return;
        if (vault.protocolTreasury() == address(0)) return;

        vault.withdrawProtocolFees();
    }

    function getActors() external view returns (address[] memory) {
        return actors;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }
}
