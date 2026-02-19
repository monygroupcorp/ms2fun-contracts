// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LiquidityDeployer} from "../../../src/factories/erc404/libraries/LiquidityDeployer.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract LiquidityDeployerTest is Test {
    function test_computeAmounts_splitsFees() public pure {
        LiquidityDeployer.DeployParams memory p = LiquidityDeployer.DeployParams({
            ethReserve: 10 ether,
            tokenReserve: 1000 ether,
            graduationFeeBps: 200,   // 2%
            creatorGraduationFeeBps: 50, // 0.5%
            polBps: 100,             // 1%
            protocolTreasury: address(0x1),
            factoryCreator: address(0x2),
            weth: address(0x3),
            token: address(0x4),
            poolFee: 3000,
            tickSpacing: 60,
            v4Hook: IHooks(address(0)),
            v4PoolManager: IPoolManager(address(0))
        });

        LiquidityDeployer.AmountsResult memory r = LiquidityDeployer.computeAmounts(p);

        // graduationFee = 10 ether * 200 / 10000 = 0.2 ether
        assertEq(r.graduationFee, 0.2 ether);
        // creatorGradCut = 10 ether * 50 / 10000 = 0.05 ether
        assertEq(r.creatorGradCut, 0.05 ether);
        // ethAfterGrad = 10 - 0.2 = 9.8 ether
        // polETH = 9.8 * 100 / 10000 = 0.098 ether
        assertEq(r.polETH, 0.098 ether);
        // ethForPool = 9.8 - 0.098 = 9.702 ether
        assertEq(r.ethForPool, 9.702 ether);
        // tokensForPool = 1000 ether - (1000 ether * 100 / 10000) = 1000 - 10 = 990 ether
        assertEq(r.tokensForPool, 990 ether);
    }

    function test_computeAmounts_noFees() public pure {
        LiquidityDeployer.DeployParams memory p = LiquidityDeployer.DeployParams({
            ethReserve: 10 ether,
            tokenReserve: 1000 ether,
            graduationFeeBps: 0,
            creatorGraduationFeeBps: 0,
            polBps: 0,
            protocolTreasury: address(0),
            factoryCreator: address(0),
            weth: address(0x3),
            token: address(0x4),
            poolFee: 3000,
            tickSpacing: 60,
            v4Hook: IHooks(address(0)),
            v4PoolManager: IPoolManager(address(0))
        });

        LiquidityDeployer.AmountsResult memory r = LiquidityDeployer.computeAmounts(p);
        assertEq(r.ethForPool, 10 ether);
        assertEq(r.tokensForPool, 1000 ether);
        assertEq(r.graduationFee, 0);
        assertEq(r.polETH, 0);
    }

    function test_computeSqrtPrice_token0IsThis() public pure {
        // When token is currency0 (token0IsThis=true), price = sqrt(eth/tokens)
        // More ETH per token = higher price
        uint160 highPrice = LiquidityDeployer.computeSqrtPrice(10 ether, 100 ether, true);  // 0.1 ETH/token
        uint160 lowPrice = LiquidityDeployer.computeSqrtPrice(1 ether, 100 ether, true);   // 0.01 ETH/token
        assertGt(highPrice, lowPrice, "Higher ETH/token ratio should produce higher sqrtPrice");
    }
}
