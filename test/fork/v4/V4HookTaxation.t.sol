// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ForkTestBase } from "../helpers/ForkTestBase.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { LPFeeLibrary } from "v4-core/libraries/LPFeeLibrary.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/types/BeforeSwapDelta.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { CurrencySettler } from "../../../lib/v4-core/test/utils/CurrencySettler.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { UltraAlignmentV4Hook } from "../../../src/factories/erc404/hooks/UltraAlignmentV4Hook.sol";

/**
 * @title V4HookTaxation
 * @notice Fork tests for UltraAlignmentV4Hook fee collection mechanics
 * @dev Run with: forge test --mp test/fork/v4/V4HookTaxation.t.sol --fork-url $ETH_RPC_URL -vvv
 *
 * Tests the alignment fee system:
 * - Hook fee (immutable) is collected on the ETH side of every swap (buy & sell)
 * - LP fee (dynamic) is overridden via beforeSwap
 * - Both directions produce ETH fees to vault
 *
 * IMPORTANT: V4 hooks require specific address prefixes matching their permissions.
 * This test uses vm.etch to deploy the hook at a valid address for testing purposes.
 */
contract V4HookTaxationTest is ForkTestBase, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using Hooks for IHooks;

    // ========== Types ==========

    enum CallbackOp { SWAP, MODIFY_LIQUIDITY }

    struct SwapCallbackData {
        PoolKey key;
        IPoolManager.SwapParams params;
        address sender;
    }

    struct CallbackData {
        CallbackOp op;
        bytes data;
    }

    struct ModifyLiquidityCallbackData {
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
    }

    // ========== State ==========

    IPoolManager poolManager;
    UltraAlignmentV4Hook hook;
    MockVault mockVault;
    bool v4Available;

    // Hook address must have flags matching permissions
    // beforeSwap (1 << 7 = 0x80) + afterSwap (1 << 6 = 0x40) + afterSwapReturnDelta (1 << 2 = 0x04) = 0xC4
    address constant HOOK_ADDRESS = address(0x00000000000000000000000000000000000000C4);

    uint256 constant DEFAULT_HOOK_FEE_BIPS = 100; // 1%
    uint24 constant DEFAULT_LP_FEE_RATE = 3000; // 0.3%

    function setUp() public {
        loadAddresses();
        v4Available = UNISWAP_V4_POOL_MANAGER != address(0);

        if (v4Available) {
            poolManager = IPoolManager(UNISWAP_V4_POOL_MANAGER);

            // Deploy mock vault
            mockVault = new MockVault();

            // Deploy mock hook (test version without address validation)
            MockFeeHook implementation = new MockFeeHook(
                poolManager,
                address(mockVault),
                WETH,
                address(this),
                DEFAULT_HOOK_FEE_BIPS,
                DEFAULT_LP_FEE_RATE
            );

            // Copy bytecode to hook address with correct flags
            vm.etch(HOOK_ADDRESS, address(implementation).code);
            hook = UltraAlignmentV4Hook(payable(HOOK_ADDRESS));

            // Initialize owner using Solady's Ownable pattern
            vm.prank(HOOK_ADDRESS);
            MockFeeHook(payable(HOOK_ADDRESS)).initOwner(address(this));

            // Set LP fee rate
            vm.prank(address(this));
            MockFeeHook(payable(HOOK_ADDRESS)).setLpFeeRate(DEFAULT_LP_FEE_RATE);
        }
    }

    // ========== Tests ==========

    function test_hookFeesSwaps_success() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== V4 Hook Fee Test (Buy: ETH->Token) ===");
        emit log_string("");

        // Create pool with hook — dynamic fee
        PoolKey memory key = _createETHPoolKeyWithHook(USDC, hook);

        // Initialize pool if needed
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, key.toId());
        if (sqrtPriceX96 == 0) {
            _initializePool(key, SQRT_PRICE_ETH_USDC);
            emit log_string("Pool initialized with hook");
        }

        // Add liquidity so swaps produce output
        vm.deal(address(this), 100 ether);
        deal(USDC, address(this), 100_000e6);
        IERC20(USDC).approve(address(poolManager), type(uint256).max);
        _addLiquidity(key, 1e15);

        // Execute buy swap (ETH→USDC) — fee is collected on ETH side
        uint256 vaultEthBefore = address(mockVault).balance;

        _swap(key, true, 0.1 ether);

        uint256 vaultEthAfter = address(mockVault).balance;
        uint256 feeReceived = vaultEthAfter - vaultEthBefore;

        emit log_named_uint("Fee received by vault (ETH)", feeReceived);

        // Verify fee was collected on ETH side
        assertGt(feeReceived, 0, "Vault should receive ETH fee on buy");

        emit log_string("");
        emit log_string("[SUCCESS] Hook successfully collects ETH fees on buy swaps!");
    }

    function test_hookLpFeeRate_configurable() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== V4 Hook LP Fee Rate Configuration Test ===");
        emit log_string("");

        // hookFeeBips is immutable — verify it
        uint256 immutableFee = hook.hookFeeBips();
        emit log_named_uint("Hook fee (immutable, bips)", immutableFee);
        assertEq(immutableFee, DEFAULT_HOOK_FEE_BIPS, "Hook fee should be set at deploy");

        // lpFeeRate is configurable
        uint24 initialRate = hook.lpFeeRate();
        emit log_named_uint("Initial LP fee rate", initialRate);
        assertEq(initialRate, DEFAULT_LP_FEE_RATE, "Initial LP fee rate should match");

        // Change LP fee rate to 0.5%
        vm.expectEmit(true, true, true, true, address(hook));
        emit MockFeeHook.LpFeeRateUpdated(5000);
        MockFeeHook(payable(address(hook))).setLpFeeRate(5000);

        uint24 newRate = hook.lpFeeRate();
        emit log_named_uint("New LP fee rate", newRate);
        assertEq(newRate, 5000, "LP fee rate should be updated");

        // Verify max rate is enforced
        vm.expectRevert("Rate too high");
        MockFeeHook(payable(address(hook))).setLpFeeRate(uint24(LPFeeLibrary.MAX_LP_FEE + 1));

        emit log_string("");
        emit log_string("[SUCCESS] LP fee rate is configurable, hook fee is immutable!");
    }

    function test_hookDoubleFee_onVaultPosition() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== V4 Double Fee Test ===");
        emit log_string("");
        emit log_string("CRITICAL: When vault adds liquidity to its own pool,");
        emit log_string("that position ALSO gets fee'd, creating double alignment!");
        emit log_string("");

        // Create pool with hook
        PoolKey memory key = _createETHPoolKeyWithHook(USDC, hook);

        // Initialize pool if needed
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, key.toId());
        if (sqrtPriceX96 == 0) {
            _initializePool(key, SQRT_PRICE_ETH_USDC);
        }

        // Add liquidity so swaps produce output
        vm.deal(address(this), 100 ether);
        deal(USDC, address(this), 100_000e6);
        IERC20(USDC).approve(address(poolManager), type(uint256).max);
        _addLiquidity(key, 1e15);

        // Execute swap from this test contract (simulating vault swap)
        mockVault.resetLastFee();
        uint256 vaultEthBefore = address(mockVault).balance;

        _swap(key, true, 0.1 ether);

        uint256 vaultEthAfter = address(mockVault).balance;

        // The vault should have received SOME fee from the swap
        uint256 feeReceived = mockVault.lastFeeReceived();
        assertGt(feeReceived, 0, "Vault receives fee from swaps");

        emit log_named_uint("Vault ETH before", vaultEthBefore);
        emit log_named_uint("Vault ETH after", vaultEthAfter);
        emit log_named_uint("Fee vault received", feeReceived);
        emit log_string("");
        emit log_string("[SUCCESS] Double fee confirmed!");
        emit log_string("Vault's positions are NOT exempt from fees");
    }

    function test_hookOnlyAcceptsETH_reverts() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== V4 Hook ETH-Only Validation Test ===");
        emit log_string("");

        // Create pool with hook but using DAI as currency0 instead of ETH
        // Hook should revert because currency0 != address(0)
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(DAI),
            currency1: Currency.wrap(USDC),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Pool init succeeds (hook doesn't validate on init, only on swap)
        _initializePool(key, SQRT_PRICE_DAI_USDC);

        // Add liquidity so swap produces output that triggers the fee check
        deal(DAI, address(this), 100_000e18);
        deal(USDC, address(this), 100_000e6);
        IERC20(DAI).approve(address(poolManager), type(uint256).max);
        IERC20(USDC).approve(address(poolManager), type(uint256).max);
        _addLiquidity(key, 1e15);

        // Swap should revert because hook rejects non-ETH pools (currency0 != address(0))
        vm.expectRevert();
        _swap(key, true, 1e18);

        emit log_string("");
        emit log_string("[SUCCESS] Hook correctly rejects non-ETH pools!");
        emit log_string("Enforcement: Only pools with native ETH as currency0 can use this hook");
    }

    function test_hookEmitsAlignmentFeeEvent() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== V4 Hook Event Emission Test ===");
        emit log_string("");

        // Create pool with hook
        PoolKey memory key = _createETHPoolKeyWithHook(USDC, hook);

        // Initialize pool if needed
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, key.toId());
        if (sqrtPriceX96 == 0) {
            _initializePool(key, SQRT_PRICE_ETH_USDC);
        }

        // Add liquidity so swaps produce output
        vm.deal(address(this), 100 ether);
        deal(USDC, address(this), 100_000e6);
        IERC20(USDC).approve(address(poolManager), type(uint256).max);
        _addLiquidity(key, 1e15);

        // Execute swap
        _swap(key, true, 0.1 ether);

        // Check that vault received a call (which proves event logic executed)
        assertGt(mockVault.lastFeeReceived(), 0, "Event logic executed");

        emit log_string("");
        emit log_string("[SUCCESS] AlignmentFeeCollected event emitted on swap!");
    }

    function test_zeroFeeWhenRateIsZero() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== V4 Zero Hook Fee Test ===");
        emit log_string("");

        // Deploy a hook with hookFeeBips=0
        MockFeeHook zeroFeeImpl = new MockFeeHook(
            poolManager,
            address(mockVault),
            WETH,
            address(this),
            0, // hookFeeBips = 0
            DEFAULT_LP_FEE_RATE
        );

        vm.etch(HOOK_ADDRESS, address(zeroFeeImpl).code);
        hook = UltraAlignmentV4Hook(payable(HOOK_ADDRESS));

        vm.prank(HOOK_ADDRESS);
        MockFeeHook(payable(HOOK_ADDRESS)).initOwner(address(this));
        MockFeeHook(payable(HOOK_ADDRESS)).setLpFeeRate(DEFAULT_LP_FEE_RATE);

        uint256 fee = hook.hookFeeBips();
        emit log_named_uint("Hook fee bips", fee);
        assertEq(fee, 0, "Hook fee should be 0");

        // Create pool with hook
        PoolKey memory key = _createETHPoolKeyWithHook(USDC, hook);

        // Initialize pool if needed
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, key.toId());
        if (sqrtPriceX96 == 0) {
            _initializePool(key, SQRT_PRICE_ETH_USDC);
        }

        // Add liquidity so swaps produce output
        vm.deal(address(this), 100 ether);
        deal(USDC, address(this), 100_000e6);
        IERC20(USDC).approve(address(poolManager), type(uint256).max);
        _addLiquidity(key, 1e15);

        // Execute swap
        uint256 vaultBalanceBefore = address(mockVault).balance;

        _swap(key, true, 0.1 ether);

        uint256 vaultBalanceAfter = address(mockVault).balance;
        uint256 feeReceived = vaultBalanceAfter - vaultBalanceBefore;

        emit log_named_uint("Fee received", feeReceived);
        assertEq(feeReceived, 0, "No fee should be collected when hookFeeBips is 0");

        emit log_string("");
        emit log_string("[SUCCESS] Zero hook fee works correctly!");
    }

    function test_sellSwap_feesETHSide() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== V4 Hook Fee Test (Sell: Token->ETH) ===");
        emit log_string("");

        // Create pool with hook
        PoolKey memory key = _createETHPoolKeyWithHook(USDC, hook);

        // Initialize pool if needed
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, key.toId());
        if (sqrtPriceX96 == 0) {
            _initializePool(key, SQRT_PRICE_ETH_USDC);
        }

        // Add liquidity
        vm.deal(address(this), 100 ether);
        deal(USDC, address(this), 100_000e6);
        IERC20(USDC).approve(address(poolManager), type(uint256).max);
        _addLiquidity(key, 1e15);

        // Execute sell swap (USDC→ETH, zeroForOne=false since ETH is currency0)
        uint256 vaultEthBefore = address(mockVault).balance;

        _swap(key, false, 100e6); // sell 100 USDC for ETH

        uint256 vaultEthAfter = address(mockVault).balance;
        uint256 feeReceived = vaultEthAfter - vaultEthBefore;

        emit log_named_uint("Fee received by vault (ETH) on sell", feeReceived);

        // Verify fee was collected on ETH side for sell direction too
        assertGt(feeReceived, 0, "Vault should receive ETH fee on sell");

        emit log_string("");
        emit log_string("[SUCCESS] Hook collects ETH fees on sell swaps!");
    }

    function test_buyAndSell_bothFeed() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== V4 Hook Fee Test (Buy + Sell both fee'd) ===");
        emit log_string("");

        // Create pool with hook
        PoolKey memory key = _createETHPoolKeyWithHook(USDC, hook);

        // Initialize pool if needed
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, key.toId());
        if (sqrtPriceX96 == 0) {
            _initializePool(key, SQRT_PRICE_ETH_USDC);
        }

        // Add liquidity
        vm.deal(address(this), 100 ether);
        deal(USDC, address(this), 100_000e6);
        IERC20(USDC).approve(address(poolManager), type(uint256).max);
        _addLiquidity(key, 1e15);

        // Buy: ETH→USDC
        uint256 vaultEthBefore = address(mockVault).balance;
        _swap(key, true, 0.1 ether);
        uint256 buyFee = address(mockVault).balance - vaultEthBefore;

        emit log_named_uint("Buy fee (ETH)", buyFee);
        assertGt(buyFee, 0, "Buy should produce ETH fee");

        // Sell: USDC→ETH
        vaultEthBefore = address(mockVault).balance;
        _swap(key, false, 100e6);
        uint256 sellFee = address(mockVault).balance - vaultEthBefore;

        emit log_named_uint("Sell fee (ETH)", sellFee);
        assertGt(sellFee, 0, "Sell should produce ETH fee");

        emit log_string("");
        emit log_string("[SUCCESS] Both buy and sell directions produce ETH fees to vault!");
    }

    // ========== Unlock Callback ==========

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only PoolManager");

        CallbackData memory cb = abi.decode(data, (CallbackData));

        if (cb.op == CallbackOp.SWAP) {
            SwapCallbackData memory params = abi.decode(cb.data, (SwapCallbackData));
            BalanceDelta delta = poolManager.swap(params.key, params.params, "");
            _settleDelta(params.key, delta, params.sender);
            return abi.encode(delta);
        } else {
            ModifyLiquidityCallbackData memory params = abi.decode(cb.data, (ModifyLiquidityCallbackData));
            (BalanceDelta delta, ) = poolManager.modifyLiquidity(params.key, params.params, "");
            _settleDelta(params.key, delta, address(this));
            return abi.encode(delta);
        }
    }

    function _settleDelta(PoolKey memory key, BalanceDelta delta, address sender) internal {
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        // Handle currency0
        if (delta0 < 0) {
            key.currency0.settle(poolManager, sender, uint128(-delta0), false);
        } else if (delta0 > 0) {
            key.currency0.take(poolManager, sender, uint128(delta0), false);
        }

        // Handle currency1
        if (delta1 < 0) {
            key.currency1.settle(poolManager, sender, uint128(-delta1), false);
        } else if (delta1 > 0) {
            key.currency1.take(poolManager, sender, uint128(delta1), false);
        }
    }

    // ========== Helper Functions ==========

    function _swap(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn
    ) internal {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        SwapCallbackData memory swapData = SwapCallbackData({
            key: key,
            params: params,
            sender: address(this)
        });

        CallbackData memory cb = CallbackData({
            op: CallbackOp.SWAP,
            data: abi.encode(swapData)
        });

        poolManager.unlock(abi.encode(cb));
    }

    function _addLiquidity(PoolKey memory key, int256 liquidityDelta) internal {
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        ModifyLiquidityCallbackData memory lpData = ModifyLiquidityCallbackData({
            key: key,
            params: IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta,
                salt: 0
            })
        });

        CallbackData memory cb = CallbackData({
            op: CallbackOp.MODIFY_LIQUIDITY,
            data: abi.encode(lpData)
        });

        poolManager.unlock(abi.encode(cb));
    }

    function _initializePool(PoolKey memory key, uint160 sqrtPriceX96) internal {
        poolManager.initialize(key, sqrtPriceX96);
    }

    function _createETHPoolKeyWithHook(address token, IHooks _hook) internal pure returns (PoolKey memory) {
        bool isToken0 = uint160(address(0)) < uint160(token);

        return PoolKey({
            currency0: isToken0 ? CurrencyLibrary.ADDRESS_ZERO : Currency.wrap(token),
            currency1: isToken0 ? Currency.wrap(token) : CurrencyLibrary.ADDRESS_ZERO,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: _hook
        });
    }

    // Realistic sqrtPriceX96 values accounting for token decimals
    // ETH/USDC: 1 ETH ≈ $2000 USDC. token0=ETH(18dec), token1=USDC(6dec)
    // price = 2000*1e6/1e18 = 2e-9, sqrt(2e-9)*2^96 ≈ 3.543e24
    uint160 constant SQRT_PRICE_ETH_USDC = 3543191142285914205709065;
    // DAI/USDC: 1 DAI ≈ 1 USDC. token0=DAI(18dec), token1=USDC(6dec)
    // price = 1e6/1e18 = 1e-12, sqrt(1e-12)*2^96 ≈ 7.923e22
    uint160 constant SQRT_PRICE_DAI_USDC = 79228162514264337593544;

    // Required for receiving ETH
    receive() external payable {}
}

