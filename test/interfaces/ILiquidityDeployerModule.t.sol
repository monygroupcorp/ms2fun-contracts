// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ILiquidityDeployerModule} from "../../src/interfaces/ILiquidityDeployerModule.sol";

contract MockDeployer is ILiquidityDeployerModule {
    bool public called;
    uint256 public receivedEth;

    function deployLiquidity(DeployParams calldata p) external payable override {
        called = true;
        receivedEth = msg.value;
        require(msg.value == p.ethReserve, "ETH mismatch");
    }
}

contract ILiquidityDeployerModuleTest is Test {
    MockDeployer deployer;

    function setUp() public {
        deployer = new MockDeployer();
    }

    function test_deployLiquidity_callsThrough() public {
        ILiquidityDeployerModule.DeployParams memory p = ILiquidityDeployerModule.DeployParams({
            ethReserve: 1 ether,
            tokenReserve: 1_000_000e18,
            protocolTreasury: address(0x1),
            vault: address(0x2),
            token: address(0x3),
            instance: address(0x3)
        });
        deployer.deployLiquidity{value: 1 ether}(p);
        assertTrue(deployer.called());
        assertEq(deployer.receivedEth(), 1 ether);
    }
}
