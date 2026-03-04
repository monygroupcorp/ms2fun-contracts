// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC404BondingInstance} from "../../../src/factories/erc404/ERC404BondingInstance.sol";
import {BondingCurveMath} from "../../../src/factories/erc404/libraries/BondingCurveMath.sol";

/// @notice Invariant handler for ERC404BondingInstance bonding curve reserve accounting
contract BondingCurveHandler is Test {
    ERC404BondingInstance public instance;
    BondingCurveMath.Params public curveParams;

    address[] public actors;
    mapping(address => bool) public isActor;

    // Ghost variables
    uint256 public ghost_totalBuyCost;
    uint256 public ghost_totalSellRefund;
    uint256 public ghost_buyCount;
    uint256 public ghost_sellCount;

    constructor(ERC404BondingInstance _instance, BondingCurveMath.Params memory _curveParams, address[] memory _actors) {
        instance = _instance;
        curveParams = _curveParams;
        for (uint256 i = 0; i < _actors.length; i++) {
            actors.push(_actors[i]);
            isActor[_actors[i]] = true;
        }
    }

    function _getActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function buy(uint256 actorSeed, uint256 amount) external {
        address actor = _getActor(actorSeed);

        uint256 unit_ = instance.unit();
        // Bound to at least 1 NFT worth, at most 5 NFTs worth
        amount = bound(amount, unit_, 5 * unit_);

        uint256 maxBondingSupply = instance.maxSupply() - instance.liquidityReserve()
            - (instance.freeMintAllocation() * unit_);
        uint256 currentSupply = instance.totalBondingSupply();

        // Skip if would exceed bonding cap
        if (currentSupply + amount > maxBondingSupply) return;

        uint256 cost = BondingCurveMath.calculateCost(curveParams, currentSupply, amount);
        if (cost == 0) return;

        uint256 bondingFee = (cost * instance.bondingFeeBps()) / 10000;
        uint256 totalWithFee = cost + bondingFee;

        vm.deal(actor, actor.balance + totalWithFee);
        vm.prank(actor);
        instance.buyBonding{value: totalWithFee}(amount, totalWithFee, false, bytes32(0), "", 0);

        ghost_totalBuyCost += cost;
        ghost_buyCount++;
    }

    function sell(uint256 actorSeed, uint256 nftCount) external {
        address actor = _getActor(actorSeed);

        uint256 unit_ = instance.unit();
        uint256 balance = instance.balanceOf(actor);
        if (balance < unit_) return;

        // Bound NFT count between 1 and what actor holds
        uint256 maxNfts = balance / unit_;
        nftCount = bound(nftCount, 1, maxNfts);
        uint256 amount = nftCount * unit_;

        // Don't sell if bonding is capped (the contract reverts)
        uint256 maxBondingSupply = instance.maxSupply() - instance.liquidityReserve()
            - (instance.freeMintAllocation() * unit_);
        if (instance.totalBondingSupply() >= maxBondingSupply) return;

        uint256 refund = BondingCurveMath.calculateRefund(curveParams, instance.totalBondingSupply(), amount);
        if (refund == 0 || instance.reserve() < refund) return;

        vm.prank(actor);
        instance.sellBonding(amount, 0, bytes32(0), "", 0);

        ghost_totalSellRefund += refund;
        ghost_sellCount++;
    }

    function getActors() external view returns (address[] memory) {
        return actors;
    }
}
