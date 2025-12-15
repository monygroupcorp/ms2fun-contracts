// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ForkTestBase
 * @notice Base contract for Uniswap fork tests with common setup and helper functions
 * @dev Loads mainnet addresses from environment variables and provides utilities for:
 *      - Dealing ETH and ERC20 tokens to test addresses
 *      - Querying V2 pair reserves for pricing
 *      - Querying V3 pool state (slot0, liquidity, ticks)
 *      - Converting V3/V4 sqrtPriceX96 to human-readable prices
 */
abstract contract ForkTestBase is Test {
    // ========== Core Tokens ==========
    address internal WETH;
    address internal USDC;
    address internal DAI;
    address internal USDT;

    // ========== Uniswap V2 ==========
    address internal UNISWAP_V2_FACTORY;
    address internal UNISWAP_V2_ROUTER;
    address internal WETH_USDC_V2_PAIR;
    address internal WETH_DAI_V2_PAIR;
    address internal WETH_USDT_V2_PAIR;

    // ========== Uniswap V3 ==========
    address internal UNISWAP_V3_FACTORY;
    address internal UNISWAP_V3_ROUTER;
    address internal UNISWAP_V3_POSITION_MANAGER;

    // V3 Pools (WETH/USDC)
    address internal WETH_USDC_V3_005;  // 0.05% fee
    address internal WETH_USDC_V3_03;   // 0.3% fee
    address internal WETH_USDC_V3_1;    // 1% fee

    // V3 Pools (WETH/DAI)
    address internal WETH_DAI_V3_005;
    address internal WETH_DAI_V3_03;

    // V3 Pools (WETH/USDT)
    address internal WETH_USDT_V3_005;
    address internal WETH_USDT_V3_03;

    // ========== Uniswap V4 ==========
    address internal UNISWAP_V4_POOL_MANAGER;
    address internal UNISWAP_V4_POSITION_MANAGER;
    address internal UNISWAP_V4_QUOTER;
    address internal UNISWAP_V4_STATE_VIEW;
    address internal UNISWAP_V4_UNIVERSAL_ROUTER;
    address internal UNISWAP_V4_PERMIT2;

    // ========== Test Addresses ==========
    address internal testAddress1;
    address internal testAddress2;
    address internal testAddress3;

    /**
     * @notice Load all addresses from environment variables
     * @dev Called in setUp() of inheriting contracts
     */
    function loadAddresses() internal {
        // Core tokens
        WETH = vm.envOr("WETH_ADDRESS", address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
        USDC = vm.envOr("USDC_ADDRESS", address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48));
        DAI = vm.envOr("DAI_ADDRESS", address(0x6B175474E89094C44Da98b954EedeAC495271d0F));
        USDT = vm.envOr("USDT_ADDRESS", address(0xdAC17F958D2ee523a2206206994597C13D831ec7));

        // V2
        UNISWAP_V2_FACTORY = vm.envOr("UNISWAP_V2_FACTORY", address(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f));
        UNISWAP_V2_ROUTER = vm.envOr("UNISWAP_V2_ROUTER", address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D));
        WETH_USDC_V2_PAIR = vm.envOr("WETH_USDC_V2_PAIR", address(0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc));
        WETH_DAI_V2_PAIR = vm.envOr("WETH_DAI_V2_PAIR", address(0xA478c2975Ab1Ea89e8196811F51A7B7Ade33eB11));
        WETH_USDT_V2_PAIR = vm.envOr("WETH_USDT_V2_PAIR", address(0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852));

        // V3
        UNISWAP_V3_FACTORY = vm.envOr("UNISWAP_V3_FACTORY", address(0x1F98431c8aD98523631AE4a59f267346ea31F984));
        UNISWAP_V3_ROUTER = vm.envOr("UNISWAP_V3_ROUTER", address(0xE592427A0AEce92De3Edee1F18E0157C05861564));
        UNISWAP_V3_POSITION_MANAGER = vm.envOr("UNISWAP_V3_POSITION_MANAGER", address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88));

        WETH_USDC_V3_005 = vm.envOr("WETH_USDC_V3_005", address(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640));
        WETH_USDC_V3_03 = vm.envOr("WETH_USDC_V3_03", address(0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8));
        WETH_USDC_V3_1 = vm.envOr("WETH_USDC_V3_1", address(0x7BeA39867e4169DBe237d55C8242a8f2fcDcc387));

        WETH_DAI_V3_005 = vm.envOr("WETH_DAI_V3_005", address(0x60594a405d53811d3BC4766596EFD80fd545A270));
        WETH_DAI_V3_03 = vm.envOr("WETH_DAI_V3_03", address(0xC2e9F25Be6257c210d7Adf0D4Cd6E3E881ba25f8));

        WETH_USDT_V3_005 = vm.envOr("WETH_USDT_V3_005", address(0x11b815efB8f581194ae79006d24E0d814B7697F6));
        WETH_USDT_V3_03 = vm.envOr("WETH_USDT_V3_03", address(0x4e68Ccd3E89f51C3074ca5072bbAC773960dFa36));

        // V4 (Ethereum Mainnet deployments)
        UNISWAP_V4_POOL_MANAGER = vm.envOr("UNISWAP_V4_POOL_MANAGER", address(0x000000000004444c5dc75cB358380D2e3dE08A90));
        UNISWAP_V4_POSITION_MANAGER = vm.envOr("UNISWAP_V4_POSITION_MANAGER", address(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e));
        UNISWAP_V4_QUOTER = vm.envOr("UNISWAP_V4_QUOTER", address(0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203));
        UNISWAP_V4_STATE_VIEW = vm.envOr("UNISWAP_V4_STATE_VIEW", address(0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227));
        UNISWAP_V4_UNIVERSAL_ROUTER = vm.envOr("UNISWAP_V4_UNIVERSAL_ROUTER", address(0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af));
        UNISWAP_V4_PERMIT2 = vm.envOr("UNISWAP_V4_PERMIT2", address(0x000000000022D473030F116dDEE9F6B43aC78BA3));

        // Test addresses
        testAddress1 = vm.envOr("TEST_ADDRESS_1", address(0x1000000000000000000000000000000000000001));
        testAddress2 = vm.envOr("TEST_ADDRESS_2", address(0x2000000000000000000000000000000000000002));
        testAddress3 = vm.envOr("TEST_ADDRESS_3", address(0x3000000000000000000000000000000000000003));
    }

    // ========== Helper Functions: Dealing Assets ==========

    /**
     * @notice Give ETH to an address
     * @param to Address to receive ETH
     * @param amount Amount of ETH in wei
     */
    function dealETH(address to, uint256 amount) internal {
        vm.deal(to, amount);
    }

    /**
     * @notice Give ERC20 tokens to an address
     * @param token Token address
     * @param to Address to receive tokens
     * @param amount Amount of tokens (in token's decimals)
     */
    function dealERC20(address token, address to, uint256 amount) internal {
        deal(token, to, amount);
    }

    // ========== Helper Functions: V2 Queries ==========

    /**
     * @notice Get reserves from a Uniswap V2 pair
     * @param pair Address of the V2 pair
     * @return reserve0 Reserve of token0
     * @return reserve1 Reserve of token1
     * @return blockTimestampLast Last block timestamp of reserves update
     */
    function getV2Reserves(address pair)
        internal
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)
    {
        (bool success, bytes memory data) = pair.staticcall(abi.encodeWithSignature("getReserves()"));
        require(success, "getReserves failed");
        (reserve0, reserve1, blockTimestampLast) = abi.decode(data, (uint112, uint112, uint32));
    }

    /**
     * @notice Calculate V2 swap output using constant product formula
     * @param amountIn Amount of input token
     * @param reserveIn Reserve of input token
     * @param reserveOut Reserve of output token
     * @return amountOut Amount of output token (accounting for 0.3% fee)
     */
    function calculateV2Output(uint256 amountIn, uint112 reserveIn, uint112 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        require(amountIn > 0, "Insufficient input amount");
        require(reserveIn > 0 && reserveOut > 0, "Insufficient liquidity");

        // Apply 0.3% fee: amountInWithFee = amountIn * 997
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 1000) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /**
     * @notice Get price of token1 in terms of token0 from V2 pair
     * @param pair Address of the V2 pair
     * @return price Price as reserve0/reserve1 (scaled by 1e18)
     */
    function getV2Price(address pair) internal view returns (uint256 price) {
        (uint112 reserve0, uint112 reserve1,) = getV2Reserves(pair);
        require(reserve0 > 0 && reserve1 > 0, "No liquidity");
        price = (uint256(reserve0) * 1e18) / uint256(reserve1);
    }

    // ========== Helper Functions: V3 Queries ==========

    /**
     * @notice Get slot0 data from a Uniswap V3 pool
     * @param pool Address of the V3 pool
     * @return sqrtPriceX96 Current sqrt(price) in Q96 format
     * @return tick Current tick
     * @return observationIndex Index of last oracle observation
     * @return observationCardinality Current maximum observations
     * @return observationCardinalityNext Next maximum observations
     * @return feeProtocol Fee protocol (4 bits for token0, 4 for token1)
     * @return unlocked Whether the pool is unlocked
     */
    function getV3Slot0(address pool)
        internal
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        (bool success, bytes memory data) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        require(success, "slot0 failed");
        (sqrtPriceX96, tick, observationIndex, observationCardinality, observationCardinalityNext, feeProtocol, unlocked) = abi.decode(data, (uint160, int24, uint16, uint16, uint16, uint8, bool));
    }

    /**
     * @notice Get liquidity from a Uniswap V3 pool
     * @param pool Address of the V3 pool
     * @return liquidity Current liquidity
     */
    function getV3Liquidity(address pool) internal view returns (uint128 liquidity) {
        (bool success, bytes memory data) = pool.staticcall(abi.encodeWithSignature("liquidity()"));
        require(success, "liquidity failed");
        liquidity = abi.decode(data, (uint128));
    }

    /**
     * @notice Convert sqrtPriceX96 to human-readable price
     * @param sqrtPriceX96 Square root of price in Q96 format
     * @return price Price scaled by 1e18 (token1/token0)
     */
    function sqrtPriceX96ToPrice(uint160 sqrtPriceX96) internal pure returns (uint256 price) {
        // Price = (sqrtPriceX96 / 2^96)^2
        // To avoid overflow: (sqrtPriceX96 >> 48)^2 / 2^96 * 1e18
        // = (sqrtPriceX96^2 >> 96) / 2^96 * 1e18
        // = (sqrtPriceX96^2) >> 192 * 1e18
        // But sqrtPriceX96^2 * 1e18 can overflow, so we divide first
        uint256 sqrtPrice = uint256(sqrtPriceX96);
        // Divide by 2^48 first to prevent overflow when squaring
        uint256 sqrtPriceScaled = sqrtPrice >> 48;
        // Now square and scale: (sqrtPrice >> 48)^2 * 1e18 >> 96
        price = (sqrtPriceScaled * sqrtPriceScaled * 1e18) >> 96;
    }

    /**
     * @notice Get price from V3 pool (token1/token0)
     * @param pool Address of the V3 pool
     * @return price Price scaled by 1e18
     */
    function getV3Price(address pool) internal view returns (uint256 price) {
        (uint160 sqrtPriceX96,,,,,,) = getV3Slot0(pool);
        price = sqrtPriceX96ToPrice(sqrtPriceX96);
    }

    // ========== Helper Functions: General Utilities ==========

    /**
     * @notice Get token balance
     * @param token ERC20 token address
     * @param account Address to check balance of
     * @return balance Token balance
     */
    function getBalance(address token, address account) internal view returns (uint256 balance) {
        balance = IERC20(token).balanceOf(account);
    }

    /**
     * @notice Approve token spending
     * @param token ERC20 token address
     * @param spender Address to approve
     * @param amount Amount to approve
     * @param from Address that owns the tokens (will be pranked)
     */
    function approveToken(address token, address spender, uint256 amount, address from) internal {
        vm.prank(from);
        IERC20(token).approve(spender, amount);
    }

    /**
     * @notice Calculate percentage difference between two values
     * @param a First value
     * @param b Second value
     * @return result Percentage difference scaled by 1e18 (e.g., 5e16 = 5%)
     */
    function percentDiff(uint256 a, uint256 b) internal pure returns (uint256 result) {
        uint256 diff = a > b ? a - b : b - a;
        uint256 avg = (a + b) / 2;
        require(avg > 0, "Cannot calculate percent diff of zero");
        result = (diff * 1e18) / avg;
    }

    /**
     * @notice Assert two values are approximately equal within tolerance
     * @param a First value
     * @param b Second value
     * @param toleranceBps Tolerance in basis points (e.g., 100 = 1%)
     * @param message Error message
     */
    function assertApproxEq(uint256 a, uint256 b, uint256 toleranceBps, string memory message) internal {
        uint256 diff = a > b ? a - b : b - a;
        uint256 maxDiff = (b * toleranceBps) / 10000;
        assertLe(diff, maxDiff, message);
    }
}
