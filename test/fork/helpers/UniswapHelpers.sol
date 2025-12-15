// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title UniswapHelpers
 * @notice Library of reusable helper functions for Uniswap math and calculations
 * @dev Provides utilities for:
 *      - Price conversions (sqrtPriceX96 ↔ price ↔ tick)
 *      - Liquidity calculations for concentrated positions
 *      - Swap output estimations
 *      - Tick math helpers
 */
library UniswapHelpers {
    // ========== Constants ==========

    uint256 constant Q96 = 0x1000000000000000000000000; // 2^96

    // Minimum and maximum tick values from Uniswap V3
    int24 constant MIN_TICK = -887272;
    int24 constant MAX_TICK = 887272;

    // ========== sqrtPrice Conversions ==========

    /**
     * @notice Convert sqrtPriceX96 to human-readable price
     * @param sqrtPriceX96 Square root of price in Q96 format
     * @return price Price scaled by 1e18 (token1/token0)
     */
    function sqrtPriceX96ToPrice(uint160 sqrtPriceX96) internal pure returns (uint256 price) {
        // Price = (sqrtPriceX96 / 2^96)^2
        // We scale by 1e18 for precision
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        price = (sqrtPrice * sqrtPrice * 1e18) >> 192;
    }

    /**
     * @notice Convert price to sqrtPriceX96
     * @param price Price scaled by 1e18 (token1/token0)
     * @return sqrtPriceX96 Square root of price in Q96 format
     */
    function priceToSqrtPriceX96(uint256 price) internal pure returns (uint160 sqrtPriceX96) {
        // sqrtPrice = sqrt(price / 1e18) * 2^96
        uint256 sqrtPrice = sqrt((price << 192) / 1e18);
        sqrtPriceX96 = uint160(sqrtPrice);
    }

    /**
     * @notice Get sqrtPriceX96 at a specific tick
     * @param tick The tick value
     * @return sqrtPriceX96 Square root of price at tick
     * @dev Simplified implementation - for production use TickMath from v4-core
     */
    function getSqrtPriceAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        require(tick >= MIN_TICK && tick <= MAX_TICK, "Tick out of bounds");

        // Simplified approximation: sqrtPrice = 1.0001^(tick/2) * 2^96
        // For testing purposes - use Uniswap's TickMath for production
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));

        // Use simplified exponential approximation
        uint256 ratio = 0x100000000000000000000000000000000; // 2^128
        if (absTick & 0x1 != 0) ratio = (ratio * 0xfffcb933bd6fad37aa2d162d1a594001) >> 128;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        // ... more tick calculations would go here for full precision
        // Simplified for testing

        if (tick > 0) sqrtPriceX96 = uint160((ratio >> 32));
        else sqrtPriceX96 = uint160((type(uint256).max / ratio) >> 32);
    }

    /**
     * @notice Get tick at a specific sqrtPriceX96
     * @param sqrtPriceX96 Square root of price in Q96 format
     * @return tick The tick value
     * @dev Simplified implementation - for production use TickMath from v4-core
     */
    function getTickAtSqrtPrice(uint160 sqrtPriceX96) internal pure returns (int24 tick) {
        // Simplified inverse calculation
        // For production, use binary search or Uniswap's TickMath
        uint256 price = sqrtPriceX96ToPrice(sqrtPriceX96);

        // Approximate: tick = log₁.₀₀₀₁(price)
        // Very rough approximation for testing
        if (price >= 1e18) {
            tick = int24(int256((price - 1e18) / 1e14)); // Rough scaling
        } else {
            tick = -int24(int256((1e18 - price) / 1e14));
        }

        // Clamp to valid range
        if (tick < MIN_TICK) tick = MIN_TICK;
        if (tick > MAX_TICK) tick = MAX_TICK;
    }

    // ========== Liquidity Calculations ==========

    /**
     * @notice Calculate liquidity for a position given token amounts
     * @param sqrtPriceX96 Current sqrtPrice of the pool
     * @param sqrtPriceAX96 sqrtPrice at lower tick
     * @param sqrtPriceBX96 sqrtPrice at upper tick
     * @param amount0 Amount of token0
     * @param amount1 Amount of token1
     * @return liquidity Liquidity value
     * @dev Simplified - use LiquidityAmounts from v4-core for production
     */
    function getLiquidityForAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            // Current price below range, only token0 needed
            liquidity = getLiquidityForAmount0(sqrtPriceAX96, sqrtPriceBX96, amount0);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            // Current price in range, both tokens needed
            uint128 liquidity0 = getLiquidityForAmount0(sqrtPriceX96, sqrtPriceBX96, amount0);
            uint128 liquidity1 = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceX96, amount1);
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            // Current price above range, only token1 needed
            liquidity = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceBX96, amount1);
        }
    }

    /**
     * @notice Calculate liquidity for amount0
     * @param sqrtPriceAX96 sqrtPrice at lower tick
     * @param sqrtPriceBX96 sqrtPrice at upper tick
     * @param amount0 Amount of token0
     * @return liquidity Liquidity value
     */
    function getLiquidityForAmount0(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        uint256 intermediate = (uint256(sqrtPriceAX96) * sqrtPriceBX96) / Q96;
        liquidity = uint128((amount0 * intermediate) / (sqrtPriceBX96 - sqrtPriceAX96));
    }

    /**
     * @notice Calculate liquidity for amount1
     * @param sqrtPriceAX96 sqrtPrice at lower tick
     * @param sqrtPriceBX96 sqrtPrice at upper tick
     * @param amount1 Amount of token1
     * @return liquidity Liquidity value
     */
    function getLiquidityForAmount1(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        liquidity = uint128((amount1 * Q96) / (sqrtPriceBX96 - sqrtPriceAX96));
    }

    // ========== V2 Calculations ==========

    /**
     * @notice Calculate V2 swap output using constant product formula
     * @param amountIn Amount of input token
     * @param reserveIn Reserve of input token
     * @param reserveOut Reserve of output token
     * @return amountOut Amount of output token (accounting for 0.3% fee)
     */
    function calculateV2Output(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "Insufficient input amount");
        require(reserveIn > 0 && reserveOut > 0, "Insufficient liquidity");

        // V2 applies 0.3% fee: amountInWithFee = amountIn * 997
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /**
     * @notice Calculate V2 swap input for desired output
     * @param amountOut Desired output amount
     * @param reserveIn Reserve of input token
     * @param reserveOut Reserve of output token
     * @return amountIn Required input amount (accounting for 0.3% fee)
     */
    function calculateV2Input(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountIn)
    {
        require(amountOut > 0, "Insufficient output amount");
        require(reserveIn > 0 && reserveOut > amountOut, "Insufficient liquidity");

        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    // ========== Math Utilities ==========

    /**
     * @notice Calculate square root using Babylonian method
     * @param x Value to find square root of
     * @return y Square root of x
     */
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /**
     * @notice Get absolute value of signed integer
     * @param x Signed integer
     * @return Absolute value
     */
    function abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    /**
     * @notice Get minimum of two values
     * @param a First value
     * @param b Second value
     * @return Minimum value
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @notice Get maximum of two values
     * @param a First value
     * @param b Second value
     * @return Maximum value
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    // ========== Fee Tier Helpers ==========

    /**
     * @notice Get tick spacing for a V3 fee tier
     * @param fee Fee in hundredths of bips (e.g., 500 for 0.05%)
     * @return tickSpacing Tick spacing for the fee tier
     */
    function getTickSpacing(uint24 fee) internal pure returns (int24 tickSpacing) {
        if (fee == 500) return 10;        // 0.05% → 10
        if (fee == 3000) return 60;       // 0.3% → 60
        if (fee == 10000) return 200;     // 1% → 200
        revert("Unknown fee tier");
    }

    /**
     * @notice Round tick down to nearest valid tick for fee tier
     * @param tick Tick to round
     * @param tickSpacing Tick spacing
     * @return Rounded tick
     */
    function roundTickDown(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 remainder = tick % tickSpacing;
        if (remainder == 0) return tick;
        if (remainder < 0) return tick - (tickSpacing + remainder);
        return tick - remainder;
    }

    /**
     * @notice Round tick up to nearest valid tick for fee tier
     * @param tick Tick to round
     * @param tickSpacing Tick spacing
     * @return Rounded tick
     */
    function roundTickUp(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 remainder = tick % tickSpacing;
        if (remainder == 0) return tick;
        if (remainder > 0) return tick + (tickSpacing - remainder);
        return tick - remainder;
    }
}
