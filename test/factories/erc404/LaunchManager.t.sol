// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LaunchManager} from "../../../src/factories/erc404/LaunchManager.sol";
import {ICurveComputer} from "../../../src/interfaces/ICurveComputer.sol";
import {BondingCurveMath} from "../../../src/factories/erc404/libraries/BondingCurveMath.sol";

contract MockCurveComputer is ICurveComputer {
    function computeCurveParams(uint256, uint256, uint256, uint256)
        external pure returns (BondingCurveMath.Params memory)
    {
        return BondingCurveMath.Params({
            initialPrice: 1,
            quarticCoeff: 1,
            cubicCoeff: 1,
            quadraticCoeff: 1,
            normalizationFactor: 1
        });
    }
}

contract LaunchManagerTest is Test {
    LaunchManager launchMgr;
    address protocolAdmin = address(0xAD111);
    MockCurveComputer mockCurve;

    function setUp() public {
        launchMgr = new LaunchManager(protocolAdmin);
        mockCurve = new MockCurveComputer();
    }

    function test_setPreset_storesPreset() public {
        vm.startPrank(protocolAdmin);
        launchMgr.setPreset(1, LaunchManager.Preset({
            targetETH: 15 ether,
            unitPerNFT: 1e6,
            liquidityReserveBps: 2000,
            curveComputer: address(mockCurve),
            active: true
        }));
        LaunchManager.Preset memory p = launchMgr.getPreset(1);
        assertEq(p.targetETH, 15 ether);
        assertEq(p.unitPerNFT, 1e6);
        assertEq(p.liquidityReserveBps, 2000);
        assertEq(p.curveComputer, address(mockCurve));
        assertTrue(p.active);
        vm.stopPrank();
    }

    function test_setPreset_revertsIfNotOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        launchMgr.setPreset(1, LaunchManager.Preset({
            targetETH: 15 ether,
            unitPerNFT: 1e6,
            liquidityReserveBps: 2000,
            curveComputer: address(0x1),
            active: true
        }));
    }

    function test_getPreset_revertsIfNotActive() public {
        vm.expectRevert("Preset not active");
        launchMgr.getPreset(99);
    }
}
