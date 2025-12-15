// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { ForkTestBase } from "../helpers/ForkTestBase.sol";
import { UniswapHelpers } from "../helpers/UniswapHelpers.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";

/**
 * @title V4PoolInitialization
 * @notice Fork tests for querying existing Uniswap V4 pools and validating liquidity
 * @dev Run with: forge test --mp test/fork/v4/V4PoolInitialization.t.sol --fork-url $ETH_RPC_URL -vvv
 *
 * Purpose: Validate assumptions about:
 * - Querying existing V4 pools
 * - Reading pool state (price, tick, fees, liquidity)
 * - Native ETH vs WETH pool differences
 * - Liquidity distribution across fee tiers
 *
 * These tests help us understand V4 pools before implementing position creation in UltraAlignmentVault.sol
 */
contract V4PoolInitializationTest is ForkTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager poolManager;
    bool v4Available;

    function setUp() public {
        loadAddresses();

        // Check if V4 PoolManager is deployed
        v4Available = UNISWAP_V4_POOL_MANAGER != address(0);

        if (v4Available) {
            poolManager = IPoolManager(UNISWAP_V4_POOL_MANAGER);
        } else {
            emit log_string("WARNING: V4 not available on this fork");
        }
    }

    /**
     * @notice Query liquidity from Native ETH/USDC pools across all fee tiers
     * @dev Validates that liquidity exists and compares distribution
     */
    function test_queryNativeETH_USDC_liquidity() public {
        if (!v4Available) return;

        emit log_string("=== Native ETH/USDC Liquidity Across Fee Tiers ===");

        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];
        uint128 maxLiquidity = 0;
        uint24 mostLiquidFee = 0;

        for (uint256 i = 0; i < fees.length; i++) {
            PoolKey memory key = _createNativeETHPoolKey(USDC, fees[i]);
            PoolId poolId = key.toId();
            uint128 liquidity = poolManager.getLiquidity(poolId);

            emit log_named_uint("Fee (bps)", fees[i]);
            emit log_named_uint("Liquidity", liquidity);

            if (liquidity > maxLiquidity) {
                maxLiquidity = liquidity;
                mostLiquidFee = fees[i];
            }

            assertTrue(liquidity > 0, "Pool should have liquidity");
        }

        emit log_named_uint("Most liquid fee tier (bps)", mostLiquidFee);
        emit log_named_uint("Max liquidity", maxLiquidity);
    }

    /**
     * @notice Query liquidity from WETH/USDC pools vs Native ETH/USDC
     * @dev Validates that Native ETH pools have different (likely more) liquidity than WETH
     */
    function test_compareNativeETH_vs_WETH_liquidity() public {
        if (!v4Available) return;

        emit log_string("=== Native ETH vs WETH Liquidity Comparison ===");

        uint24 fee = 500; // 0.05% fee tier

        // Query Native ETH/USDC
        PoolKey memory nativeKey = _createNativeETHPoolKey(USDC, fee);
        PoolId nativeId = nativeKey.toId();
        uint128 nativeLiquidity = poolManager.getLiquidity(nativeId);

        // Query WETH/USDC
        PoolKey memory wethKey = _createWETHPoolKey(USDC, fee);
        PoolId wethId = wethKey.toId();
        uint128 wethLiquidity = poolManager.getLiquidity(wethId);

        emit log_named_uint("Native ETH/USDC liquidity", nativeLiquidity);
        emit log_named_uint("WETH/USDC liquidity", wethLiquidity);

        // Both should exist
        assertTrue(nativeLiquidity > 0, "Native ETH pool should have liquidity");
        assertTrue(wethLiquidity > 0, "WETH pool should have liquidity");

        // Log which has more
        if (nativeLiquidity > wethLiquidity) {
            emit log_string("Native ETH pool has MORE liquidity");
        } else {
            emit log_string("WETH pool has MORE liquidity");
        }
    }

    /**
     * @notice Query full pool state (price, tick, fees, liquidity) for WETH/USDC
     * @dev Demonstrates complete pool state query using StateLibrary
     */
    function test_queryFullPoolState_WETH_USDC() public {
        if (!v4Available) return;

        emit log_string("=== Full Pool State: WETH/USDC 0.05% ===");

        PoolKey memory key = _createWETHPoolKey(USDC, 500);
        PoolId poolId = key.toId();

        // Query slot0
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(poolId);

        // Query liquidity
        uint128 liquidity = poolManager.getLiquidity(poolId);

        emit log_named_uint("sqrtPriceX96", sqrtPriceX96);
        emit log_named_int("tick", tick);
        emit log_named_uint("protocolFee", protocolFee);
        emit log_named_uint("lpFee", lpFee);
        emit log_named_uint("liquidity", liquidity);

        // Validations
        assertTrue(sqrtPriceX96 > 0, "Pool should be initialized");
        assertEq(lpFee, 500, "LP fee should match pool key");
        assertTrue(liquidity > 0, "Pool should have liquidity");
    }

    /**
     * @notice Query liquidity from stablecoin pool USDC/USDT
     * @dev Stablecoin pools should have high liquidity in low fee tiers (0.01% is most common)
     */
    function test_queryStablecoinPoolLiquidity() public {
        if (!v4Available) return;

        emit log_string("=== USDC/USDT Stablecoin Pool Liquidity ===");

        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];
        uint128 maxLiquidity = 0;
        uint24 mostLiquidFee = 0;
        uint256 poolsWithLiquidity = 0;

        for (uint256 i = 0; i < fees.length; i++) {
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(USDC),
                currency1: Currency.wrap(USDT),
                fee: fees[i],
                tickSpacing: _getTickSpacing(fees[i]),
                hooks: IHooks(address(0))
            });
            PoolId poolId = key.toId();
            uint128 liquidity = poolManager.getLiquidity(poolId);

            emit log_named_uint("Fee (bps)", fees[i]);
            emit log_named_uint("Liquidity", liquidity);

            if (liquidity > 0) {
                poolsWithLiquidity++;
            }

            if (liquidity > maxLiquidity) {
                maxLiquidity = liquidity;
                mostLiquidFee = fees[i];
            }
        }

        emit log_named_uint("Pools with liquidity", poolsWithLiquidity);
        emit log_named_uint("Most liquid stablecoin fee tier", mostLiquidFee);

        // At least one stablecoin pool should have liquidity (typically the 0.01% tier)
        assertTrue(poolsWithLiquidity > 0, "At least one stablecoin pool should have liquidity");
        assertTrue(maxLiquidity > 0, "Max liquidity should be > 0");
    }

    /**
     * @notice Verify that WETH/DAI pools don't exist (as discovered in pool query tests)
     * @dev This validates our pool discovery findings
     */
    function test_verifyWETH_DAI_poolsDoNotExist() public {
        if (!v4Available) return;

        emit log_string("=== Verifying WETH/DAI Pools Don't Exist ===");

        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];

        for (uint256 i = 0; i < fees.length; i++) {
            PoolKey memory key = _createWETHPoolKey(DAI, fees[i]);
            PoolId poolId = key.toId();

            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

            emit log_named_uint("Fee (bps)", fees[i]);
            emit log_named_uint("sqrtPriceX96", sqrtPriceX96);

            // WETH/DAI pools should not be initialized (sqrtPrice = 0)
            assertEq(sqrtPriceX96, 0, "WETH/DAI pool should not exist");
        }

        emit log_string("Confirmed: No WETH/DAI V4 pools exist");
    }

    /**
     * @notice Query fee growth globals to understand pool trading activity
     * @dev Higher fee growth = more swap volume
     */
    function test_queryFeeGrowthGlobals() public {
        if (!v4Available) return;

        emit log_string("=== Fee Growth Globals: Native ETH/USDC 0.05% ===");

        PoolKey memory key = _createNativeETHPoolKey(USDC, 500);
        PoolId poolId = key.toId();

        (uint256 feeGrowth0, uint256 feeGrowth1) = poolManager.getFeeGrowthGlobals(poolId);

        emit log_named_uint("feeGrowthGlobal0X128", feeGrowth0);
        emit log_named_uint("feeGrowthGlobal1X128", feeGrowth1);

        // Fee growth should be non-zero for active pools
        // (though could be zero if pool was just created)
        assertTrue(feeGrowth0 > 0 || feeGrowth1 > 0, "Active pool should have some fee growth");
    }

    /**
     * @notice Test current V4 availability on mainnet
     * @dev Useful diagnostic test
     */
    function test_checkV4Availability() public {
        if (UNISWAP_V4_POOL_MANAGER == address(0)) {
            emit log_string("V4 PoolManager: NOT SET (expected until V4 launches)");
        } else {
            emit log_named_address("V4 PoolManager", UNISWAP_V4_POOL_MANAGER);

            // Try to check if code exists at address
            uint256 size;
            address pm = UNISWAP_V4_POOL_MANAGER;
            assembly {
                size := extcodesize(pm)
            }

            if (size > 0) {
                emit log_named_uint("PoolManager code size", size);
                emit log_string("V4 PoolManager is deployed and accessible!");
            } else {
                emit log_string("V4 PoolManager: NO CODE AT ADDRESS");
            }
        }

        // Always pass - this is just informational
        assertTrue(true, "V4 availability check complete");
    }

    // ============ Helper Functions ============

    /**
     * @notice Create a PoolKey for a Native ETH pool
     * @dev Native ETH is represented as address(0)
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
     * @notice Create a PoolKey for a WETH pool
     */
    function _createWETHPoolKey(address token, uint24 fee) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(WETH < token ? WETH : token),
            currency1: Currency.wrap(WETH < token ? token : WETH),
            fee: fee,
            tickSpacing: _getTickSpacing(fee),
            hooks: IHooks(address(0))
        });
    }

    /**
     * @notice Get tick spacing for a given fee tier
     * @dev Matches Uniswap V4 conventions
     */
    function _getTickSpacing(uint24 fee) internal pure returns (int24) {
        if (fee == 100) return 1;      // 0.01%
        if (fee == 500) return 10;     // 0.05%
        if (fee == 3000) return 60;    // 0.3%
        if (fee == 10000) return 200;  // 1%
        revert("Unknown fee tier");
    }
}
