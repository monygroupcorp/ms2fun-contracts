// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal Algebra V2 factory interface
interface IAlgebraFactory {
    function createPool(address tokenA, address tokenB, bytes calldata data) external returns (address pool);
    function poolByPair(address tokenA, address tokenB) external view returns (address pool);
}

/// @notice Minimal Algebra V2 pool interface
interface IAlgebraPool {
    function initialize(uint160 sqrtPriceX96) external;
    function globalState() external view returns (
        uint160 price, int24 tick, uint16 lastFee,
        uint8 pluginConfig, uint16 communityFee, bool unlocked
    );
}

/// @notice Algebra V2 NonFungiblePositionManager (adds deployer field vs Uniswap V3)
interface IAlgebraNFTPositionManager {
    struct MintParams {
        address token0;
        address token1;
        address deployer;     // Algebra-specific: typically address(0)
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params)
        external payable
        returns (uint256 amount0, uint256 amount1);

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external payable
        returns (uint256 amount0, uint256 amount1);

    /// @dev Returns 12 values: nonce, operator, token0, token1, deployer,
    ///      tickLower, tickUpper, liquidity, feeGrowth0, feeGrowth1, tokensOwed0, tokensOwed1
    function positions(uint256 tokenId)
        external view
        returns (
            uint88 nonce, address operator,
            address token0, address token1, address deployer,
            int24 tickLower, int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0, uint128 tokensOwed1
        );

    function approve(address spender, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

/// @notice Algebra V2 SwapRouter (uses limitSqrtPrice instead of sqrtPriceLimitX96)
interface IAlgebraSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 limitSqrtPrice;  // Algebra-specific (0 = no limit)
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external payable
        returns (uint256 amountOut);
}
