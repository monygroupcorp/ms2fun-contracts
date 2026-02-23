// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IAlignmentVault} from "../../../interfaces/IAlignmentVault.sol";
import {IERC20} from "../../../shared/interfaces/IERC20.sol";

/**
 * @title UltraAlignmentV4Hook
 * @notice Uniswap v4 hook that collects alignment fees on swaps and sends them to the vault
 * @dev Fees are sent directly to vault with project instance tracking for contribution metrics.
 *      Uses beforeSwap for dynamic LP fee override and afterSwap for ETH-side fee collection.
 *      Hook fee (hookFeeBips) is immutable — set once at deploy, no governance risk.
 *      LP fee (lpFeeRate) is owner-adjustable via setLpFeeRate().
 */
contract UltraAlignmentV4Hook is IHooks, ReentrancyGuard, Ownable {
    using Hooks for IHooks;
    using SafeCast for uint256;
    using SafeCast for int128;

    IPoolManager public immutable poolManager;
    IAlignmentVault public immutable vault;
    address public immutable weth;

    /// @notice Hook fee in basis points — immutable, set at deploy (e.g., 100 = 1%)
    uint256 public immutable hookFeeBips;

    /// @notice LP fee rate — owner-configurable, overrides pool's static fee via beforeSwap
    uint24 public lpFeeRate;

    event AlignmentFeeCollected(uint256 ethAmount, address indexed benefactor);
    event LpFeeRateUpdated(uint24 newRate);

    constructor(
        IPoolManager _poolManager,
        IAlignmentVault _vault,
        address _weth,
        address _owner,
        uint256 _hookFeeBips,
        uint24 _initialLpFeeRate
    ) {
        require(address(_poolManager) != address(0), "Invalid pool manager");
        require(address(_vault) != address(0), "Invalid vault");
        require(_weth != address(0), "Invalid WETH");
        require(_owner != address(0), "Invalid owner");
        require(_hookFeeBips <= 10000, "Hook fee too high");
        require(_initialLpFeeRate <= LPFeeLibrary.MAX_LP_FEE, "LP fee too high");

        _initializeOwner(_owner);
        poolManager = _poolManager;
        vault = _vault;
        weth = _weth;
        hookFeeBips = _hookFeeBips;
        lpFeeRate = _initialLpFeeRate;

        // Validate hook permissions — beforeSwap + afterSwap with return delta
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "Unauthorized");
        _;
    }

    /**
     * @notice Dynamic LP fee override — returns owner-configurable lpFeeRate on every swap
     */
    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            lpFeeRate | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    /**
     * @notice Collect alignment fee on the ETH side of every swap
     * @dev Always taxes delta.amount0() since currency0 must be native ETH.
     *      Works for both buys (ETH→token) and sells (token→ETH).
     */
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        // Always tax the ETH movement (currency0 = native ETH)
        require(Currency.unwrap(key.currency0) == address(0), "Pool currency0 must be native ETH");

        int128 amount0 = delta.amount0();
        uint256 ethMoved = amount0 < 0 ? uint256(uint128(-amount0)) : uint256(uint128(amount0));
        uint256 feeAmount = (ethMoved * hookFeeBips) / 10000;

        if (feeAmount > 0) {
            poolManager.take(key.currency0, address(this), feeAmount);
            vault.receiveContribution{value: feeAmount}(key.currency0, feeAmount, sender);
            emit AlignmentFeeCollected(feeAmount, sender);
            return (IHooks.afterSwap.selector, feeAmount.toInt128());
        }

        return (IHooks.afterSwap.selector, int128(0));
    }

    /**
     * @notice Set LP fee rate (owner only)
     * @param _rate New LP fee rate (max LPFeeLibrary.MAX_LP_FEE = 1000000 = 100%)
     */
    function setLpFeeRate(uint24 _rate) external onlyOwner {
        require(_rate <= LPFeeLibrary.MAX_LP_FEE, "Rate too high");
        lpFeeRate = _rate;
        emit LpFeeRateUpdated(_rate);
    }

    // ============================================
    // Unused Hook Implementations (Stub Methods)
    // ============================================

    function beforeInitialize(address, PoolKey calldata, uint160)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        pure
        returns (bytes4)
    {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    /// @notice Receive ETH from poolManager.take() before forwarding to vault
    receive() external payable {}
}
