// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ZAMMLiquidityDeployerModule} from "../../../src/factories/erc404zamm/ZAMMLiquidityDeployerModule.sol";
import {MockZAMM} from "../../mocks/MockZAMM.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockVault} from "../../mocks/MockVault.sol";

contract ZAMMLiquidityDeployerModuleTest is Test {
    ZAMMLiquidityDeployerModule module;
    MockZAMM zamm;
    MockERC20 token;
    MockVault vault;

    address treasury = address(0xBEEF);
    address instance = address(0xDEAD);

    function setUp() public {
        zamm = new MockZAMM();
        token = new MockERC20("Test", "TST");
        vault = new MockVault();
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
            protocolTreasury: treasury,
            vault: address(vault),
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

        // Fixed 1/19/80 split
        uint256 expectedProtocolFee = ethReserve / 100;
        uint256 expectedVaultCut    = (ethReserve * 19) / 100;
        assertEq(treasury.balance, expectedProtocolFee, "Protocol should receive 1%");
        assertEq(address(vault).balance, expectedVaultCut, "Vault should receive 19%");
    }

    function test_deployLiquidity_revertsOnETHMismatch() public {
        token.mint(address(module), 1000 ether);
        ZAMMLiquidityDeployerModule.DeployParams memory p = ZAMMLiquidityDeployerModule.DeployParams({
            ethReserve: 10 ether,
            tokenReserve: 1000 ether,
            protocolTreasury: treasury,
            vault: address(vault),
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
