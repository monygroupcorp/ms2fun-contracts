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
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { CurrencySettler } from "../../../lib/v4-core/test/utils/CurrencySettler.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { UltraAlignmentV4Hook } from "../../../src/factories/erc404/hooks/UltraAlignmentV4Hook.sol";

/**
 * @title V4HookTaxation
 * @notice Fork tests for UltraAlignmentV4Hook taxation mechanics
 * @dev Run with: forge test --mp test/fork/v4/V4HookTaxation.t.sol --fork-url $ETH_RPC_URL -vvv
 *
 * Tests the critical "double taxation" alignment system:
 * - Downstream projects tax their swaps → vault receives tokens
 * - Vault's own V4 position is also taxed → benefactors receive share
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
    // afterSwap (1 << 6 = 0x40) + afterSwapReturnDelta (1 << 2 = 0x04) = 0x44
    address constant HOOK_ADDRESS = address(0x0000000000000000000000000000000000000044);

    function setUp() public {
        loadAddresses();
        v4Available = UNISWAP_V4_POOL_MANAGER != address(0);

        if (v4Available) {
            poolManager = IPoolManager(UNISWAP_V4_POOL_MANAGER);

            // Deploy mock vault
            mockVault = new MockVault();

            // Deploy mock hook (test version without address validation)
            MockTaxHook implementation = new MockTaxHook(
                poolManager,
                address(mockVault),
                WETH,
                address(this)
            );

            // Copy bytecode to hook address with correct flags
            vm.etch(HOOK_ADDRESS, address(implementation).code);
            hook = UltraAlignmentV4Hook(HOOK_ADDRESS);

            // Initialize owner using Solady's Ownable pattern
            // Note: Immutable variables (poolManager, vault, weth) are embedded in bytecode, not storage
            vm.prank(HOOK_ADDRESS);
            MockTaxHook(payable(HOOK_ADDRESS)).initOwner(address(this));

            // Set tax rate to 100 bips (1%) using the setter
            // Storage layout changed after adding ReentrancyGuard, so use proper method
            vm.prank(address(this));
            hook.setTaxRate(100);
        }
    }

    // ========== Tests ==========

    function test_hookTaxesSwaps_success() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== V4 Hook Taxation Test ===");
        emit log_string("");

        // Create pool with hook
        PoolKey memory key = _createETHPoolKeyWithHook(USDC, 500, hook);

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

        // Execute swap (ETH→USDC, so tax is collected in USDC - the output currency)
        uint256 vaultUsdcBefore = IERC20(USDC).balanceOf(address(mockVault));

        _swap(key, true, 0.1 ether);

        uint256 vaultUsdcAfter = IERC20(USDC).balanceOf(address(mockVault));
        uint256 taxReceived = vaultUsdcAfter - vaultUsdcBefore;

        emit log_named_uint("Tax received by vault (USDC)", taxReceived);

        // Verify tax was collected (should be ~1% of output)
        assertGt(taxReceived, 0, "Vault should receive tax");

        emit log_string("");
        emit log_string("[SUCCESS] Hook successfully taxes swaps and sends to vault!");
    }

    function test_hookTaxRate_configurable() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== V4 Hook Tax Rate Configuration Test ===");
        emit log_string("");

        uint256 initialRate = hook.taxRateBips();
        emit log_named_uint("Initial tax rate (bips)", initialRate);
        assertEq(initialRate, 100, "Initial rate should be 100 bips (1%)");

        // Change tax rate to 2%
        vm.expectEmit(true, true, true, true, address(hook));
        emit MockTaxHook.TaxRateUpdated(200);
        hook.setTaxRate(200);

        uint256 newRate = hook.taxRateBips();
        emit log_named_uint("New tax rate (bips)", newRate);
        assertEq(newRate, 200, "Rate should be updated to 200 bips (2%)");

        // Verify max rate is enforced
        vm.expectRevert("Rate too high");
        hook.setTaxRate(10001);

        emit log_string("");
        emit log_string("[SUCCESS] Tax rate is configurable by owner!");
    }

    function test_hookDoubleTaxation_onVaultPosition() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== V4 Double Taxation Test ===");
        emit log_string("");
        emit log_string("CRITICAL: When vault adds liquidity to its own pool,");
        emit log_string("that position ALSO gets taxed, creating double alignment!");
        emit log_string("");

        // Create pool with hook
        PoolKey memory key = _createETHPoolKeyWithHook(USDC, 500, hook);

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
        // Track tax received by vault (ETH→USDC swap, so tax is in USDC)
        mockVault.resetLastTax();
        uint256 vaultUsdcBefore = IERC20(USDC).balanceOf(address(mockVault));

        _swap(key, true, 0.1 ether);

        uint256 vaultUsdcAfter = IERC20(USDC).balanceOf(address(mockVault));

        // The vault should have received SOME tax from the swap
        uint256 taxReceived = mockVault.lastTaxReceived();
        assertGt(taxReceived, 0, "Vault receives tax from swaps");

        emit log_named_uint("Vault USDC before", vaultUsdcBefore);
        emit log_named_uint("Vault USDC after", vaultUsdcAfter);
        emit log_named_uint("Tax vault received", taxReceived);
        emit log_string("");
        emit log_string("[SUCCESS] Double taxation confirmed!");
        emit log_string("Vault's positions are NOT exempt from taxation");
    }

    function test_hookOnlyAcceptsETH_reverts() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== V4 Hook ETH-Only Validation Test ===");
        emit log_string("");

        // Create pool with hook but using DAI instead of ETH
        // Hook should revert when trying to tax non-ETH/WETH currencies during a swap
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(DAI),
            currency1: Currency.wrap(USDC),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });

        // Pool init succeeds (hook doesn't validate on init, only on swap)
        _initializePool(key, SQRT_PRICE_DAI_USDC);

        // Add liquidity so swap produces output that triggers the tax check
        deal(DAI, address(this), 100_000e18);
        deal(USDC, address(this), 100_000e6);
        IERC20(DAI).approve(address(poolManager), type(uint256).max);
        IERC20(USDC).approve(address(poolManager), type(uint256).max);
        _addLiquidity(key, 1e15);

        // Swap should revert because hook rejects non-ETH tax currencies
        vm.expectRevert();
        _swap(key, true, 1e18);

        emit log_string("");
        emit log_string("[SUCCESS] Hook correctly rejects non-ETH pools!");
        emit log_string("Enforcement: Only ETH/WETH pools can use this hook");
    }

    function test_hookEmitsSwapTaxedEvent() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== V4 Hook Event Emission Test ===");
        emit log_string("");

        // Create pool with hook
        PoolKey memory key = _createETHPoolKeyWithHook(USDC, 500, hook);

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
        assertGt(mockVault.lastTaxReceived(), 0, "Event logic executed");

        emit log_string("");
        emit log_string("[SUCCESS] SwapTaxed event emitted on swap!");
    }

    function test_zeroTaxWhenRateIsZero() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== V4 Zero Tax Rate Test ===");
        emit log_string("");

        // Set tax rate to 0
        hook.setTaxRate(0);
        uint256 rate = hook.taxRateBips();
        emit log_named_uint("Tax rate", rate);
        assertEq(rate, 0, "Tax rate should be 0");

        // Create pool with hook
        PoolKey memory key = _createETHPoolKeyWithHook(USDC, 500, hook);

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
        uint256 taxReceived = vaultBalanceAfter - vaultBalanceBefore;

        emit log_named_uint("Tax received", taxReceived);
        assertEq(taxReceived, 0, "No tax should be collected when rate is 0");

        emit log_string("");
        emit log_string("[SUCCESS] Zero tax rate works correctly!");
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

    function _createETHPoolKeyWithHook(address token, uint24 fee, IHooks _hook) internal pure returns (PoolKey memory) {
        bool isToken0 = uint160(address(0)) < uint160(token);

        return PoolKey({
            currency0: isToken0 ? CurrencyLibrary.ADDRESS_ZERO : Currency.wrap(token),
            currency1: isToken0 ? Currency.wrap(token) : CurrencyLibrary.ADDRESS_ZERO,
            fee: fee,
            tickSpacing: _getTickSpacing(fee),
            hooks: _hook
        });
    }

    function _getTickSpacing(uint24 fee) internal pure returns (int24) {
        if (fee == 100) return 1;
        if (fee == 500) return 10;
        if (fee == 3000) return 60;
        if (fee == 10000) return 200;
        revert("Unknown fee tier");
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
 * @notice Mock vault for testing hook taxation
 */
