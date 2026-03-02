// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ICurveComputer} from "../../src/interfaces/ICurveComputer.sol";
import {BondingCurveMath} from "../../src/factories/erc404/libraries/BondingCurveMath.sol";

contract MockCurveComputer is ICurveComputer {
    function computeCurveParams(
        uint256 nftCount,
        uint256 targetETH,
        uint256 unitPerNFT,
        uint256 liquidityReserveBps
    ) external pure override returns (BondingCurveMath.Params memory) {
        return BondingCurveMath.Params({
            initialPrice: targetETH / nftCount,
            quarticCoeff: 3 gwei,
            cubicCoeff: 1333333333,
            quadraticCoeff: 2 gwei,
            normalizationFactor: unitPerNFT * 1e7
        });
    }
}

contract ICurveComputerTest is Test {
    MockCurveComputer computer;

    function setUp() public {
        computer = new MockCurveComputer();
    }

    function test_computeCurveParams_returnsParams() public {
        BondingCurveMath.Params memory p = computer.computeCurveParams(100, 15 ether, 1e6, 2000);
        assertGt(p.initialPrice, 0);
        assertGt(p.normalizationFactor, 0);
    }
}
