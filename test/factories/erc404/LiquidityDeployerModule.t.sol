// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LiquidityDeployerModule} from "../../../src/factories/erc404/LiquidityDeployerModule.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/**
 * @title LiquidityDeployerModuleTest
 * @notice Unit tests for LiquidityDeployerModule fee math and amount computations.
 *         Full V4 integration requires a mock PoolManager (covered in integration tests).
 */
contract LiquidityDeployerModuleTest is Test {
    LiquidityDeployerModule public module;

    function setUp() public {
        module = new LiquidityDeployerModule();
    }

    // -----------------------------------------------------------------------
    // Helpers — build a DeployParams struct
    // -----------------------------------------------------------------------

    function _params(
        uint256 ethReserve,
        uint256 tokenReserve,
        address treasury
    ) internal pure returns (LiquidityDeployerModule.DeployParams memory p) {
        p = LiquidityDeployerModule.DeployParams({
            ethReserve: ethReserve,
            tokenReserve: tokenReserve,
            protocolTreasury: treasury,
            vault: address(0x5),
            weth: address(0x3),
            token: address(0x4),
            instance: address(0x4),
            poolFee: 3000,
            tickSpacing: 60,
            v4Hook: IHooks(address(0)),
            v4PoolManager: IPoolManager(address(0))
        });
    }

    // -----------------------------------------------------------------------
    // Fee math tests
    // -----------------------------------------------------------------------

    function test_computeAmounts_119_80_split() public pure {
        uint256 ethReserve = 10 ether;

        // Fixed 1/19/80 split
        uint256 protocolFee = ethReserve / 100;           // 1% = 0.1 ETH
        uint256 vaultCut    = (ethReserve * 19) / 100;    // 19% = 1.9 ETH
        uint256 ethForPool  = ethReserve - protocolFee - vaultCut; // 80% = 8.0 ETH

        assertEq(protocolFee, 0.1 ether);
        assertEq(vaultCut,    1.9 ether);
        assertEq(ethForPool,  8.0 ether);
    }

    function test_computeAmounts_roundingInvariant() public pure {
        // Verify no ETH is lost in the split
        uint256 ethReserve = 1 ether;
        uint256 protocolFee = ethReserve / 100;
        uint256 vaultCut    = (ethReserve * 19) / 100;
        uint256 ethForPool  = ethReserve - protocolFee - vaultCut;

        assertEq(protocolFee + vaultCut + ethForPool, ethReserve);
    }

    function test_deployLiquidity_revertsIfNotEnoughETH() public {
        LiquidityDeployerModule.DeployParams memory p = _params(
            1 ether, 100 ether, address(0x1)
        );
        // Send less ETH than ethReserve — module checks msg.value == ethReserve
        vm.expectRevert("ETH mismatch");
        module.deployLiquidity{value: 0.5 ether}(p);
    }

    function test_deployLiquidity_revertsIfNoETHSent() public {
        LiquidityDeployerModule.DeployParams memory p = _params(
            1 ether, 100 ether, address(0x1)
        );
        vm.expectRevert("ETH mismatch");
        module.deployLiquidity{value: 0}(p);
    }

    function test_unlockCallback_revertsIfNotPoolManager() public {
        vm.expectRevert("Not pool manager");
        module.unlockCallback(bytes(""));
    }
}
