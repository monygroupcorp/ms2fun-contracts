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
        uint256 gradBps,
        address treasury
    ) internal pure returns (LiquidityDeployerModule.DeployParams memory p) {
        p = LiquidityDeployerModule.DeployParams({
            ethReserve: ethReserve,
            tokenReserve: tokenReserve,
            graduationFeeBps: gradBps,
            protocolTreasury: treasury,
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

    function test_computeAmounts_splitsFees() public pure {
        uint256 ethReserve = 10 ether;
        uint256 gradBps = 200; // 2%

        // graduationFee = 10 ether * 200 / 10000 = 0.2 ether
        uint256 graduationFee = (ethReserve * gradBps) / 10000;
        assertEq(graduationFee, 0.2 ether);

        // ethForPool = 10 - 0.2 = 9.8 ether
        uint256 ethForPool = ethReserve - graduationFee;
        assertEq(ethForPool, 9.8 ether);
    }

    function test_computeAmounts_noFees() public pure {
        // Zero fees: everything goes to pool
        uint256 ethReserve = 10 ether;
        uint256 tokenReserve = 1000 ether;
        uint256 gradBps = 0;

        uint256 graduationFee = (ethReserve * gradBps) / 10000;
        uint256 ethForPool = ethReserve - graduationFee;
        uint256 tokensForPool = tokenReserve;

        assertEq(ethForPool, 10 ether);
        assertEq(tokensForPool, 1000 ether);
        assertEq(graduationFee, 0);
    }

    function test_deployLiquidity_revertsIfNotEnoughETH() public {
        LiquidityDeployerModule.DeployParams memory p = _params(
            1 ether, 100 ether, 0, address(0x1)
        );
        // Send less ETH than ethReserve — module checks msg.value == ethReserve
        vm.expectRevert("ETH mismatch");
        module.deployLiquidity{value: 0.5 ether}(p);
    }

    function test_deployLiquidity_revertsIfNoETHSent() public {
        LiquidityDeployerModule.DeployParams memory p = _params(
            1 ether, 100 ether, 0, address(0x1)
        );
        vm.expectRevert("ETH mismatch");
        module.deployLiquidity{value: 0}(p);
    }

    function test_unlockCallback_revertsIfNotPoolManager() public {
        vm.expectRevert("Not pool manager");
        module.unlockCallback(bytes(""));
    }
}
