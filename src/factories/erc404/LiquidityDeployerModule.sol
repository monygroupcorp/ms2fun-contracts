// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LiquidityAmounts} from "../../libraries/v4/LiquidityAmounts.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {CurrencySettler} from "../../libraries/v4/CurrencySettler.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20} from "../../shared/interfaces/IERC20.sol";

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

/**
 * @title LiquidityDeployerModule
 * @notice Singleton contract that handles all Uniswap V4 liquidity deployment.
 *         Called externally by ERC404BondingInstance at graduation time.
 *         Owns the unlockCallback so V4 bytecode is not embedded in the instance.
 */
contract LiquidityDeployerModule is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using FixedPointMathLib for uint256;

    struct DeployParams {
        uint256 ethReserve;
        uint256 tokenReserve;
        uint256 graduationFeeBps;
        uint256 creatorGraduationFeeBps;
        uint256 polBps;
        address protocolTreasury;
        address factoryCreator;
        address weth;
        address token;        // the ERC404 token (instance address)
        address instance;     // same as token, needed for token transfers
        uint24 poolFee;
        int24 tickSpacing;
        IHooks v4Hook;
        IPoolManager v4PoolManager;
    }

    struct AmountsResult {
        uint256 graduationFee;
        uint256 creatorGradCut;
        uint256 ethForPool;
        uint256 tokensForPool;
        uint256 polETH;
        uint256 polTokens;
    }

    struct CallbackContext {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
        address instance;
        IPoolManager poolManager;
    }

    CallbackContext private _ctx;

    event LiquidityDeployed(address indexed pool, uint256 amountToken, uint256 amountETH);
    event GraduationFeePaid(address indexed treasury, uint256 amount);
    event CreatorGraduationFeePaid(address indexed factoryCreator, uint256 amount);
    event ProtocolLiquidityDeployed(address indexed treasury, uint256 tokenAmount, uint256 ethAmount);

    /**
     * @notice Deploy V4 liquidity on behalf of an ERC404BondingInstance.
     * @dev Caller must have transferred LIQUIDITY_RESERVE tokens to this contract before calling.
     *      ETH is sent as msg.value.
     * @param p Deployment parameters
     * @return liquidity Amount of liquidity added to the primary pool position
     */
    function deployLiquidity(DeployParams calldata p) external payable returns (uint128 liquidity) {
        require(msg.value == p.ethReserve, "ETH mismatch");

        AmountsResult memory r = _computeAmounts(p);

        // Determine token ordering (Currency wraps address as uint160)
        Currency currencyToken = Currency.wrap(p.token);
        Currency currencyWETH = Currency.wrap(p.weth);
        bool token0IsThis = currencyToken < currencyWETH;

        Currency currency0 = token0IsThis ? currencyToken : currencyWETH;
        Currency currency1 = token0IsThis ? currencyWETH : currencyToken;

        uint160 sqrtPriceX96 = _computeSqrtPrice(r.ethForPool, r.tokensForPool, token0IsThis);

        int24 tickLower = TickMath.minUsableTick(p.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(p.tickSpacing);

        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: p.poolFee,
            tickSpacing: p.tickSpacing,
            hooks: p.v4Hook
        });

        // Wrap ETH for the primary pool position
        IWETH(p.weth).deposit{value: r.ethForPool}();
        // Approve poolManager to pull WETH (ERC20 path)
        IWETH(p.weth).approve(address(p.v4PoolManager), r.ethForPool);

        // Initialize pool
        p.v4PoolManager.initialize(poolKey, sqrtPriceX96);

        uint256 amount0 = token0IsThis ? r.tokensForPool : r.ethForPool;
        uint256 amount1 = token0IsThis ? r.ethForPool : r.tokensForPool;

        // Store context for unlock callback
        _ctx = CallbackContext({
            poolKey: poolKey,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0: amount0,
            amount1: amount1,
            instance: p.instance,
            poolManager: p.v4PoolManager
        });

        bytes memory result = p.v4PoolManager.unlock(abi.encode(uint8(0)));

        // Clear context
        delete _ctx;

        // Decode returned liquidity
        liquidity = abi.decode(result, (uint128));

        // Send graduation fees (we hold ETH from msg.value minus what was wrapped)
        if (r.graduationFee > 0) {
            uint256 protocolCut = r.graduationFee - r.creatorGradCut;
            if (protocolCut > 0) {
                SafeTransferLib.safeTransferETH(p.protocolTreasury, protocolCut);
                emit GraduationFeePaid(p.protocolTreasury, protocolCut);
            }
            if (r.creatorGradCut > 0) {
                SafeTransferLib.safeTransferETH(p.factoryCreator, r.creatorGradCut);
                emit CreatorGraduationFeePaid(p.factoryCreator, r.creatorGradCut);
            }
        }

        // Deploy protocol-owned liquidity (POL)
        if (r.polETH > 0 && r.polTokens > 0) {
            _deployProtocolLiquidity(
                p, poolKey, tickLower, tickUpper, r.polTokens, r.polETH, token0IsThis
            );
        }

        emit LiquidityDeployed(address(p.v4PoolManager), r.tokensForPool, r.ethForPool);
    }

    /**
     * @notice V4 unlock callback — only callable by the pool manager stored in context.
     */
    function unlockCallback(bytes calldata) external returns (bytes memory) {
        CallbackContext memory ctx = _ctx;
        require(msg.sender == address(ctx.poolManager), "Not pool manager");

        PoolId poolId = ctx.poolKey.toId();
        (uint160 sqrtPriceX96,,,) = ctx.poolManager.getSlot0(poolId);
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(ctx.tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(ctx.tickUpper);

        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, ctx.amount0, ctx.amount1
        );

        IPoolManager.ModifyLiquidityParams memory modifyParams = IPoolManager.ModifyLiquidityParams({
            tickLower: ctx.tickLower,
            tickUpper: ctx.tickUpper,
            liquidityDelta: int256(uint256(liq)),
            salt: keccak256(abi.encodePacked(block.timestamp, block.prevrandao))
        });

        (BalanceDelta delta,) = ctx.poolManager.modifyLiquidity(ctx.poolKey, modifyParams, "");

        int256 delta0 = delta.amount0();
        int256 delta1 = delta.amount1();

        // Settle debts (negative delta = we owe tokens)
        if (delta0 < 0) ctx.poolKey.currency0.settle(ctx.poolManager, ctx.instance, uint256(-delta0), false);
        if (delta1 < 0) ctx.poolKey.currency1.settle(ctx.poolManager, ctx.instance, uint256(-delta1), false);
        // Take credits (positive delta = pool owes us)
        if (delta0 > 0) ctx.poolKey.currency0.take(ctx.poolManager, ctx.instance, uint256(delta0), false);
        if (delta1 > 0) ctx.poolKey.currency1.take(ctx.poolManager, ctx.instance, uint256(delta1), false);

        return abi.encode(liq);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    function _computeAmounts(DeployParams calldata p) internal pure returns (AmountsResult memory r) {
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

    function _computeSqrtPrice(
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

    function _deployProtocolLiquidity(
        DeployParams calldata p,
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 polTokenAmount,
        uint256 polETHAmount,
        bool token0IsThis
    ) internal {
        // Wrap POL ETH to WETH
        IWETH(p.weth).deposit{value: polETHAmount}();

        // Transfer WETH to treasury
        IWETH(p.weth).transfer(p.protocolTreasury, polETHAmount);

        // Transfer project tokens to treasury
        // (module holds polTokenAmount from the transfer done by instance before calling deployLiquidity)
        IERC20(p.token).transfer(p.protocolTreasury, polTokenAmount);

        // Determine amounts in currency order
        uint256 polAmount0 = token0IsThis ? polTokenAmount : polETHAmount;
        uint256 polAmount1 = token0IsThis ? polETHAmount : polTokenAmount;

        // Treasury deploys its own V4 position
        IProtocolTreasuryPOL(p.protocolTreasury).receivePOL(
            poolKey, tickLower, tickUpper, polAmount0, polAmount1
        );

        emit ProtocolLiquidityDeployed(p.protocolTreasury, polTokenAmount, polETHAmount);
    }

    /// @notice Accept ETH (needed for WETH deposits returning change, etc.)
    receive() external payable {}
}
