// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ZAMMLiquidityDeployerModule} from "../../../src/factories/erc404zamm/ZAMMLiquidityDeployerModule.sol";
import {MockZAMM} from "../../mocks/MockZAMM.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

contract ZAMMLiquidityDeployerModuleTest is Test {
    ZAMMLiquidityDeployerModule module;
    MockZAMM zamm;
    MockERC20 token;

    address treasury = address(0xBEEF);
    address factoryCreator = address(0xCAFE);
    address instance = address(0xDEAD);

    function setUp() public {
        zamm = new MockZAMM();
        token = new MockERC20("Test", "TST");
        module = new ZAMMLiquidityDeployerModule();
    }

    function test_deployLiquidity_basicFlow() public {
        uint256 ethReserve = 10 ether;
        uint256 tokenReserve = 1000 ether;

        // Mint tokens to module (simulates instance transferring them before calling)
        token.mint(address(module), tokenReserve);

        ZAMMLiquidityDeployerModule.DeployParams memory p = ZAMMLiquidityDeployerModule.DeployParams({
            ethReserve: ethReserve,
            tokenReserve: tokenReserve,
            graduationFeeBps: 200,   // 2%
            creatorGraduationFeeBps: 50, // 0.5%
            polBps: 0,
            protocolTreasury: treasury,
            factoryCreator: factoryCreator,
            token: address(token),
            instance: instance,
            zamm: address(zamm),
            feeOrHook: 30 // 0.3% ZAMM fee
        });

        vm.deal(address(this), ethReserve);
        (ZAMMLiquidityDeployerModule.ZAMMPoolKey memory poolKey, uint256 liquidity) =
            module.deployLiquidity{value: ethReserve}(p);

        // Pool key should be set with correct token ordering
        assertEq(poolKey.feeOrHook, 30);
        assertGt(liquidity, 0);

        // Graduation fees paid
        uint256 expectedGradFee = (ethReserve * 200) / 10000;
        uint256 expectedCreatorCut = (ethReserve * 50) / 10000;
        assertEq(treasury.balance, expectedGradFee - expectedCreatorCut);
        assertEq(factoryCreator.balance, expectedCreatorCut);
    }

    function test_deployLiquidity_revertsOnETHMismatch() public {
        token.mint(address(module), 1000 ether);
        ZAMMLiquidityDeployerModule.DeployParams memory p = ZAMMLiquidityDeployerModule.DeployParams({
            ethReserve: 10 ether,
            tokenReserve: 1000 ether,
            graduationFeeBps: 200,
            creatorGraduationFeeBps: 0,
            polBps: 0,
            protocolTreasury: treasury,
            factoryCreator: factoryCreator,
            token: address(token),
            instance: instance,
            zamm: address(zamm),
            feeOrHook: 30
        });

        vm.deal(address(this), 5 ether);
        vm.expectRevert();
        module.deployLiquidity{value: 5 ether}(p);
    }
}
