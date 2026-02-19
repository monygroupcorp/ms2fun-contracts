// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LiquidityAmounts} from "../../../libraries/v4/LiquidityAmounts.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {CurrencySettler} from "../../../libraries/v4/CurrencySettler.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IProtocolTreasuryPOL {
    function receivePOL(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) external;
}

library LiquidityDeployer {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using FixedPointMathLib for uint256;

    struct DeployParams {
        uint256 ethReserve;         // Total ETH available (post-fees)
        uint256 tokenReserve;       // Tokens reserved for liquidity
        uint256 graduationFeeBps;
        uint256 creatorGraduationFeeBps;
        uint256 polBps;
        address protocolTreasury;
        address factoryCreator;
        address weth;
        address token;              // address(this) in instance context
        uint24 poolFee;
        int24 tickSpacing;
        IHooks v4Hook;
        IPoolManager v4PoolManager;
    }

    struct DeployResult {
        uint256 graduationFee;
        uint256 creatorGradCut;
        uint256 ethForPool;
        uint256 tokensForPool;
        uint256 polETH;
        uint256 polTokens;
        address poolManagerAddress;  // v4PoolManager address, returned as liquidityPool
        uint128 liquidity;
    }

    struct UnlockCallbackParams {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
        address sender;
    }

    /// @notice Compute fee splits and pool amounts from raw reserve values
    function computeAmounts(DeployParams memory p)
        internal pure
        returns (DeployResult memory r)
    {
        uint256 ethAvailable = p.ethReserve;

        if (p.graduationFeeBps > 0 && p.protocolTreasury != address(0)) {
            r.graduationFee = (ethAvailable * p.graduationFeeBps) / 10000;
            if (p.creatorGraduationFeeBps > 0 && p.factoryCreator != address(0)) {
                r.creatorGradCut = (ethAvailable * p.creatorGraduationFeeBps) / 10000;
                if (r.creatorGradCut > r.graduationFee) r.creatorGradCut = r.graduationFee;
            }
        }

        uint256 ethAfterGrad = ethAvailable - r.graduationFee;

        if (p.polBps > 0 && p.protocolTreasury != address(0)) {
            r.polETH = (ethAfterGrad * p.polBps) / 10000;
            r.polTokens = (p.tokenReserve * p.polBps) / 10000;
        }

        r.ethForPool = ethAfterGrad - r.polETH;
        r.tokensForPool = p.tokenReserve - r.polTokens;

        require(r.ethForPool > 0, "No ETH for pool");
        require(r.tokensForPool > 0, "No tokens for pool");
    }

    /// @notice Compute sqrtPriceX96 for a given token/ETH ratio
    function computeSqrtPrice(
        uint256 ethForPool,
        uint256 tokensForPool,
        bool token0IsThis
    ) internal pure returns (uint160 sqrtPriceX96) {
        uint256 numerator = token0IsThis ? ethForPool : tokensForPool;
        uint256 denominator = token0IsThis ? tokensForPool : ethForPool;
        uint256 priceX192 = FixedPointMathLib.fullMulDiv(numerator, 1 << 192, denominator);
        sqrtPriceX96 = uint160(FixedPointMathLib.sqrt(priceX192));
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE + 1) sqrtPriceX96 = TickMath.MIN_SQRT_PRICE + 1;
        if (sqrtPriceX96 > TickMath.MAX_SQRT_PRICE - 1) sqrtPriceX96 = TickMath.MAX_SQRT_PRICE - 1;
    }

    /// @notice Handle the V4 unlock callback — add liquidity and settle deltas
    /// @dev Called by instance.unlockCallback(); instance validates msg.sender == poolManager
    function handleUnlockCallback(
        IPoolManager poolManager,
        bytes calldata data
    ) internal returns (bytes memory) {
        UnlockCallbackParams memory params = abi.decode(data, (UnlockCallbackParams));

        PoolId poolId = params.poolKey.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(params.tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(params.tickUpper);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, params.amount0, params.amount1
        );

        IPoolManager.ModifyLiquidityParams memory modifyParams = IPoolManager.ModifyLiquidityParams({
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: keccak256(abi.encodePacked(block.timestamp, block.prevrandao))
        });

        (BalanceDelta delta,) = poolManager.modifyLiquidity(params.poolKey, modifyParams, "");

        int256 delta0 = delta.amount0();
        int256 delta1 = delta.amount1();

        if (delta0 < 0) params.poolKey.currency0.settle(poolManager, params.sender, uint256(-delta0), false);
        if (delta1 < 0) params.poolKey.currency1.settle(poolManager, params.sender, uint256(-delta1), false);
        if (delta0 > 0) params.poolKey.currency0.take(poolManager, params.sender, uint256(delta0), false);
        if (delta1 > 0) params.poolKey.currency1.take(poolManager, params.sender, uint256(delta1), false);

        return abi.encode(delta);
    }
}