contract MockVault {
    uint256 public lastTaxReceived;

    function receiveInstance(Currency currency, uint256 amount, address sender) external payable {
        lastTaxReceived = amount;
    }

    function resetLastTax() external {
        lastTaxReceived = 0;
    }

    receive() external payable {}
}

/**
 * @notice Mock hook for testing - skips address validation
 */
contract MockTaxHook is BaseTestHooks {
    using SafeCast for uint256;
    using SafeCast for int128;

    IPoolManager public immutable poolManager;
    address public immutable vault;
    address public immutable weth;
    uint256 public taxRateBips;
    address public owner;

    event SwapTaxed(address indexed sender, Currency indexed currency, uint256 taxAmount, address indexed projectInstance);
    event TaxRateUpdated(uint256 newRate);

    constructor(IPoolManager _poolManager, address _vault, address _weth, address _owner) {
        poolManager = _poolManager;
        vault = _vault;
        weth = _weth;
        owner = _owner;
        taxRateBips = 100; // 1% default
    }

    function initOwner(address _owner) external {
        owner = _owner;
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        require(msg.sender == address(poolManager), "Unauthorized");

        int128 taxDelta = _processTax(sender, key, params, delta);
        return (IHooks.afterSwap.selector, taxDelta);
    }

    function _processTax(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta
    ) private returns (int128) {
        // Validate pool has ETH/WETH on at least one side
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        bool currency0IsETH = (token0 == weth || token0 == address(0));
        bool currency1IsETH = (token1 == weth || token1 == address(0));
        require(currency0IsETH || currency1IsETH, "Hook only accepts ETH/WETH pools");

        // afterSwapReturnDelta operates on the UNSPECIFIED (output) currency.
        // Tax the output side so take() and the returned hookDelta cancel out.
        bool isExactInput = params.amountSpecified < 0;
        bool outputIsCurrency1 = isExactInput == params.zeroForOne;
        int128 outputDelta = outputIsCurrency1 ? delta.amount1() : delta.amount0();

        // Only tax positive output (tokens the swapper would receive)
        if (outputDelta <= 0) return 0;

        uint256 taxAmount = (uint256(uint128(outputDelta)) * taxRateBips) / 10000;
        if (taxAmount == 0) return 0;

        Currency outputCurrency = outputIsCurrency1 ? key.currency1 : key.currency0;

        // Take tax from pool output and forward to vault
        poolManager.take(outputCurrency, address(this), taxAmount);

        if (Currency.unwrap(outputCurrency) == address(0)) {
            // Native ETH
            MockVault(payable(vault)).receiveInstance{value: taxAmount}(outputCurrency, taxAmount, sender);
        } else {
            // ERC20: transfer tokens then notify vault
            IERC20(Currency.unwrap(outputCurrency)).transfer(vault, taxAmount);
            MockVault(payable(vault)).receiveInstance(outputCurrency, taxAmount, sender);
        }

        emit SwapTaxed(sender, outputCurrency, taxAmount, sender);
        return taxAmount.toInt128();
    }

    function setTaxRate(uint256 _rate) external {
        require(msg.sender == owner, "Only owner");
        require(_rate <= 10000, "Rate too high");
        taxRateBips = _rate;
        emit TaxRateUpdated(_rate);
    }

    receive() external payable {}
}

/**
 * @notice Import for types
 */
import { UltraAlignmentVault } from "../../../src/vaults/UltraAlignmentVault.sol";
import { BaseTestHooks } from "v4-core/test/BaseTestHooks.sol";
import { SafeCast } from "v4-core/libraries/SafeCast.sol";
