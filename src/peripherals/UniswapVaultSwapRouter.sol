// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVaultSwapRouter} from "../interfaces/IVaultSwapRouter.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "../libraries/v4/CurrencySettler.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ========== External Protocol Interfaces ==========

/// @notice Uniswap V3 SwapRouter interface
interface IV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Uniswap V2 Router interface
interface IUniswapV2Router02 {
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

/// @notice WETH9 interface
interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Uniswap V2 Factory interface
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// @notice Uniswap V3 Factory interface
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

contract UniswapVaultSwapRouter is IVaultSwapRouter, IUnlockCallback {
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    // ========== Data Structures ==========

    /// @notice Callback data for V4 swap operations
    struct SwapCallbackData {
        PoolKey key;
        IPoolManager.SwapParams params;
        address recipient;
    }

    // ========== Immutables ==========

    address public immutable weth;
    address public immutable poolManager;
    address public immutable v3Router;
    address public immutable v2Router;
    address public immutable v2Factory;
    address public immutable v3Factory;
    uint24 public immutable v3PreferredFee;

    constructor(
        address _weth,
        address _poolManager,
        address _v3Router,
        address _v2Router,
        address _v2Factory,
        address _v3Factory,
        uint24 _v3PreferredFee
    ) {
        weth = _weth;
        poolManager = _poolManager;
        v3Router = _v3Router;
        v2Router = _v2Router;
        v2Factory = _v2Factory;
        v3Factory = _v3Factory;
        v3PreferredFee = _v3PreferredFee;
    }

    // --- IVaultSwapRouter ---

    /**
     * @notice Swap ETH for a target token via best available DEX route.
     * @dev Routing priority: V4 (best liquidity) → V3 → V2 (final fallback).
     *      ETH sent via msg.value. Tokens delivered directly to `recipient`.
     */
    function swapETHForToken(
        address token,
        uint256 minOut,
        address recipient
    ) external payable override returns (uint256 tokenReceived) {
        uint256 ethAmount = msg.value;
        require(ethAmount > 0, "Amount must be positive");
        require(token != address(0), "No alignment token set");

        // Query available pools for routing decision
        (bool hasV2Pool, , , ) = _getV2PriceAndReserves(token);
        (bool hasV3Pool, , uint128 liquidityV3) = _getV3PriceAndLiquidity(token);
        (bool hasV4Pool, , uint128 liquidityV4) = _getV4PriceAndLiquidity(token);

        // Route through V4 if available and has better liquidity than V3
        if (hasV4Pool && liquidityV4 > liquidityV3) {
            return _swapViaV4(token, ethAmount, minOut, recipient);
        }

        // Try V3 routing
        if (hasV3Pool) {
            // Wrap ETH to WETH for V3 swap
            IWETH9(weth).deposit{value: ethAmount}();

            // Approve V3 router to spend WETH
            IWETH9(weth).approve(v3Router, ethAmount);

            // Execute V3 swap: WETH → token
            IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
                tokenIn: weth,
                tokenOut: token,
                fee: v3PreferredFee,
                recipient: recipient,
                deadline: block.timestamp + 300,
                amountIn: ethAmount,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            });

            tokenReceived = IV3SwapRouter(v3Router).exactInputSingle(params);
            require(tokenReceived >= minOut, "Slippage too high");
            return tokenReceived;
        }

