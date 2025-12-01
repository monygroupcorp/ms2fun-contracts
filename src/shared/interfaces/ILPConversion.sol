// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ILPConversion
 * @notice Interface for LP conversion operations across V2, V3, and V4
 */
interface ILPConversion {
    // ========== Events ==========

    event ConversionInitiated(
        uint8 indexed poolType,
        uint256 ethAmount,
        uint256 targetTokenAmount,
        uint256 reward
    );

    event LiquidityAdded(
        uint8 indexed poolType,
        address indexed pool,
        uint256 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    // ========== V4 Conversion ==========

    /**
     * @notice Convert accumulated ETH to LP position in V4 pool
     * @param poolManager V4 PoolManager address
     * @param minOut Minimum target tokens to receive from swap
     * @return liquidityAdded Amount of liquidity added
     * @return amount0 Amount of token0 used
     * @return amount1 Amount of token1 used
     */
    function convertToV4Liquidity(
        address poolManager,
        uint256 minOut
    ) external payable returns (
        uint256 liquidityAdded,
        uint256 amount0,
        uint256 amount1
    );

    // ========== V3 Conversion ==========

    /**
     * @notice Convert accumulated ETH to LP position in V3 pool
     * @param positionManager V3 NFT Position Manager address
     * @param minOut Minimum target tokens to receive from swap
     * @return tokenId NFT ID of new position
     * @return liquidity Amount of liquidity added
     * @return amount0 Amount of token0 used
     * @return amount1 Amount of token1 used
     */
    function convertToV3Liquidity(
        address positionManager,
        uint256 minOut
    ) external payable returns (
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    // ========== V2 Conversion ==========

    /**
     * @notice Convert accumulated ETH to LP position in V2 pool
     * @param router V2 Router02 address
     * @param minOut Minimum target tokens to receive from swap
     * @return lpTokens Amount of LP tokens received
     * @return amount0 Amount of token0 used
     * @return amount1 Amount of token1 used
     */
    function convertToV2Liquidity(
        address router,
        uint256 minOut
    ) external payable returns (
        uint256 lpTokens,
        uint256 amount0,
        uint256 amount1
    );
}
