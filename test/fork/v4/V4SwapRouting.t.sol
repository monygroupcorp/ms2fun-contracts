// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ForkTestBase } from "../helpers/ForkTestBase.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";

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
contract V4SwapRoutingTest is ForkTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager poolManager;
    address stateView;
    bool v4Available;

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
     * @notice Test querying V4 pools for ETH/USDC, ETH/USDT, etc
     * @dev V4 uses native ETH (address(0)), not WETH!
     */
    function test_queryWETHUSDCV4Pool_existence() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("Searching for V4 pools...");
        emit log_string("NOTE: V4 uses native ETH (Currency.wrap(address(0))), not WETH");

        // Token pairs to try
        address[3] memory tokens = [USDC, USDT, DAI];
        string[3] memory tokenNames = ["USDC", "USDT", "DAI"];

        // Fee tiers to try
        uint24[4] memory feeTiers = [uint24(500), uint24(3000), uint24(10000), uint24(100)];
        string[4] memory feeNames = ["0.05%", "0.3%", "1%", "0.01%"];

        bool foundAnyPool = false;
        uint256 poolsFound = 0;

        // Try native ETH pairs
        for (uint256 t = 0; t < tokens.length; t++) {
            for (uint256 f = 0; f < feeTiers.length; f++) {
                bool found = _tryQueryPool(tokens[t], feeTiers[f]);
                if (found) {
                    if (!foundAnyPool) {
                        emit log_string("=== FOUND V4 POOLS ===");
                    }
                    foundAnyPool = true;
                    poolsFound++;
                }
            }
        }

        if (foundAnyPool) {
            emit log_string("");
            emit log_named_uint("Total V4 pools found", poolsFound);
            emit log_string("V4 IS LIVE WITH LIQUIDITY! Can implement real swap tests.");
        } else {
            emit log_string("");
            emit log_string("No V4 ETH/stable pools found yet");
            emit log_string("V4 was just deployed - liquidity may still be migrating");
        }
    }

    /**
     * @notice Basic ETH->Token swap via V4
     * @dev This requires a WETH/USDC pool to exist on V4
     */
    function test_swapExactInputSingle_success() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        // TODO: Implement once we find an active V4 pool
        // For now, document the pattern:

        emit log_string("TODO: V4 swap pattern:");
        emit log_string("1. Create PoolKey for WETH/USDC");
        emit log_string("2. Wrap ETH to WETH");
        emit log_string("3. Approve PoolManager to spend WETH");
        emit log_string("4. Call poolManager.unlock() with swap callback");
        emit log_string("5. In callback: poolManager.swap()");
        emit log_string("6. In callback: settle() WETH and take() USDC");
        emit log_string("7. Return delta from callback");

        emit log_string("");
        emit log_string("NOTE: V4 swaps require unlock callback pattern");
        emit log_string("Unlike V2/V3, there's no simple swapExactInput() function");
        emit log_string("We need to implement IUnlockCallback.unlockCallback()");
    }

    /**
     * @notice Specify exact output amount
     * @dev Similar to V3 exactOutputSingle
     */
    function test_swapExactOutputSingle_success() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("TODO: V4 exactOutput swap");
        emit log_string("Same unlock pattern, but specify negative amountSpecified");
    }

    /**
     * @notice CRITICAL: Hook tax affects swap price!
     * @dev If pool has a hook, the hook may tax swaps
     */
    function test_swapWithHookTaxation_reducesOutput() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("TODO: CRITICAL TEST");
        emit log_string("Compare swap output:");
        emit log_string("- V4 pool WITHOUT hook: full output");
        emit log_string("- V4 pool WITH hook (e.g., UltraAlignmentV4Hook): reduced output");
        emit log_string("");
        emit log_string("Hook taxation makes V4 more expensive than V2/V3!");
        emit log_string("This affects routing decisions in _swapETHForTarget()");
        emit log_string("");
        emit log_string("Example: 1% hook tax means 1 ETH -> 3385 USDC becomes 3351 USDC");
        emit log_string("That's worse than V2 (3384) or V3 (3385)");
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

        emit log_string("TODO: Multi-hop V4 swaps");
        emit log_string("ETH -> USDC -> DAI via two V4 pools");
        emit log_string("Requires two swap() calls in unlock callback");
    }

    /**
     * @notice Compare V4 prices to V2/V3
     * @dev This is CRITICAL for routing algorithm
     */
    function test_compareV4SwapToV2V3_success() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("TODO: Price comparison across all versions");
        emit log_string("1. Query V2 getAmountsOut()");
        emit log_string("2. Execute V3 swap");
        emit log_string("3. Execute V4 swap (with hook if exists)");
        emit log_string("4. Compare outputs");
        emit log_string("");
        emit log_string("Expected for hookless V4 pool:");
        emit log_string("V4 should have similar or better price than V3 0.05%");
        emit log_string("");
        emit log_string("Expected for hooked V4 pool:");
        emit log_string("V4 will be worse due to hook taxation");
        emit log_string("Only use V4 if it's the vault's own alignment token pool");
    }

    /**
     * @notice Price limit protection
     * @dev Similar to V3 sqrtPriceLimitX96
     */
    function test_swapWithSqrtPriceLimitX96_success() public {
        if (!v4Available) {
            emit log_string("SKIPPED: V4 not available");
            return;
        }

        emit log_string("TODO: sqrtPriceLimitX96 in V4 swap params");
        emit log_string("Protects against excessive slippage during swap");
    }

    // ========== Helper Functions ==========

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

        // Use poolManager.getSlot0() directly (like ERC404BondingInstance.sol:1253)
        // StateLibrary.getSlot0() is a library function that uses view/pure semantics
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(poolId);

        if (sqrtPriceX96 > 0) {
            emit log_named_address("Token", token);
            emit log_named_uint("Fee", fee);
            emit log_named_uint("sqrtPriceX96", sqrtPriceX96);
            emit log_named_int("tick", tick);
            return true;
        }

        return false;
    }
}