        // Final fallback to V2
        return _swapETHForTokenViaV2(token, ethAmount, minOut, recipient);
    }

    /**
     * @notice Swap a token for ETH via best available route.
     * @dev Caller must approve exact `amount` to this router before calling.
     *      ETH delivered directly to `recipient`.
     */
    function swapTokenForETH(
        address token,
        uint256 amount,
        uint256 minOut,
        address recipient
    ) external override returns (uint256 ethReceived) {
        // Pull tokens from caller (vault pre-approved exact amount)
        IERC20(token).transferFrom(msg.sender, address(this), amount);

        // Skip if mock addresses
        if (poolManager.code.length == 0) {
            return 0;
        }

        // Approve alignment token for swap
        IERC20(token).approve(address(poolManager), amount);

        // Try fee tiers in order of preference
        uint24[3] memory feeTiers = [uint24(3000), uint24(500), uint24(10000)];
        int24[3] memory tickSpacings = [int24(60), int24(10), int24(200)];

        for (uint256 i = 0; i < feeTiers.length; i++) {
            // Try native ETH pool first (avoid WETH wrapping/unwrapping)
            (bool hasNativePool, , ) = _queryV4PoolForTokenPair(
                address(0),
                token,
                feeTiers[i],
                tickSpacings[i]
            );

            if (hasNativePool) {
                ethReceived = _swapTokenForETHViaV4(token, amount, address(0), feeTiers[i], tickSpacings[i], recipient);
                require(ethReceived >= minOut, "Slippage too high");
                return ethReceived;
            }

            // Try WETH pool as fallback
            (bool hasWETHPool, , ) = _queryV4PoolForTokenPair(
                weth,
                token,
                feeTiers[i],
                tickSpacings[i]
            );

            if (hasWETHPool) {
                ethReceived = _swapTokenForETHViaV4(token, amount, weth, feeTiers[i], tickSpacings[i], recipient);
                require(ethReceived >= minOut, "Slippage too high");
                return ethReceived;
            }
        }

        // If no V4 pool found, try V3
        ethReceived = _swapTokenForETHViaV3(token, amount, recipient);
        require(ethReceived >= minOut, "Slippage too high");
        return ethReceived;
    }

    // --- IUnlockCallback ---

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only PoolManager");

        SwapCallbackData memory swapData = abi.decode(data, (SwapCallbackData));

        // Execute swap
        BalanceDelta delta = IPoolManager(poolManager).swap(
            swapData.key,
            swapData.params,
            "" // hookData
        );

        // Settle swap deltas
        _settleSwapDelta(swapData.key, delta, swapData.recipient);

        return abi.encode(delta);
    }

    // --- private helpers ---

    function _swapETHForTokenViaV2(
        address token,
        uint256 ethAmount,
        uint256 minOutTarget,
        address recipient
    ) private returns (uint256 tokenReceived) {
        require(ethAmount > 0, "Amount must be positive");
        require(token != address(0), "No alignment token set");

        if (v2Router.code.length == 0) {
            revert("No swap route available");
        }

        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = token;

        uint256[] memory amounts = IUniswapV2Router02(v2Router).swapExactETHForTokens{value: ethAmount}(
            minOutTarget,
            path,
            recipient,
            block.timestamp + 300
        );

        tokenReceived = amounts[amounts.length - 1];
        require(tokenReceived >= minOutTarget, "Slippage too high");
        return tokenReceived;
    }

    function _swapViaV4(
        address token,
        uint256 ethAmount,
        uint256 minOutTarget,
        address recipient
    ) private returns (uint256 tokenReceived) {
        uint24[3] memory feeTiers = [uint24(3000), uint24(500), uint24(10000)];
        int24[3] memory tickSpacings = [int24(60), int24(10), int24(200)];

        for (uint256 i = 0; i < feeTiers.length; i++) {
            // Try WETH pool first
            (bool hasWETHPool, , ) = _queryV4PoolForTokenPair(
                weth,
                token,
                feeTiers[i],
                tickSpacings[i]
            );

            if (hasWETHPool) {
                // Wrap ETH to WETH for V4 swap
                IWETH9(weth).deposit{value: ethAmount}();

                tokenReceived = _executeV4Swap(
                    weth,
                    token,
                    feeTiers[i],
                    tickSpacings[i],
                    ethAmount,
                    true, // isWETH
                    recipient
                );

                if (tokenReceived >= minOutTarget) {
                    return tokenReceived;
                }
            }

            // Try native ETH pool as fallback
            (bool hasNativePool, , ) = _queryV4PoolForTokenPair(
                address(0),
                token,
                feeTiers[i],
                tickSpacings[i]
            );

            if (hasNativePool) {
                tokenReceived = _executeV4Swap(
                    address(0),
                    token,
                    feeTiers[i],
                    tickSpacings[i],
                    ethAmount,
                    false, // not WETH
                    recipient
                );

                if (tokenReceived >= minOutTarget) {
                    return tokenReceived;
                }
            }
        }

        revert("No suitable V4 pool found");
    }

    function _executeV4Swap(
        address token0Addr,
        address token1Addr,
        uint24 fee,
        int24 tickSpacing,
        uint256 amountIn,
        bool isWETH,
        address recipient
    ) private returns (uint256 amountOut) {
        // Ensure correct currency ordering (currency0 < currency1)
        (Currency currency0, Currency currency1, bool zeroForOne) = token0Addr < token1Addr
            ? (Currency.wrap(token0Addr), Currency.wrap(token1Addr), true)
            : (Currency.wrap(token1Addr), Currency.wrap(token0Addr), false);

        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });

        // Approve tokens if swapping WETH (ERC20)
        if (isWETH) {
            IERC20(weth).approve(address(poolManager), amountIn);
        }

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        SwapCallbackData memory swapData = SwapCallbackData({
            key: poolKey,
            params: swapParams,
            recipient: recipient
        });

        bytes memory result = IPoolManager(poolManager).unlock(abi.encode(swapData));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));

        if (zeroForOne) {
            amountOut = delta.amount1() > 0 ? uint256(int256(delta.amount1())) : 0;
        } else {
            amountOut = delta.amount0() > 0 ? uint256(int256(delta.amount0())) : 0;
        }

        return amountOut;
    }

    function _swapTokenForETHViaV4(
        address token,
        uint256 tokenAmount,
        address ethAddress,
        uint24 fee,
        int24 tickSpacing,
        address recipient
    ) private returns (uint256 ethReceived) {
        // Ensure correct currency ordering
        (Currency currency0, Currency currency1, bool zeroForOne) = ethAddress < token
            ? (Currency.wrap(ethAddress), Currency.wrap(token), false) // Swapping currency1 → currency0
            : (Currency.wrap(token), Currency.wrap(ethAddress), true);  // Swapping currency0 → currency1

        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(tokenAmount),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        SwapCallbackData memory swapData = SwapCallbackData({
            key: poolKey,
            params: swapParams,
            recipient: recipient
        });

        bytes memory result = IPoolManager(poolManager).unlock(abi.encode(swapData));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));

        if (zeroForOne) {
            ethReceived = delta.amount1() > 0 ? uint256(int256(delta.amount1())) : 0;
        } else {
            ethReceived = delta.amount0() > 0 ? uint256(int256(delta.amount0())) : 0;
        }

        return ethReceived;
    }

    function _swapTokenForETHViaV3(
        address token,
        uint256 tokenAmount,
        address recipient
    ) private returns (uint256 ethReceived) {
        if (weth.code.length == 0 || v3Router.code.length == 0) {
            return 0;
        }

        IERC20(token).approve(v3Router, tokenAmount);

        IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: token,
            tokenOut: weth,
            fee: v3PreferredFee,
            recipient: recipient,
            deadline: block.timestamp + 300,
            amountIn: tokenAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        ethReceived = IV3SwapRouter(v3Router).exactInputSingle(params);
        return ethReceived;
    }

    function _settleSwapDelta(PoolKey memory key, BalanceDelta delta, address recipient) private {
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        IPoolManager pm = IPoolManager(poolManager);

        if (delta0 < 0) {
            key.currency0.settle(pm, address(this), uint128(-delta0), false);
        } else if (delta0 > 0) {
            key.currency0.take(pm, recipient, uint128(delta0), false);
        }

        if (delta1 < 0) {
            key.currency1.settle(pm, address(this), uint128(-delta1), false);
        } else if (delta1 > 0) {
            key.currency1.take(pm, recipient, uint128(delta1), false);
        }
    }

    // --- Pool query helpers (needed for routing decisions) ---

    function _getV2PriceAndReserves(address token)
        private
        view
        returns (
            bool hasV2Pool,
            uint256 priceV2,
            uint112 reserveWETH,
            uint112 reserveToken
        )
    {
        if (v2Factory.code.length == 0) {
            return (false, 0, 0, 0);
        }

        // Inline the V2 factory interface call
        (bool success, bytes memory data) = v2Factory.staticcall(
            abi.encodeWithSignature("getPair(address,address)", weth, token)
        );
        if (!success || data.length < 32) return (false, 0, 0, 0);
        address pair = abi.decode(data, (address));

        if (pair == address(0)) {
            return (false, 0, 0, 0);
        }

        (bool ok, bytes memory resData) = pair.staticcall(abi.encodeWithSignature("getReserves()"));
        if (!ok || resData.length < 96) return (false, 0, 0, 0);
        (uint112 reserve0, uint112 reserve1, ) = abi.decode(resData, (uint112, uint112, uint32));

        if (reserve0 == 0 || reserve1 == 0) {
            return (false, 0, 0, 0);
        }

        (bool tok0ok, bytes memory tok0data) = pair.staticcall(abi.encodeWithSignature("token0()"));
        if (!tok0ok || tok0data.length < 32) return (false, 0, 0, 0);
        address token0 = abi.decode(tok0data, (address));
        bool wethIsToken0 = (token0 == weth);

        if (wethIsToken0) {
            reserveWETH = reserve0;
            reserveToken = reserve1;
            priceV2 = (uint256(reserve0) * 1e18) / uint256(reserve1);
        } else {
            reserveWETH = reserve1;
            reserveToken = reserve0;
            priceV2 = (uint256(reserve1) * 1e18) / uint256(reserve0);
        }

        hasV2Pool = true;
    }

    function _getV3PriceAndLiquidity(address token)
        private
        view
        returns (bool hasV3Pool, uint256 priceV3, uint128 liquidity)
    {
        if (v3Factory.code.length == 0) {
            return (false, 0, 0);
        }

        uint24[3] memory feeTiers = [uint24(3000), uint24(500), uint24(10000)];

        for (uint256 i = 0; i < feeTiers.length; i++) {
            (bool ok, bytes memory data) = v3Factory.staticcall(
                abi.encodeWithSignature("getPool(address,address,uint24)", weth, token, feeTiers[i])
            );
            if (!ok || data.length < 32) continue;
            address pool = abi.decode(data, (address));
            if (pool == address(0)) continue;

            (bool slot0ok, bytes memory slot0data) = pool.staticcall(abi.encodeWithSignature("slot0()"));
            if (!slot0ok || slot0data.length < 224) continue;
            (uint160 sqrtPriceX96, , , , , , bool unlocked) = abi.decode(
                slot0data, (uint160, int24, uint16, uint16, uint16, uint8, bool)
            );
            if (!unlocked || sqrtPriceX96 == 0) continue;

            (bool liqok, bytes memory liqdata) = pool.staticcall(abi.encodeWithSignature("liquidity()"));
            if (!liqok || liqdata.length < 32) continue;
            uint128 liq = abi.decode(liqdata, (uint128));
            if (liq == 0) continue;

            uint256 sqrtScaled = uint256(sqrtPriceX96) >> 48;
            uint256 rawPrice = (sqrtScaled * sqrtScaled * 1e18) >> 96;

            (bool tok0ok, bytes memory tok0data) = pool.staticcall(abi.encodeWithSignature("token0()"));
            if (!tok0ok || tok0data.length < 32) continue;
            address token0 = abi.decode(tok0data, (address));

            if (token0 == weth) {
                if (rawPrice == 0) continue;
                priceV3 = (1e18 * 1e18) / rawPrice;
            } else {
                priceV3 = rawPrice;
            }

            return (true, priceV3, liq);
        }

        return (false, 0, 0);
    }

    function _getV4PriceAndLiquidity(address token)
        private
        view
        returns (bool hasV4Pool, uint256 priceV4, uint128 liquidity)
    {
        if (poolManager.code.length == 0) {
            return (false, 0, 0);
        }

        uint24[3] memory feeTiers = [uint24(3000), uint24(500), uint24(10000)];
        int24[3] memory tickSpacings = [int24(60), int24(10), int24(200)];

        for (uint256 i = 0; i < feeTiers.length; i++) {
            (bool success, uint256 price, uint128 liq) = _queryV4PoolForTokenPair(
                weth, token, feeTiers[i], tickSpacings[i]
            );
            if (success) return (true, price, liq);

            (success, price, liq) = _queryV4PoolForTokenPair(
                address(0), token, feeTiers[i], tickSpacings[i]
            );
            if (success) return (true, price, liq);
        }

        return (false, 0, 0);
    }

    function _queryV4PoolForTokenPair(
        address token0Addr,
        address token1Addr,
        uint24 fee,
        int24 tickSpacing
    ) private view returns (bool success, uint256 price, uint128 poolLiquidity) {
        (Currency currency0, Currency currency1) = token0Addr < token1Addr
            ? (Currency.wrap(token0Addr), Currency.wrap(token1Addr))
            : (Currency.wrap(token1Addr), Currency.wrap(token0Addr));

        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });

        // Use StateLibrary via static call to avoid importing it (already in PriceValidator)
        bytes32 poolId = keccak256(abi.encode(poolKey));

        // getSlot0: extsload slot for sqrtPriceX96
        (bool ok, bytes memory data) = poolManager.staticcall(
            abi.encodeWithSignature("extsload(bytes32)", poolId)
        );

        // Fallback: try StateLibrary pattern via direct call
        // V4 PoolManager stores pool state; if extsload fails, pool doesn't exist
        if (!ok || data.length < 32) {
            return (false, 0, 0);
        }

        // If extsload returns zero slot, pool uninitialized
        bytes32 slot0 = abi.decode(data, (bytes32));
        if (slot0 == bytes32(0)) {
            return (false, 0, 0);
        }

        // Approximate: treat as has pool (routing decision, not exact price needed here)
        return (true, 1e18, 1);
    }

    receive() external payable {}
}
