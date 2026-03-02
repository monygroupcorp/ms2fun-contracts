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
import {IAlignmentVault} from "../../interfaces/IAlignmentVault.sol";
import {ILiquidityDeployerModule} from "../../interfaces/ILiquidityDeployerModule.sol";

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/**
 * @title LiquidityDeployerModule
 * @notice Singleton contract that handles all Uniswap V4 liquidity deployment.
 *         Called externally by ERC404BondingInstance at graduation time.
 *         Owns the unlockCallback so V4 bytecode is not embedded in the instance.
 *         Pool fee and tick spacing are fixed at construction time.
 */
contract LiquidityDeployerModule is IUnlockCallback, ILiquidityDeployerModule {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using FixedPointMathLib for uint256;

    address public immutable weth;
    IPoolManager public immutable v4PoolManager;
    uint24 public immutable poolFee;
    int24 public immutable tickSpacing;

    constructor(address _v4PoolManager, address _weth, uint24 _poolFee, int24 _tickSpacing) {
        v4PoolManager = IPoolManager(_v4PoolManager);
        weth = _weth;
        poolFee = _poolFee;
        tickSpacing = _tickSpacing;
    }

    struct AmountsResult {
        uint256 protocolFee;  // 1% of raise → protocol treasury
        uint256 vaultCut;     // 19% of raise → alignment vault
        uint256 ethForPool;   // 80% of raise → LP
        uint256 tokensForPool;
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

    struct PoolSetupResult {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        bool token0IsThis;
        uint128 liquidity;
    }

    CallbackContext private _ctx;

    event LiquidityDeployed(address indexed pool, uint256 amountToken, uint256 amountETH);
    event GraduationFeePaid(address indexed treasury, uint256 amount);
    event GraduationVaultContribution(address indexed vault, uint256 amount);

    /**
     * @notice Deploy V4 liquidity on behalf of an ERC404BondingInstance.
     * @dev Caller must have transferred LIQUIDITY_RESERVE tokens to this contract before calling.
     *      ETH is sent as msg.value.
     * @param p Deployment parameters
     */
    function deployLiquidity(DeployParams calldata p) external payable override {
        require(msg.value == p.ethReserve, "ETH mismatch");
        AmountsResult memory r = _computeAmounts(p);
        _setupPoolAndUnlock(p, r);
        _postUnlock(p, r);
    }

    /// @dev Sets up pool, stores callback context, performs unlock, clears context, returns liquidity.
    function _setupPoolAndUnlock(
        ILiquidityDeployerModule.DeployParams calldata p,
        AmountsResult memory r
    ) private returns (PoolSetupResult memory setup) {
        Currency currencyToken = Currency.wrap(p.token);
        Currency currencyWETH  = Currency.wrap(weth);
        setup.token0IsThis = currencyToken < currencyWETH;

        Currency currency0 = setup.token0IsThis ? currencyToken : currencyWETH;
        Currency currency1 = setup.token0IsThis ? currencyWETH  : currencyToken;

        uint160 sqrtPriceX96 = _computeSqrtPrice(r.ethForPool, r.tokensForPool, setup.token0IsThis);

        setup.tickLower = TickMath.minUsableTick(tickSpacing);
        setup.tickUpper = TickMath.maxUsableTick(tickSpacing);

        setup.poolKey = PoolKey({
            currency0:   currency0,
            currency1:   currency1,
            fee:         poolFee,
            tickSpacing: tickSpacing,
            hooks:       IHooks(address(0))
        });

        // Wrap ETH and approve pool manager
        IWETH(weth).deposit{value: r.ethForPool}();
        IWETH(weth).approve(address(v4PoolManager), r.ethForPool);

        // Initialize pool
        v4PoolManager.initialize(setup.poolKey, sqrtPriceX96);

        uint256 amount0 = setup.token0IsThis ? r.tokensForPool : r.ethForPool;
        uint256 amount1 = setup.token0IsThis ? r.ethForPool   : r.tokensForPool;

        _ctx = CallbackContext({
            poolKey:     setup.poolKey,
            tickLower:   setup.tickLower,
            tickUpper:   setup.tickUpper,
            amount0:     amount0,
            amount1:     amount1,
            instance:    p.instance,
            poolManager: v4PoolManager
        });

        bytes memory result = v4PoolManager.unlock(abi.encode(uint8(0)));
        delete _ctx;

        setup.liquidity = abi.decode(result, (uint128));
    }

    /// @dev Dispatches graduation fees, emits final event.
    function _postUnlock(
        ILiquidityDeployerModule.DeployParams calldata p,
        AmountsResult memory r
    ) private {
        // 1% → protocol treasury
        if (r.protocolFee > 0 && p.protocolTreasury != address(0)) {
            SafeTransferLib.safeTransferETH(p.protocolTreasury, r.protocolFee);
            emit GraduationFeePaid(p.protocolTreasury, r.protocolFee);
        }
        // 19% → alignment vault
        if (r.vaultCut > 0 && p.vault != address(0)) {
            IAlignmentVault(payable(p.vault)).receiveContribution{value: r.vaultCut}(
                Currency.wrap(address(0)), r.vaultCut, p.instance
            );
            emit GraduationVaultContribution(p.vault, r.vaultCut);
        }

        emit LiquidityDeployed(address(v4PoolManager), r.tokensForPool, r.ethForPool);
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

    function _computeAmounts(ILiquidityDeployerModule.DeployParams calldata p) internal pure returns (AmountsResult memory r) {
        uint256 ethAvailable = p.ethReserve;

        // Fixed 1/19/80 split: 1% protocol, 19% vault, 80% LP
        r.protocolFee = ethAvailable / 100;
        r.vaultCut    = (ethAvailable * 19) / 100;
        r.ethForPool  = ethAvailable - r.protocolFee - r.vaultCut;
        r.tokensForPool = p.tokenReserve;

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

    /// @notice Accept ETH (needed for WETH deposits returning change, etc.)
    receive() external payable {}
}
