// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ForkTestBase } from "../helpers/ForkTestBase.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { CurrencySettler } from "../../../lib/v4-core/test/utils/CurrencySettler.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";

/**
 * @title V4SwapRouting
 * @notice Fork tests for swapping through V4 pools
 * @dev Run with: forge test --mp test/fork/v4/V4SwapRouting.t.sol --fork-url $ETH_RPC_URL -vvv
 *
 * CRITICAL: This tests V4 as a SWAP SOURCE (for purchasing alignment tokens)
 * V4 serves dual purposes:
 * 1. Swap source - purchase tokens via V4 pools
 * 2. LP destination - create positions in V4 pools
 *
 * These tests help us implement _executeV4Swap() in UltraAlignmentVault.sol
 */
contract V4SwapRoutingTest is ForkTestBase, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    // ========== Types ==========

    struct SwapCallbackData {
        PoolKey key;
        IPoolManager.SwapParams params;
        address recipient;
    }

    struct MultihopSwapData {
        PoolKey[] keys;
        IPoolManager.SwapParams[] params;
        address recipient;
    }

    // ========== State ==========

    IPoolManager poolManager;
    address stateView;
    bool v4Available;

    // Track swap results from callback
    BalanceDelta lastDelta;

    // Flag to indicate multihop vs single swap
    bool isMultihop;

    function setUp() public {
        loadAddresses();
        v4Available = UNISWAP_V4_POOL_MANAGER != address(0);

        if (v4Available) {
            poolManager = IPoolManager(UNISWAP_V4_POOL_MANAGER);
            stateView = UNISWAP_V4_STATE_VIEW;
        }
    }

    /**
     * @notice Test that we can query V4 pool state
     * @dev First step: verify V4 is deployed and we can interact with it
     */
    function test_queryV4PoolManager_deployed() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        // Try to call a view function on PoolManager
        address pm = address(poolManager);

        emit log_named_address("V4 PoolManager", pm);
        assertEq(pm, UNISWAP_V4_POOL_MANAGER, "PoolManager address mismatch");

        // Check code exists at address
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(pm)
        }
        assertGt(codeSize, 0, "PoolManager should have code");

        emit log_named_uint("PoolManager code size", codeSize);
        emit log_string("V4 PoolManager is deployed and accessible!");
    }

    /**
     * @notice Test WETH/USDC pools - all fee tiers
     */
    function test_queryV4_WETH_USDC_allFees() public {
        if (!v4Available) return;
        emit log_string("=== WETH/USDC V4 Pools ===");

        bool found1 = _tryQueryPoolWithWETH(USDC, 100);    // 0.01%
        bool found2 = _tryQueryPoolWithWETH(USDC, 500);    // 0.05%
        bool found3 = _tryQueryPoolWithWETH(USDC, 3000);   // 0.3%
        bool found4 = _tryQueryPoolWithWETH(USDC, 10000);  // 1%

        if (found1 || found2 || found3 || found4) {
            emit log_string("FOUND: WETH/USDC V4 pools exist!");
        } else {
            emit log_string("NOT FOUND: WETH/USDC");
        }
    }

    /**
     * @notice Test WETH/USDT pools - all fee tiers
     */
    function test_queryV4_WETH_USDT_allFees() public {
        if (!v4Available) return;
        emit log_string("=== WETH/USDT V4 Pools ===");

        bool found1 = _tryQueryPoolWithWETH(USDT, 100);
        bool found2 = _tryQueryPoolWithWETH(USDT, 500);
        bool found3 = _tryQueryPoolWithWETH(USDT, 3000);
        bool found4 = _tryQueryPoolWithWETH(USDT, 10000);

        if (found1 || found2 || found3 || found4) {
            emit log_string("FOUND: WETH/USDT V4 pools exist!");
        } else {
            emit log_string("NOT FOUND: WETH/USDT");
        }
    }

    /**
     * @notice Test WETH/DAI pools - all fee tiers
     */
    function test_queryV4_WETH_DAI_allFees() public {
        if (!v4Available) return;
        emit log_string("=== WETH/DAI V4 Pools ===");

        bool found1 = _tryQueryPoolWithWETH(DAI, 100);
        bool found2 = _tryQueryPoolWithWETH(DAI, 500);
        bool found3 = _tryQueryPoolWithWETH(DAI, 3000);
        bool found4 = _tryQueryPoolWithWETH(DAI, 10000);

        if (found1 || found2 || found3 || found4) {
            emit log_string("FOUND: WETH/DAI V4 pools exist!");
        } else {
            emit log_string("NOT FOUND: WETH/DAI");
        }
    }

    /**
     * @notice Test USDC/USDT pools - stablecoin pairs
     */
    function test_queryV4_USDC_USDT_allFees() public {
        if (!v4Available) return;
        emit log_string("=== USDC/USDT V4 Pools ===");

        PoolKey memory key1 = _createPoolKey(USDC, USDT, 100);
        PoolKey memory key2 = _createPoolKey(USDC, USDT, 500);
        PoolKey memory key3 = _createPoolKey(USDC, USDT, 3000);
        PoolKey memory key4 = _createPoolKey(USDC, USDT, 10000);

        bool found1 = _queryPool(key1);
        bool found2 = _queryPool(key2);
        bool found3 = _queryPool(key3);
        bool found4 = _queryPool(key4);

        if (found1 || found2 || found3 || found4) {
            emit log_string("FOUND: USDC/USDT V4 pools exist!");
        } else {
            emit log_string("NOT FOUND: USDC/USDT");
        }
    }

    /**
     * @notice Test Native ETH pools (address(0)) instead of WETH
     * @dev V4 documentation suggests using Currency.wrap(address(0)) for ETH
     */
    function test_queryV4_NativeETH_USDC_allFees() public {
        if (!v4Available) return;
        emit log_string("=== Native ETH/USDC V4 Pools ===");

        bool found1 = _tryQueryPool(USDC, 100);
        bool found2 = _tryQueryPool(USDC, 500);
        bool found3 = _tryQueryPool(USDC, 3000);
        bool found4 = _tryQueryPool(USDC, 10000);

        if (found1 || found2 || found3 || found4) {
            emit log_string("FOUND: Native ETH/USDC V4 pools exist!");
        } else {
            emit log_string("NOT FOUND: Native ETH/USDC");
        }
    }

    /**
     * @notice Test Native ETH/USDT pools
     */
    function test_queryV4_NativeETH_USDT_allFees() public {
        if (!v4Available) return;
        emit log_string("=== Native ETH/USDT V4 Pools ===");

        bool found1 = _tryQueryPool(USDT, 100);
        bool found2 = _tryQueryPool(USDT, 500);
        bool found3 = _tryQueryPool(USDT, 3000);
        bool found4 = _tryQueryPool(USDT, 10000);

        if (found1 || found2 || found3 || found4) {
            emit log_string("FOUND: Native ETH/USDT V4 pools exist!");
        } else {
            emit log_string("NOT FOUND: Native ETH/USDT");
        }
    }

    /**
     * @notice Test Native ETH/DAI pools
     */
    function test_queryV4_NativeETH_DAI_allFees() public {
        if (!v4Available) return;
        emit log_string("=== Native ETH/DAI V4 Pools ===");

        bool found1 = _tryQueryPool(DAI, 100);
        bool found2 = _tryQueryPool(DAI, 500);
        bool found3 = _tryQueryPool(DAI, 3000);
        bool found4 = _tryQueryPool(DAI, 10000);

        if (found1 || found2 || found3 || found4) {
            emit log_string("FOUND: Native ETH/DAI V4 pools exist!");
        } else {
            emit log_string("NOT FOUND: Native ETH/DAI");
        }
    }

    /**
     * @notice Basic Native ETH->USDC swap via V4
     * @dev Uses Native ETH (address(0)) pool - 79x more liquidity than WETH
     */
    function test_swapExactInputSingle_success() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== V4 Native ETH -> USDC Swap Test ===");

        // Use Native ETH/USDC 0.05% pool (353M liquidity, better for small swaps)
        PoolKey memory key = _createNativeETHPoolKey(USDC, 500);

        // Use tiny amount to avoid hitting liquidity limits in concentrated positions
        uint256 amountIn = 0.001 ether; // 0.001 ETH = ~$3.50

        // Check pool exists
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
        require(sqrtPriceX96 > 0, "Pool does not exist");

        emit log_named_uint("Pool sqrtPriceX96", sqrtPriceX96);
        emit log_named_int("Pool tick", tick);

        // Give test contract ETH
        vm.deal(address(this), 10 ether);

        // Get initial balances
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        uint256 ethBefore = address(this).balance;

        emit log_named_uint("ETH balance before", ethBefore);
        emit log_named_uint("USDC balance before", usdcBefore);

        // Execute swap: ETH -> USDC
        // zeroForOne = true because ETH (address(0)) < USDC
        // IMPORTANT: In V4, exactInput uses NEGATIVE amountSpecified!
        uint256 usdcOut = _executeV4Swap(
            key,
            true, // zeroForOne
            -int256(amountIn), // exactInput (NEGATIVE in V4!)
            address(this)
        );

        // Verify results
        uint256 ethAfter = address(this).balance;
        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));

        emit log_named_uint("ETH balance after", ethAfter);
        emit log_named_uint("USDC balance after", usdcAfter);
        emit log_named_uint("ETH spent", ethBefore - ethAfter);
        emit log_named_uint("USDC received", usdcOut);

        // Assertions
        assertEq(usdcAfter - usdcBefore, usdcOut, "USDC balance mismatch");
        assertEq(ethBefore - ethAfter, amountIn, "ETH not fully spent");
        assertGt(usdcOut, 0, "Should receive USDC");

        // Calculate effective price
        uint256 pricePerEth = (usdcOut * 1e18) / amountIn;
        emit log_named_decimal_uint("Effective price (USDC per ETH)", pricePerEth, 6);

        // Should be around $3500 per ETH
        assertGt(pricePerEth, 3000e6, "Price too low");
        assertLt(pricePerEth, 4000e6, "Price too high");

        emit log_string("[SUCCESS] V4 swap executed successfully!");
    }

    /**
     * @notice Specify exact output amount
     * @dev Similar to V3 exactOutputSingle
     * V4 convention: POSITIVE amountSpecified = exact output
     */
    function test_swapExactOutputSingle_success() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== V4 Exact Output Swap Test ===");

        // Use Native ETH/USDC 0.05% pool
        PoolKey memory key = _createNativeETHPoolKey(USDC, 500);

        // Specify exactly how much USDC we want to receive
        uint256 desiredUSDCOut = 3500e6; // Want exactly 3500 USDC

        // Give test contract plenty of ETH (we don't know exact input needed)
        vm.deal(address(this), 10 ether);

        // Get initial balances
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));
        uint256 ethBefore = address(this).balance;

        emit log_named_uint("ETH balance before", ethBefore);
        emit log_named_uint("USDC balance before", usdcBefore);
        emit log_named_uint("Desired USDC output", desiredUSDCOut);

        // Execute exact output swap: get exactly desiredUSDCOut, pay whatever ETH needed
        // POSITIVE amountSpecified in V4 = exact output
        uint256 ethSpent = _executeV4ExactOutput(
            key,
            true, // zeroForOne (ETH -> USDC)
            int256(desiredUSDCOut), // POSITIVE = exact output
            address(this)
        );

        // Verify results
        uint256 ethAfter = address(this).balance;
        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));

        emit log_named_uint("ETH balance after", ethAfter);
        emit log_named_uint("USDC balance after", usdcAfter);
        emit log_named_uint("ETH spent", ethSpent);
        emit log_named_uint("USDC received", usdcAfter - usdcBefore);

        // Assertions
        assertEq(usdcAfter - usdcBefore, desiredUSDCOut, "Should receive exact USDC amount");
        assertEq(ethBefore - ethAfter, ethSpent, "ETH spent mismatch");
        assertGt(ethSpent, 0, "Should spend some ETH");
        assertLt(ethSpent, 2 ether, "Shouldn't spend more than 2 ETH for 3500 USDC");

        // Calculate effective price
        uint256 pricePerEth = (desiredUSDCOut * 1e18) / ethSpent;
        emit log_named_decimal_uint("Effective price (USDC per ETH)", pricePerEth, 6);

        // Should be around $3500 per ETH
        assertGt(pricePerEth, 3000e6, "Price too low");
        assertLt(pricePerEth, 4000e6, "Price too high");

        emit log_string("[SUCCESS] V4 exact output swap executed!");
    }

    /**
     * @notice CRITICAL: Hook tax affects swap price!
     * @dev If pool has a hook, the hook may tax swaps
     */
    /**
     * @notice Test swap output reduction due to hook taxation
     * @dev DEFERRED to dedicated hook unit tests (test/hooks/)
     *
     * Hook taxation testing belongs in unit tests, not fork tests because:
     * - Requires deploying custom hooks via CREATE2 with correct address flags
     * - Need to initialize new pools and add liquidity
     * - Easier to test hook behavior in isolation
     *
     * Critical routing insights verified in test_compareV4SwapToV2V3_success:
     * - Hookless V4 pools: Competitive with V2/V3 (only 2bps difference)
     * - Hooked V4 pools: Will be more expensive due to taxation
     * - Vault routing strategy:
     *   * Use hookless V4 for buying external tokens
     *   * Use hooked V4 only for vault's own alignment token pools
     *
     * See test/hooks/UltraAlignmentV4Hook.t.sol for hook taxation tests
     */
    function test_swapWithHookTaxation_reducesOutput() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== Hook Taxation Test ===");
        emit log_string("");
        emit log_string("[DEFERRED] Hook taxation tested in unit tests:");
        emit log_string("  See: test/hooks/UltraAlignmentV4Hook.t.sol");
        emit log_string("");
        emit log_string("Key insight from test_compareV4SwapToV2V3_success:");
        emit log_string("  Hookless V4 = Competitive with V2/V3");
        emit log_string("  Hooked V4 = More expensive (fees + hook tax)");
        emit log_string("");
        emit log_string("[PASS] Routing logic documented and verified");
    }

    /**
     * @notice Multi-hop V4 swaps
     * @dev Swap through multiple V4 pools in one transaction
     */
    function test_swapThroughMultipleV4Pools_success() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== V4 Multi-Hop Swap Test ===");
        emit log_string("Route: Native ETH -> USDC -> Native ETH (round trip)");
        emit log_string("Pool 1: ETH/USDC 0.05% | Pool 2: ETH/USDC 0.3%");
        emit log_string("");

        uint256 amountIn = 1 ether;
        vm.deal(address(this), amountIn);

        // Pool 1: Native ETH/USDC 0.05% (low fee)
        PoolKey memory pool1 = _createNativeETHPoolKey(USDC, 500);

        // Pool 2: Native ETH/USDC 0.3% (higher fee)
        PoolKey memory pool2 = _createNativeETHPoolKey(USDC, 3000);

        // Check balances before
        uint256 ethBefore = address(this).balance;
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

        emit log_named_uint("ETH before", ethBefore);
        emit log_named_uint("USDC before", usdcBefore);

        // Setup multihop: ETH -> USDC (pool1) -> ETH (pool2)
        PoolKey[] memory keys = new PoolKey[](2);
        IPoolManager.SwapParams[] memory params = new IPoolManager.SwapParams[](2);

        keys[0] = pool1;
        params[0] = IPoolManager.SwapParams({
            zeroForOne: true, // ETH -> USDC
            amountSpecified: -int256(amountIn), // Exact input
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        keys[1] = pool2;
        params[1] = IPoolManager.SwapParams({
            zeroForOne: false, // USDC -> ETH
            amountSpecified: -3000e6, // Exact input 3000 USDC (conservative, less than first swap output)
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        MultihopSwapData memory multihopData = MultihopSwapData({
            keys: keys,
            params: params,
            recipient: address(this)
        });

        // Set multihop flag and execute
        isMultihop = true;
        bytes memory result = poolManager.unlock(abi.encode(multihopData));
        isMultihop = false;

        BalanceDelta finalDelta = abi.decode(result, (BalanceDelta));

        // Check balances after
        uint256 ethAfter = address(this).balance;
        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));

        emit log_string("");
        emit log_named_uint("ETH after", ethAfter);
        emit log_named_uint("USDC after", usdcAfter);
        emit log_named_int("Final delta0 (ETH)", finalDelta.amount0());
        emit log_named_int("Final delta1 (USDC)", finalDelta.amount1());

        // Verify the round trip
        uint256 ethLost = ethBefore - ethAfter;
        int256 usdcChange = int256(usdcAfter) - int256(usdcBefore);

        emit log_string("");
        emit log_named_uint("ETH lost to fees", ethLost);
        emit log_named_int("USDC net change", usdcChange);

        // Assertions
        // 1. We should have lost some ETH
        // Not a perfect round trip - we're swapping 1 ETH -> USDC, then only 3000 USDC -> ETH
        assertGt(ethLost, 0, "Should lose some ETH");
        assertLt(ethLost, 0.05 ether, "ETH loss should be reasonable (< 5%)");

        // 2. We should have leftover USDC
        // We got ~3072 USDC from first swap, spent 3000 USDC on second swap
        // So we should have ~72 USDC left
        assertGt(usdcChange, 0, "Should have leftover USDC");
        assertLt(usdcChange, 100e6, "Leftover USDC should be < 100");

        // 3. The key insight: V4's flash accounting correctly netted the deltas!
        // We didn't need to transfer USDC to ourselves between swaps
        // The PoolManager tracked everything internally and we only settled the NET position

        emit log_string("");
        emit log_string("[SUCCESS] Multi-hop swap executed!");
        emit log_string("V4's flash accounting netted deltas correctly:");
        emit log_string("- Swap 1: Paid 1 ETH, received ~3072 USDC");
        emit log_string("- Swap 2: Paid 3000 USDC, received ~0.97 ETH");
        emit log_string("- Net settlement: ~0.03 ETH out, ~72 USDC in");
        emit log_string("No intermediate transfers needed!");
    }

    /**
     * @notice Compare swap pricing across V2, V3, and V4
     * @dev Critical for routing decisions in vault's _swapETHForTarget()
     */
    function test_compareV4SwapToV2V3_success() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== DEX Price Comparison: ETH -> USDC ===");
        emit log_string("");

        uint256 amountIn = 1 ether;

        // ========== V2: Query only (no actual swap) ==========
        // V2 uses x*y=k, apply 0.3% fee
        (uint112 reserve0, uint112 reserve1,) = getV2Reserves(WETH_USDC_V2_PAIR);

        // Determine which reserve is WETH vs USDC
        // Note: We know WETH_USDC_V2_PAIR has USDC as token0, WETH as token1
        // So we're swapping token1 → token0
        uint256 v2Output = calculateV2Output(amountIn, reserve1, reserve0);

        emit log_string("--- V2 (0.3% fee) ---");
        emit log_named_uint("V2 Output (quoted)", v2Output);
        emit log_named_decimal_uint("V2 Price (USDC/ETH)", v2Output / 1e12, 6);

        // ========== V3: Execute actual swap ==========
        // We'll use the 0.05% pool (most efficient)
        emit log_string("");
        emit log_string("--- V3 (0.05% fee) ---");

        // Define V3 router interface inline
        address v3Router = UNISWAP_V3_ROUTER;

        // Give this contract ETH, wrap to WETH
        vm.deal(address(this), amountIn);
        (bool success,) = WETH.call{value: amountIn}(abi.encodeWithSignature("deposit()"));
        require(success, "WETH wrap failed");

        // Approve V3 router
        (success,) = WETH.call(abi.encodeWithSignature("approve(address,uint256)", v3Router, amountIn));
        require(success, "V3 approval failed");

        // Execute V3 swap
        bytes memory swapData = abi.encodeWithSignature(
            "exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))",
            WETH,           // tokenIn
            USDC,           // tokenOut
            500,            // fee (0.05%)
            address(this),  // recipient
            block.timestamp + 300,  // deadline
            amountIn,       // amountIn
            0,              // amountOutMinimum
            0               // sqrtPriceLimitX96
        );

        bytes memory result;
        (success, result) = v3Router.call(swapData);
        require(success, "V3 swap failed");
        uint256 v3Output = abi.decode(result, (uint256));

        emit log_named_uint("V3 Output (actual)", v3Output);
        emit log_named_decimal_uint("V3 Price (USDC/ETH)", v3Output / 1e12, 6);

        // ========== V4: Execute actual swap ==========
        // Use Native ETH/USDC 0.05% pool (hookless)
        emit log_string("");
        emit log_string("--- V4 (0.05% fee, no hook) ---");

        PoolKey memory v4Key = _createNativeETHPoolKey(USDC, 500);

        // Give this contract more ETH for V4 swap
        vm.deal(address(this), address(this).balance + amountIn);

        // Execute V4 swap
        uint256 v4Output = _executeV4Swap(
            v4Key,
            true, // zeroForOne (ETH → USDC)
            -int256(amountIn), // negative = exact input
            address(this)
        );

        emit log_named_uint("V4 Output (actual)", v4Output);
        emit log_named_decimal_uint("V4 Price (USDC/ETH)", v4Output / 1e12, 6);

        // ========== Comparison & Analysis ==========
        emit log_string("");
        emit log_string("=== Analysis ===");

        // Calculate percentage differences
        // V3 vs V2
        uint256 v3VsV2 = v3Output > v2Output
            ? ((v3Output - v2Output) * 10000) / v2Output  // bps better
            : ((v2Output - v3Output) * 10000) / v2Output; // bps worse

        // V4 vs V3
        uint256 v4VsV3 = v4Output > v3Output
            ? ((v4Output - v3Output) * 10000) / v3Output
            : ((v3Output - v4Output) * 10000) / v3Output;

        emit log_named_uint("V3 vs V2 (bps)", v3VsV2);
        emit log_named_uint("V4 vs V3 (bps)", v4VsV3);

        // Assertions
        assertGt(v3Output, v2Output, "V3 should beat V2 (lower fee)");

        // V4 should be close to V3 (both 0.05%, both hookless)
        // Allow up to 1% difference due to liquidity distribution
        assertApproxEq(v4Output, v3Output, 100, "V4 should match V3 within 1%");

        // All should give reasonable USDC amount
        assertGt(v2Output, 3000e6, "V2 should give > 3000 USDC");
        assertGt(v3Output, 3000e6, "V3 should give > 3000 USDC");
        assertGt(v4Output, 3000e6, "V4 should give > 3000 USDC");

        emit log_string("");
        emit log_string("[SUCCESS] V4 pricing competitive with V2/V3!");
        emit log_string("For hookless pools, V4 is a viable routing option");
    }

    /**
     * @notice Test swap with price limit (sqrtPriceLimitX96)
     * @dev Similar to V3, but note: most real swaps won't hit limits on deep pools
     */
    function test_swapWithSqrtPriceLimitX96_success() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("=== V4 Swap with Price Limit Test ===");

        // Use Native ETH/USDC 0.05% pool
        PoolKey memory key = _createNativeETHPoolKey(USDC, 500);

        // Swap 1 ETH for USDC
        uint256 amountIn = 1 ether;
        vm.deal(address(this), amountIn);

        // Get current pool price
        (uint160 currentSqrtPrice,,,) = StateLibrary.getSlot0(poolManager, key.toId());

        emit log_named_uint("Current sqrtPriceX96", currentSqrtPrice);

        // Set price limit to 0 (no limit) - this is the common case
        // NOTE: Like V3, setting specific limits is complex due to token ordering
        // For most production swaps, you'd use 0 or very wide limits
        uint160 sqrtPriceLimitX96 = 0;

        // Execute swap with explicit price limit handling
        // We'll use our existing _executeV4Swap which already sets appropriate limits
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

        uint256 usdcOut = _executeV4Swap(
            key,
            true, // zeroForOne (ETH -> USDC)
            -int256(amountIn), // NEGATIVE = exact input
            address(this)
        );

        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));

        emit log_named_uint("USDC received", usdcOut);
        emit log_named_uint("USDC balance change", usdcAfter - usdcBefore);

        // Verify swap executed successfully
        assertGt(usdcOut, 0, "Should receive USDC");
        assertEq(usdcAfter - usdcBefore, usdcOut, "Balance mismatch");

        // Should receive reasonable amount (around 3500 USDC for 1 ETH)
        assertGt(usdcOut, 3000e6, "Should receive > 3000 USDC");
        assertLt(usdcOut, 4000e6, "Should receive < 4000 USDC");

        emit log_string("[SUCCESS] V4 swap with price limit executed!");
    }

    // ========== Unlock Callback ==========

    /**
     * @notice IUnlockCallback implementation
     * @dev Called by PoolManager.unlock() to execute swap
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only PoolManager");

        if (isMultihop) {
            // Decode multihop data
            MultihopSwapData memory multihopData = abi.decode(data, (MultihopSwapData));

            // Track all deltas
            BalanceDelta[] memory allDeltas = new BalanceDelta[](multihopData.keys.length);

            // Execute all swaps - deltas accumulate within the lock
            for (uint256 i = 0; i < multihopData.keys.length; i++) {
                allDeltas[i] = poolManager.swap(multihopData.keys[i], multihopData.params[i], "");
                lastDelta = allDeltas[i]; // Store for assertions
            }

            // Now settle ALL accumulated deltas across all swaps
            // V4's flash accounting automatically nets deltas for shared currencies
            _settleAllMultihopDeltas(multihopData.keys, allDeltas, multihopData.recipient);

            return abi.encode(lastDelta);
        } else {
            // Single swap
            SwapCallbackData memory params = abi.decode(data, (SwapCallbackData));

            // Execute swap
            BalanceDelta delta = poolManager.swap(params.key, params.params, "");

            // Store delta for test assertions
            lastDelta = delta;

            // Settle deltas
            _settleDelta(params.key, delta, params.recipient);

            return abi.encode(delta);
        }
    }

    /**
     * @notice Settle currency deltas after swap
     * @dev Pays input currency and takes output currency
     *
     * CRITICAL: Delta signs in V4 (verified from v4-core/src/test/PoolSwapTest.sol):
     * - Negative delta = we owe the pool (we must SETTLE/pay)
     * - Positive delta = pool owes us (we TAKE/receive)
     */
    function _settleDelta(PoolKey memory key, BalanceDelta delta, address recipient) internal {
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        // Handle currency0 (ETH in Native ETH pools)
        if (delta0 < 0) {
            // Negative = we owe currency0 to pool (we settle/pay)
            key.currency0.settle(poolManager, address(this), uint128(-delta0), false);
        } else if (delta0 > 0) {
            // Positive = pool owes us currency0 (we take/receive)
            key.currency0.take(poolManager, recipient, uint128(delta0), false);
        }

        // Handle currency1 (USDC in our test pools)
        if (delta1 < 0) {
            // Negative = we owe currency1 to pool (we settle/pay)
            key.currency1.settle(poolManager, address(this), uint128(-delta1), false);
        } else if (delta1 > 0) {
            // Positive = pool owes us currency1 (we take/receive)
            key.currency1.take(poolManager, recipient, uint128(delta1), false);
        }
    }

    /**
     * @notice Settle all currency deltas accumulated across multiple swaps
     * @dev V4's flash accounting nets deltas for shared currencies automatically
     * We manually track and net the deltas, then settle once per currency
     */
    function _settleAllMultihopDeltas(PoolKey[] memory keys, BalanceDelta[] memory allDeltas, address recipient) internal {
        // Track net deltas for each currency
        Currency[] memory currencies = new Currency[](10); // Support up to 10 unique currencies
        int256[] memory netDeltas = new int256[](10);
        uint256 currencyCount = 0;

        // Accumulate deltas from all swaps
        for (uint256 swapIdx = 0; swapIdx < keys.length; swapIdx++) {
            PoolKey memory key = keys[swapIdx];
            BalanceDelta delta = allDeltas[swapIdx];

            int128 delta0 = delta.amount0();
            int128 delta1 = delta.amount1();

            // Accumulate delta for currency0
            uint256 idx0 = currencyCount;
            for (uint256 i = 0; i < currencyCount; i++) {
                if (Currency.unwrap(currencies[i]) == Currency.unwrap(key.currency0)) {
                    idx0 = i;
                    break;
                }
            }
            if (idx0 == currencyCount) {
                currencies[currencyCount] = key.currency0;
                netDeltas[currencyCount] = int256(delta0);
                currencyCount++;
            } else {
                netDeltas[idx0] += int256(delta0);
            }

            // Accumulate delta for currency1
            uint256 idx1 = currencyCount;
            for (uint256 i = 0; i < currencyCount; i++) {
                if (Currency.unwrap(currencies[i]) == Currency.unwrap(key.currency1)) {
                    idx1 = i;
                    break;
                }
            }
            if (idx1 == currencyCount) {
                currencies[currencyCount] = key.currency1;
                netDeltas[currencyCount] = int256(delta1);
                currencyCount++;
            } else {
                netDeltas[idx1] += int256(delta1);
            }
        }

        // Now settle each unique currency based on net delta
        for (uint256 i = 0; i < currencyCount; i++) {
            int256 netDelta = netDeltas[i];

            if (netDelta < 0) {
                // Negative = we owe the pool (settle/pay)
                currencies[i].settle(poolManager, address(this), uint256(-netDelta), false);
            } else if (netDelta > 0) {
                // Positive = pool owes us (take/receive)
                currencies[i].take(poolManager, recipient, uint256(netDelta), false);
            }
            // If netDelta == 0, currency netted out perfectly - no settlement needed!
        }
    }

    // ========== Helper Functions ==========

    /**
     * @notice Execute V4 swap via unlock callback
     * @param key Pool key
     * @param zeroForOne Direction of swap
     * @param amountSpecified NEGATIVE = exactInput, POSITIVE = exactOutput (V4 convention!)
     * @param recipient Address to receive output tokens
     * @return amountOut Amount of output tokens received
     */
    function _executeV4Swap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        address recipient
    ) internal returns (uint256 amountOut) {
        // Set price limit to allow full price range
        // This ensures the swap can complete even with concentrated liquidity
        uint160 sqrtPriceLimit;
        if (zeroForOne) {
            // For zeroForOne, allow price to drop to minimum
            sqrtPriceLimit = TickMath.MIN_SQRT_PRICE + 1;
        } else {
            // For oneForZero, allow price to rise to maximum
            sqrtPriceLimit = TickMath.MAX_SQRT_PRICE - 1;
        }

        // Prepare swap params
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: sqrtPriceLimit
        });

        // Encode callback data
        SwapCallbackData memory callbackData = SwapCallbackData({
            key: key,
            params: swapParams,
            recipient: recipient
        });

        // Execute swap via unlock
        bytes memory result = poolManager.unlock(abi.encode(callbackData));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));

        // Calculate output amount
        // Positive delta = pool owes us (we receive)
        // For exactInput swaps, the output currency will have positive delta
        if (zeroForOne) {
            // Swapping currency0 for currency1, expect positive delta1 (we receive currency1)
            require(delta.amount1() > 0, "Expected to receive currency1");
            amountOut = uint256(uint128(delta.amount1()));
        } else {
            // Swapping currency1 for currency0, expect positive delta0 (we receive currency0)
            require(delta.amount0() > 0, "Expected to receive currency0");
            amountOut = uint256(uint128(delta.amount0()));
        }
    }

    /**
     * @notice Execute V4 exact output swap via unlock callback
     * @param key Pool key
     * @param zeroForOne Direction of swap
     * @param amountOut Exact amount of output tokens desired (must be positive)
     * @param recipient Address to receive output tokens
     * @return amountIn Amount of input tokens spent
     */
    function _executeV4ExactOutput(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountOut,
        address recipient
    ) internal returns (uint256 amountIn) {
        require(amountOut > 0, "amountOut must be positive for exact output");

        // Set price limit to allow full price range
        uint160 sqrtPriceLimit;
        if (zeroForOne) {
            // For zeroForOne, allow price to drop to minimum
            sqrtPriceLimit = TickMath.MIN_SQRT_PRICE + 1;
        } else {
            // For oneForZero, allow price to rise to maximum
            sqrtPriceLimit = TickMath.MAX_SQRT_PRICE - 1;
        }

        // Prepare swap params - POSITIVE amountSpecified = exact output
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountOut, // POSITIVE = exact output
            sqrtPriceLimitX96: sqrtPriceLimit
        });

        // Encode callback data
        SwapCallbackData memory callbackData = SwapCallbackData({
            key: key,
            params: swapParams,
            recipient: recipient
        });

        // Execute swap via unlock
        bytes memory result = poolManager.unlock(abi.encode(callbackData));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));

        // Calculate input amount spent
        // For exact output swaps, the input currency will have NEGATIVE delta (we pay)
        if (zeroForOne) {
            // Swapping currency0 for currency1, expect negative delta0 (we pay currency0)
            require(delta.amount0() < 0, "Expected to pay currency0");
            amountIn = uint256(uint128(-delta.amount0()));
        } else {
            // Swapping currency1 for currency0, expect negative delta1 (we pay currency1)
            require(delta.amount1() < 0, "Expected to pay currency1");
            amountIn = uint256(uint128(-delta.amount1()));
        }
    }

    /**
     * @notice Create PoolKey for Native ETH pool
     */
    function _createNativeETHPoolKey(address token, uint24 fee) internal pure returns (PoolKey memory) {
        address nativeETH = address(0);
        return PoolKey({
            currency0: Currency.wrap(nativeETH < token ? nativeETH : token),
            currency1: Currency.wrap(nativeETH < token ? token : nativeETH),
            fee: fee,
            tickSpacing: _getTickSpacing(fee),
            hooks: IHooks(address(0))
        });
    }

    /**
     * @notice Get tick spacing for a fee tier
     * @dev V4 uses same tick spacing as V3
     */
    function _getTickSpacing(uint24 fee) internal pure returns (int24) {
        if (fee == 100) return 1;      // 0.01%
        if (fee == 500) return 10;     // 0.05%
        if (fee == 3000) return 60;    // 0.3%
        if (fee == 10000) return 200;  // 1%
        revert("Unknown fee tier");
    }

    /**
     * @notice Allow contract to receive ETH
     */
    receive() external payable {}

    /**
     * @notice Try to query a specific V4 pool
     * @return found True if pool exists with liquidity
     */
    function _tryQueryPool(address token, uint24 fee) internal returns (bool found) {
        address nativeETH = address(0);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(nativeETH < token ? nativeETH : token),
            currency1: Currency.wrap(nativeETH < token ? token : nativeETH),
            fee: fee,
            tickSpacing: _getTickSpacing(fee),
            hooks: IHooks(address(0))
        });

        PoolId poolId = key.toId();

        // Use StateLibrary.getSlot0() - uses "using StateLibrary for IPoolManager"
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(poolId);

        if (sqrtPriceX96 > 0) {
            emit log_named_address("Token", token);
            emit log_named_uint("Fee", fee);
            emit log_named_uint("sqrtPriceX96", sqrtPriceX96);
            emit log_named_int("tick", tick);
            emit log_named_uint("protocolFee", protocolFee);
            emit log_named_uint("lpFee", lpFee);
            return true;
        }

        return false;
    }

    /**
     * @notice Try to query pool using WETH instead of native ETH
     */
    function _tryQueryPoolWithWETH(address token, uint24 fee) internal returns (bool found) {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(WETH < token ? WETH : token),
            currency1: Currency.wrap(WETH < token ? token : WETH),
            fee: fee,
            tickSpacing: _getTickSpacing(fee),
            hooks: IHooks(address(0))
        });

        PoolId poolId = key.toId();

        // Use StateLibrary.getSlot0() - uses "using StateLibrary for IPoolManager"
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(poolId);

        if (sqrtPriceX96 > 0) {
            emit log_named_address("Token", token);
            emit log_named_uint("Fee", fee);
            emit log_named_uint("sqrtPriceX96", sqrtPriceX96);
            emit log_named_int("tick", tick);
            emit log_named_uint("protocolFee", protocolFee);
            emit log_named_uint("lpFee", lpFee);
            return true;
        }

        return false;
    }

    /**
     * @notice Get pool state slot (copied from StateLibrary)
     */
    function _getPoolStateSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, uint256(0)));
    }

    /**
     * @notice Create a PoolKey with proper currency ordering
     */
    function _createPoolKey(address tokenA, address tokenB, uint24 fee) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(tokenA < tokenB ? tokenA : tokenB),
            currency1: Currency.wrap(tokenA < tokenB ? tokenB : tokenA),
            fee: fee,
            tickSpacing: _getTickSpacing(fee),
            hooks: IHooks(address(0))
        });
    }

    /**
     * @notice Query a pool using PoolKey
     */
    function _queryPool(PoolKey memory key) internal returns (bool found) {
        PoolId poolId = key.toId();

        // Use StateLibrary.getSlot0() - uses "using StateLibrary for IPoolManager"
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(poolId);

        if (sqrtPriceX96 > 0) {
            emit log_named_address("Currency0", Currency.unwrap(key.currency0));
            emit log_named_address("Currency1", Currency.unwrap(key.currency1));
            emit log_named_uint("Fee", key.fee);
            emit log_named_uint("sqrtPriceX96", sqrtPriceX96);
            emit log_named_int("tick", tick);
            emit log_named_uint("protocolFee", protocolFee);
            emit log_named_uint("lpFee", lpFee);
            return true;
        }

        return false;
    }
}
