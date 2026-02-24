// test/interfaces/AlgebraInterfaces.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "forge-std/Test.sol";
import "../../src/interfaces/algebra/IAlgebra.sol";

contract AlgebraInterfacesTest is Test {
    function test_mintParamsHasDeployerField() public view {
        // Compile check: MintParams with deployer field compiles
        IAlgebraNFTPositionManager.MintParams memory p = IAlgebraNFTPositionManager.MintParams({
            token0: address(1), token1: address(2), deployer: address(0),
            tickLower: -887220, tickUpper: 887220,
            amount0Desired: 1e18, amount1Desired: 1e18,
            amount0Min: 0, amount1Min: 0,
            recipient: address(3), deadline: block.timestamp + 1
        });
        assertEq(p.deployer, address(0));
    }

    function test_swapParamsHasLimitSqrtPrice() public view {
        IAlgebraSwapRouter.ExactInputSingleParams memory p = IAlgebraSwapRouter.ExactInputSingleParams({
            tokenIn: address(1), tokenOut: address(2),
            recipient: address(3), deadline: block.timestamp + 1,
            amountIn: 1e18, amountOutMinimum: 0, limitSqrtPrice: 0
        });
        assertEq(p.limitSqrtPrice, 0);
    }
}