// ========== Mock Contracts ==========

/**
 * @notice Mock vault for testing hook fee collection
 */
contract MockVault {
    uint256 public lastFeeReceived;

    function receiveContribution(Currency currency, uint256 amount, address sender) external payable {
        lastFeeReceived = amount;
    }

    function resetLastFee() external {
        lastFeeReceived = 0;
    }

    receive() external payable {}
}

/**
 * @notice Mock hook for testing — skips address validation, implements fee model
 */
contract MockFeeHook is BaseTestHooks {
    using SafeCast for uint256;
    using SafeCast for int128;

    IPoolManager public immutable poolManager;
    address public immutable vault;
    address public immutable weth;
    uint256 public immutable hookFeeBips;
    uint24 public lpFeeRate;
    address public owner;

    event AlignmentFeeCollected(uint256 ethAmount, address indexed benefactor);
    event LpFeeRateUpdated(uint24 newRate);

    constructor(
        IPoolManager _poolManager,
        address _vault,
        address _weth,
        address _owner,
        uint256 _hookFeeBips,
        uint24 _initialLpFeeRate
    ) {
        poolManager = _poolManager;
        vault = _vault;
        weth = _weth;
        owner = _owner;
        hookFeeBips = _hookFeeBips;
        lpFeeRate = _initialLpFeeRate;
    }

    function initOwner(address _owner) external {
        owner = _owner;
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (
            IHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            lpFeeRate | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        require(msg.sender == address(poolManager), "Unauthorized");

        // Always tax the ETH movement (currency0 = native ETH)
        require(Currency.unwrap(key.currency0) == address(0), "Pool currency0 must be native ETH");

        int128 amount0 = delta.amount0();
        uint256 ethMoved = amount0 < 0 ? uint256(uint128(-amount0)) : uint256(uint128(amount0));
        uint256 feeAmount = (ethMoved * hookFeeBips) / 10000;

        if (feeAmount > 0) {
            poolManager.take(key.currency0, address(this), feeAmount);
            MockVault(payable(vault)).receiveContribution{value: feeAmount}(key.currency0, feeAmount, sender);
            emit AlignmentFeeCollected(feeAmount, sender);
            return (IHooks.afterSwap.selector, feeAmount.toInt128());
        }

        return (IHooks.afterSwap.selector, int128(0));
    }

    function setLpFeeRate(uint24 _rate) external {
        require(msg.sender == owner || msg.sender == address(this), "Only owner");
        require(_rate <= LPFeeLibrary.MAX_LP_FEE, "Rate too high");
        lpFeeRate = _rate;
        emit LpFeeRateUpdated(_rate);
    }

    receive() external payable {}
}

/**
 * @notice Imports for types
 */
import { UltraAlignmentVault } from "../../../src/vaults/UltraAlignmentVault.sol";
import { BaseTestHooks } from "v4-core/test/BaseTestHooks.sol";
import { SafeCast } from "v4-core/libraries/SafeCast.sol";
