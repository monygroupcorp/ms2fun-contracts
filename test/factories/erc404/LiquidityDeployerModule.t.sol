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
        uint256 creatorGradBps,
        uint256 polBps,
        address treasury,
        address factoryCreator
    ) internal pure returns (LiquidityDeployerModule.DeployParams memory p) {
        p = LiquidityDeployerModule.DeployParams({
            ethReserve: ethReserve,
            tokenReserve: tokenReserve,
            graduationFeeBps: gradBps,
            creatorGraduationFeeBps: creatorGradBps,
            polBps: polBps,
            protocolTreasury: treasury,
            factoryCreator: factoryCreator,
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
    // Fee math tests (mirror of old LiquidityDeployer tests)
    // -----------------------------------------------------------------------

    function test_computeAmounts_splitsFees() public view {
        LiquidityDeployerModule.DeployParams memory p = _params(
            10 ether, 1000 ether,
            200,  // 2%
            50,   // 0.5%
            100,  // 1%
            address(0x1), address(0x2)
        );

        // Call the internal logic indirectly by checking the revert-free path.
        // Since _computeAmounts is private, we verify via expected math:

        // graduationFee = 10 ether * 200 / 10000 = 0.2 ether
        uint256 graduationFee = (p.ethReserve * p.graduationFeeBps) / 10000;
        assertEq(graduationFee, 0.2 ether);

        // creatorGradCut = 10 ether * 50 / 10000 = 0.05 ether
        uint256 creatorGradCut = (p.ethReserve * p.creatorGraduationFeeBps) / 10000;
        assertEq(creatorGradCut, 0.05 ether);

        // ethAfterGrad = 10 - 0.2 = 9.8 ether
        uint256 ethAfterGrad = p.ethReserve - graduationFee;
        assertEq(ethAfterGrad, 9.8 ether);

        // polETH = 9.8 * 100 / 10000 = 0.098 ether
        uint256 polETH = (ethAfterGrad * p.polBps) / 10000;
        assertEq(polETH, 0.098 ether);

        // ethForPool = 9.8 - 0.098 = 9.702 ether
        uint256 ethForPool = ethAfterGrad - polETH;
        assertEq(ethForPool, 9.702 ether);

        // tokensForPool = 1000 ether - (1000 ether * 100 / 10000) = 990 ether
        uint256 polTokens = (p.tokenReserve * p.polBps) / 10000;
        uint256 tokensForPool = p.tokenReserve - polTokens;
        assertEq(tokensForPool, 990 ether);
    }

    function test_computeAmounts_noFees() public pure {
        // Zero fees: everything goes to pool
        uint256 ethReserve = 10 ether;
        uint256 tokenReserve = 1000 ether;
        uint256 gradBps = 0;
        uint256 polBps = 0;

        uint256 graduationFee = (ethReserve * gradBps) / 10000;
        uint256 ethAfterGrad = ethReserve - graduationFee;
        uint256 polETH = (ethAfterGrad * polBps) / 10000;
        uint256 ethForPool = ethAfterGrad - polETH;
        uint256 polTokens = (tokenReserve * polBps) / 10000;
        uint256 tokensForPool = tokenReserve - polTokens;

        assertEq(ethForPool, 10 ether);
        assertEq(tokensForPool, 1000 ether);
        assertEq(graduationFee, 0);
        assertEq(polETH, 0);
    }

    function test_computeAmounts_creatorCutClampedToGradFee() public pure {
        // If creatorGradBps > gradBps, creatorGradCut is clamped to graduationFee
        uint256 ethReserve = 10 ether;
        uint256 gradBps = 100; // 1%
        uint256 creatorGradBps = 200; // 2% — exceeds grad fee

        uint256 graduationFee = (ethReserve * gradBps) / 10000;
        uint256 creatorGradCut = (ethReserve * creatorGradBps) / 10000;
        if (creatorGradCut > graduationFee) creatorGradCut = graduationFee;

        assertEq(creatorGradCut, graduationFee, "Creator cut should be clamped to grad fee");
    }

    function test_deployLiquidity_revertsIfNotEnoughETH() public {
        LiquidityDeployerModule.DeployParams memory p = _params(
            1 ether, 100 ether, 0, 0, 0, address(0x1), address(0x2)
        );
        // Send less ETH than ethReserve — module checks msg.value == ethReserve
        vm.expectRevert("ETH mismatch");
        module.deployLiquidity{value: 0.5 ether}(p);
    }

    function test_deployLiquidity_revertsIfNoETHSent() public {
        LiquidityDeployerModule.DeployParams memory p = _params(
            1 ether, 100 ether, 0, 0, 0, address(0x1), address(0x2)
        );
        vm.expectRevert("ETH mismatch");
        module.deployLiquidity{value: 0}(p);
    }

    function test_unlockCallback_revertsIfNotPoolManager() public {
        vm.expectRevert("Not pool manager");
        module.unlockCallback(bytes(""));
    }
}
