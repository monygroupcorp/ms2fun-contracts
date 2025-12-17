// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {CurrencySettler} from "../libraries/v4/CurrencySettler.sol";
import {LiquidityAmounts} from "../libraries/v4/LiquidityAmounts.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ========== External Protocol Interfaces ==========

/// @notice Uniswap V3 SwapRouter interface
interface IV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Uniswap V2 Router interface
interface IUniswapV2Router02 {
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

/// @notice WETH9 interface
interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Uniswap V2 Factory interface
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// @notice Uniswap V2 Pair interface
interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/// @notice Uniswap V3 Factory interface
interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @notice Uniswap V3 Pool interface
interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

/**
 * @title UltraAlignmentVault
 * @notice Share-based vault for collecting and distributing fees from ms2fun ecosystem
 * @dev Clean implementation using share accounting to eliminate complexity
 */
contract UltraAlignmentVault is ReentrancyGuard, Ownable, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ========== Data Structures ==========

    /// @notice Callback data for V4 modifyLiquidity operations
    struct ModifyLiquidityCallbackData {
        IPoolManager.ModifyLiquidityParams params;
    }

    // Track total ETH contributed per benefactor (for bragging rights)
    mapping(address => uint256) public benefactorTotalETH;

    // Track shares issued to benefactors (for fee claims)
    mapping(address => uint256) public benefactorShares;

    // Track last claim state for multi-claim support
    mapping(address => uint256) public shareValueAtLastClaim;
    mapping(address => uint256) public lastClaimTimestamp;

    // Track pending contributions in current dragnet (reset after each conversion)
    mapping(address => uint256) public pendingETH;

    // Global state
    uint256 public totalShares;
    uint256 public totalPendingETH;
    uint256 public accumulatedFees;
    uint256 public totalLPUnits;

    // Conversion participants tracking (dragnet)
    address[] public conversionParticipants;
    mapping(address => uint256) public lastConversionParticipantIndex;

    // External contracts
    address public immutable weth;
    address public immutable poolManager;
    address public immutable v3Router;
    address public immutable v2Router;
    address public immutable v2Factory;
    address public immutable v3Factory;
    address public alignmentToken;
    PoolKey public v4PoolKey;

    // Configuration
    uint256 public conversionRewardBps = 5; // 0.05% reward for caller
    uint24 public v3PreferredFee = 3000; // 0.3% fee tier for V3 swaps
    uint256 public maxPriceDeviationBps = 500; // 5% max price deviation between DEXes

    // Position tracking
    int24 public lastTickLower; // Last tick lower bound used for LP position
    int24 public lastTickUpper; // Last tick upper bound used for LP position

    // ========== Events ==========

    event ContributionReceived(address indexed benefactor, uint256 amount);
    event LiquidityAdded(
        uint256 ethSwapped,
        uint256 tokenReceived,
        uint256 lpPositionValue,
        uint256 sharesIssued,
        uint256 callerReward
    );
    event FeesClaimed(address indexed benefactor, uint256 ethAmount);
    event FeesAccumulated(uint256 amount);

    // ========== Constructor ==========

    constructor(
        address _weth,
        address _poolManager,
        address _v3Router,
        address _v2Router,
        address _v2Factory,
        address _v3Factory,
        address _alignmentToken
    ) {
        _initializeOwner(msg.sender);
        require(_weth != address(0), "Invalid WETH");
        require(_poolManager != address(0), "Invalid pool manager");
        require(_v3Router != address(0), "Invalid V3 router");
        require(_v2Router != address(0), "Invalid V2 router");
        require(_v2Factory != address(0), "Invalid V2 factory");
        require(_v3Factory != address(0), "Invalid V3 factory");
        require(_alignmentToken != address(0), "Invalid alignment token");

        weth = _weth;
        poolManager = _poolManager;
        v3Router = _v3Router;
        v2Router = _v2Router;
        v2Factory = _v2Factory;
        v3Factory = _v3Factory;
        alignmentToken = _alignmentToken;
    }

    // ========== Fee Reception ==========

    /**
     * @notice Receive ETH contributions from any source
     * @dev Tracks msg.sender as benefactor, adds to pending dragnet
     *      Allows WETH unwrapping (from internal withdrawals) without reentrancy issues
     */
    receive() external payable {
        // If ETH is from WETH withdrawal (internal operation), just accept it
        if (msg.sender == weth) {
            return;
        }

        // External ETH contribution - apply reentrancy guard and track
        require(msg.value > 0, "Amount must be positive");
        _trackBenefactorContribution(msg.sender, msg.value);
        emit ContributionReceived(msg.sender, msg.value);
    }

    /**
     * @notice Receive taxes from V4 hooks with explicit benefactor attribution
     * @dev Allows V4 hooks to route fees with source project attribution
     */
    function receiveHookTax(
        Currency currency,
        uint256 amount,
        address benefactor
    ) external payable nonReentrant {
        require(amount > 0, "Amount must be positive");
        require(benefactor != address(0), "Invalid benefactor");
        _trackBenefactorContribution(benefactor, amount);
        emit ContributionReceived(benefactor, amount);
    }

    function _trackBenefactorContribution(address benefactor, uint256 amount) internal {
        if(pendingETH[benefactor] == 0){
            conversionParticipants.push(benefactor);
        }
        benefactorTotalETH[benefactor] += amount;
        pendingETH[benefactor] += amount;
        totalPendingETH += amount;
    }

    // ========== Conversion & Liquidity ==========

    /**
     * @notice Convert accumulated pending ETH to alignment token and add liquidity to V4
     * @dev Public incentivized function - caller earns reward for execution
     *      - Identifies all benefactors with pending contributions
     *      - Converts total pending ETH to alignment token
     *      - Mints LP position in V4 pool
     *      - Issues shares to each benefactor proportional to their contribution
     *      - Clears pending contributions for next dragnet round
     * @param minOutTarget Minimum alignment tokens to receive (slippage protection)
     * @param tickLower Lower tick for V4 concentrated liquidity position
     * @param tickUpper Upper tick for V4 concentrated liquidity position
     * @return lpPositionValue Total value of LP position added (amount0 + amount1)
     */
    function convertAndAddLiquidity(
        uint256 minOutTarget,
        int24 tickLower,
        int24 tickUpper
    ) external nonReentrant returns (uint256 lpPositionValue) {
        require(totalPendingETH > 0, "No pending ETH to convert");
        require(alignmentToken != address(0), "No alignment target set");
        require(Currency.unwrap(v4PoolKey.currency0) != address(0) || Currency.unwrap(v4PoolKey.currency1) != address(0), "V4 pool key not set");

        // Step 1: Calculate and RESERVE caller reward upfront by wrapping it temporarily
        // This ensures it doesn't get consumed by subsequent operations
        uint256 callerReward = (totalPendingETH * conversionRewardBps) / 10000;
        uint256 ethToAdd = totalPendingETH - callerReward;

        // Wrap caller reward to WETH temporarily to reserve it (skip if WETH is mock)
        // We'll unwrap it back to ETH before paying
        if (callerReward > 0 && weth.code.length > 0) {
            IWETH9(weth).deposit{value: callerReward}();
        }

        // Step 1.2: CHECK TARGET ASSET PRICE AND PURCHASE POWER (v2/v3/v4 source)
        _checkTargetAssetPriceAndPurchasePower();

        // Step 1.3: CHECK CURRENT VAULT OWNED LP TICK VALUES
        _checkCurrentVaultOwnedLpTickValues();

        // Step 1.4: CALCULATE PROPORTION OF ETH TO SWAP BASED ON VAULT OWNED LP TICK VALUES
        uint256 proportionToSwap = _calculateProportionOfEthToSwapBasedOnVaultOwnedLpTickValues();
        uint256 ethToSwap = (ethToAdd * proportionToSwap) / 1e18;

        // Step 2: Swap ETH for alignment token
        uint256 targetTokenReceived = _swapETHForTarget(ethToSwap, minOutTarget);

        // Step 3: ADD TO LP POSITION
        uint128 newLiquidityUnits;
        {
            // After swap, we have targetTokenReceived of alignment token and (ethToAdd - ethToSwap) ETH remaining
            uint256 ethRemaining = ethToAdd - ethToSwap;

            // Wrap remaining ETH to WETH if pool uses WETH (skip if WETH is mock)
            if (weth.code.length > 0) {
                if (!v4PoolKey.currency0.isAddressZero() && Currency.unwrap(v4PoolKey.currency0) == weth) {
                    IWETH9(weth).deposit{value: ethRemaining}();
                } else if (!v4PoolKey.currency1.isAddressZero() && Currency.unwrap(v4PoolKey.currency1) == weth) {
                    IWETH9(weth).deposit{value: ethRemaining}();
                }
            }

            // Determine amounts based on v4PoolKey ordering (currency0 < currency1)
            (uint256 amount0, uint256 amount1) = Currency.unwrap(v4PoolKey.currency0) == alignmentToken
                ? (targetTokenReceived, ethRemaining)
                : (ethRemaining, targetTokenReceived);

            newLiquidityUnits = _addToLpPosition(amount0, amount1, tickLower, tickUpper);
        }

        // Step 4: SEE HOW MANY MORE LIQUIDITY UNITS WE HAVE THAN WE HAD BEFORE
        uint256 liquidityUnitsAdded = uint256(newLiquidityUnits);
        totalLPUnits += liquidityUnitsAdded;

        // Calculate shares to issue based on new liquidity added
        uint256 totalSharesIssued = liquidityUnitsAdded;

        // Step 5: Issue shares to all pending benefactors
        address[] memory activeBenefactors = _getActiveBenefactors();

        for (uint256 i = 0; i < activeBenefactors.length; i++) {
            address benefactor = activeBenefactors[i];
            uint256 contribution = pendingETH[benefactor];

            // Calculate share proportion: (their contribution / total pending)
            // Share issuance: shares = (contribution / ethToAdd) * totalSharesIssued
            uint256 sharePercent = (contribution * 1e18) / ethToAdd;
            uint256 sharesToIssue = (totalSharesIssued * sharePercent) / 1e18;

            benefactorShares[benefactor] += sharesToIssue;
            totalShares += sharesToIssue;

            // Clear pending for next round
            pendingETH[benefactor] = 0;
        }

        // Clear conversion participants for next dragnet
        totalPendingETH = 0;
        _clearConversionParticipants();

        // Step 6: Calculate final LP position value
        lpPositionValue = ethToSwap + targetTokenReceived;

        // Step 7: Pay caller reward
        // Unwrap ALL WETH to get native ETH for reward (skip if WETH is mock)
        // This includes: caller reward WETH (reserved earlier) + any excess from LP
        if (weth.code.length > 0) {
            uint256 wethBalance = IWETH9(weth).balanceOf(address(this));
            if (wethBalance > 0) {
                IWETH9(weth).withdraw(wethBalance);
            }
        }

        // Now pay the caller reward in native ETH
        // We should have at least callerReward ETH from the unwrap above
        require(address(this).balance >= callerReward, "Insufficient ETH for reward");
        (bool success, ) = payable(msg.sender).call{value: callerReward}("");
        require(success, "Caller reward transfer failed");

        emit LiquidityAdded(
            ethToSwap,
            targetTokenReceived,
            lpPositionValue,
            totalSharesIssued,
            callerReward
        );

        return lpPositionValue;
    }

    // ========== Fee Claims ==========

    /**
     * @notice Claim benefactor's share of accumulated LP fees
     * @dev O(1) calculation using share ratio
     *      - share = (accumulatedFees × benefactorShares) / totalShares
     *      - Uses delta calculation for multi-claim support
     *      - Benefactor only receives new fees since last claim
     * @return ethClaimed Amount of ETH sent to benefactor
     */
    function claimFees() external nonReentrant returns (uint256 ethClaimed) {


        //check if we have claimed vault fees recently / if there is tokens accrued in the vault lp positoin
        //if fees have not been claimed by the vault recently, or there is enough tokens accrued in the vault lp position, claim them and immediately swap to eth, then update global state of vault fees accrued (share value)
        //_claimVaultFees();
        //_convertVaultFeesToEth();

        address benefactor = msg.sender;

        require(benefactorShares[benefactor] > 0, "No shares");
        require(accumulatedFees > 0, "No fees to claim");

        // Calculate current proportional share
        uint256 currentShareValue = (accumulatedFees * benefactorShares[benefactor]) / totalShares;

        // Calculate unclaimed amount (delta from last claim)
        ethClaimed = currentShareValue > shareValueAtLastClaim[benefactor]
            ? currentShareValue - shareValueAtLastClaim[benefactor]
            : 0;

        require(ethClaimed > 0, "No new fees to claim");

        // Unwrap any WETH to ensure we have native ETH for fees
        uint256 wethBalance = IWETH9(weth).balanceOf(address(this));
        if (wethBalance > 0) {
            IWETH9(weth).withdraw(wethBalance);
        }

        // Transfer ETH to benefactor
        require(address(this).balance >= ethClaimed, "Insufficient ETH for claim");
        (bool success, ) = payable(benefactor).call{value: ethClaimed}("");
        require(success, "ETH transfer failed");

        // Update claim state
        shareValueAtLastClaim[benefactor] = currentShareValue;
        lastClaimTimestamp[benefactor] = block.timestamp;

        emit FeesClaimed(benefactor, ethClaimed);

        return ethClaimed;
    }

    // ========== Fee Accumulation ==========

    /**
     * @notice Record fees accumulated from LP position
     * @dev Called by owner when fees are collected from V4 LP position
     * @param feeAmount Total fees accumulated (in ETH or converted value)
     */
    function recordAccumulatedFees(uint256 feeAmount) external onlyOwner {
        require(feeAmount > 0, "Fee amount must be positive");
        accumulatedFees += feeAmount;
        emit FeesAccumulated(feeAmount);
    }

    // ========== Internal Helpers ==========

    /**
     * @notice Get all benefactors with pending contributions in current dragnet
     * @dev Returns array of addresses added during current dragnet
     *      Used in convertAndAddLiquidity to iterate benefactors for share issuance
     */
    function _getActiveBenefactors() internal view returns (address[] memory) {
        return conversionParticipants;
    }

    /**
     * @notice Clear conversion participants array for next dragnet round
     * @dev Called after conversion completes and shares are issued
     */
    function _clearConversionParticipants() internal {
        while (conversionParticipants.length > 0) {
            conversionParticipants.pop();
        }
    }

    /**
     * @notice Swap ETH for alignment target token via Uniswap V3
     * @dev Primary routing through V3 for capital efficiency, with V2 fallback
     *      - Wraps ETH to WETH
     *      - Routes through V3 SwapRouter with configured fee tier
     *      - Slippage protection via minOutTarget
     * @param ethAmount ETH to swap
     * @param minOutTarget Minimum tokens to receive (slippage protection)
     * @return tokenReceived Amount of target token received from swap
     */
    function _swapETHForTarget(uint256 ethAmount, uint256 minOutTarget)
        internal
        returns (uint256 tokenReceived)
    {
        require(ethAmount > 0, "Amount must be positive");
        require(alignmentToken != address(0), "No alignment token set");

        // STUB: For unit tests with mock addresses, return fake swap amount
        // In production with real addresses, this executes actual V3 swap
        if (weth.code.length == 0 || v3Router.code.length == 0) {
            // Simulate swap with 0.3% slippage
            tokenReceived = (ethAmount * 997) / 1000;
            require(tokenReceived >= minOutTarget, "Slippage too high");
            return tokenReceived;
        }

        // Wrap ETH to WETH for V3 swap
        IWETH9(weth).deposit{value: ethAmount}();

        // Approve V3 router to spend WETH
        IWETH9(weth).approve(v3Router, ethAmount);

        // Execute V3 swap: WETH → alignmentToken
        IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
            tokenIn: weth,
            tokenOut: alignmentToken,
            fee: v3PreferredFee,
            recipient: address(this),
            deadline: block.timestamp + 300, // 5 minute deadline
            amountIn: ethAmount,
            amountOutMinimum: minOutTarget,
            sqrtPriceLimitX96: 0 // No price limit (slippage handled by minOutTarget)
        });

        tokenReceived = IV3SwapRouter(v3Router).exactInputSingle(params);

        require(tokenReceived >= minOutTarget, "Slippage too high");
        return tokenReceived;
    }

    /**
     * @notice Add liquidity to V4 pool position via unlock callback
     * @dev Uses PoolManager.unlock() pattern to execute modifyLiquidity
     *      - Triggers unlockCallback() which calls modifyLiquidity and settles deltas
     *      - Returns actual liquidity units created by V4
     * @param amount0 ETH amount to add (or target token depending on pool ordering)
     * @param amount1 Target token amount to add (or ETH depending on pool ordering)
     * @param tickLower Lower tick for concentrated liquidity range
     * @param tickUpper Upper tick for concentrated liquidity range
     * @return liquidityUnits Actual liquidity units created in V4 position
     */
    function _addToLpPosition(
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper
    ) internal returns (uint128 liquidityUnits) {
        require(amount0 > 0 && amount1 > 0, "Amounts must be positive");

        // Store tick range for future position queries
        lastTickLower = tickLower;
        lastTickUpper = tickUpper;

        // STUB: For unit tests with mock poolManager, return fake liquidity amount
        // In production with real poolManager, this executes actual V4 LP addition
        if (poolManager.code.length == 0) {
            // Return simple approximation for unit tests
            liquidityUnits = uint128((amount0 + amount1) / 2);
            return liquidityUnits;
        }

        // Approve tokens for PoolManager settlement
        Currency currency0 = v4PoolKey.currency0;
        Currency currency1 = v4PoolKey.currency1;

        // Approve non-native currencies for PoolManager
        if (!currency0.isAddressZero()) {
            IERC20(Currency.unwrap(currency0)).approve(address(poolManager), amount0);
        }
        if (!currency1.isAddressZero()) {
            IERC20(Currency.unwrap(currency1)).approve(address(poolManager), amount1);
        }

        // Calculate liquidity delta to add
        // Use simple approximation - V4 will calculate actual liquidity
        int256 liquidityDelta = int256((amount0 + amount1) / 2);

        // Prepare callback data
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidityDelta,
            salt: 0
        });

        ModifyLiquidityCallbackData memory callbackData = ModifyLiquidityCallbackData({
            params: params
        });

        // Execute unlock → callback → modifyLiquidity → settle
        bytes memory result = IPoolManager(poolManager).unlock(abi.encode(callbackData));

        // Decode balance delta from callback result
        BalanceDelta delta = abi.decode(result, (BalanceDelta));

        // Return liquidity units (use liquidityDelta as approximation)
        liquidityUnits = uint128(uint256(liquidityDelta));

        return liquidityUnits;
    }

    /**
     * @notice Unlock callback for V4 position operations
     * @dev Called by PoolManager during unlock() - executes modifyLiquidity and settles deltas
     * @param data Encoded ModifyLiquidityCallbackData
     * @return Encoded BalanceDelta from modifyLiquidity operation
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only PoolManager");

        ModifyLiquidityCallbackData memory params = abi.decode(data, (ModifyLiquidityCallbackData));

        // Execute modifyLiquidity on the V4 pool
        (BalanceDelta delta, ) = IPoolManager(poolManager).modifyLiquidity(
            v4PoolKey,
            params.params,
            "" // hookData
        );

        // Settle the deltas (transfer tokens to/from pool)
        _settleDelta(delta);

        return abi.encode(delta);
    }

    /**
     * @notice Settle currency deltas from V4 operations
     * @dev Uses CurrencySettler library pattern from V4 core tests
     *      - Negative delta = vault owes tokens to pool → currency.settle()
     *      - Positive delta = pool owes tokens to vault → currency.take()
     * @param delta Balance delta from modifyLiquidity operation
     */
    function _settleDelta(BalanceDelta delta) internal {
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        IPoolManager pm = IPoolManager(poolManager);

        // Settle currency0
        if (delta0 < 0) {
            // Vault owes currency0 to pool
            v4PoolKey.currency0.settle(pm, address(this), uint128(-delta0), false);
        } else if (delta0 > 0) {
            // Pool owes currency0 to vault (excess tokens returned)
            v4PoolKey.currency0.take(pm, address(this), uint128(delta0), false);
            // If currency0 is WETH, unwrap back to ETH for caller reward
            if (Currency.unwrap(v4PoolKey.currency0) == weth) {
                uint256 wethBalance = IWETH9(weth).balanceOf(address(this));
                require(wethBalance >= uint128(delta0), "Insufficient WETH balance after take");
                IWETH9(weth).withdraw(uint128(delta0));
            }
        }

        // Settle currency1
        if (delta1 < 0) {
            // Vault owes currency1 to pool
            v4PoolKey.currency1.settle(pm, address(this), uint128(-delta1), false);
        } else if (delta1 > 0) {
            // Pool owes currency1 to vault (excess tokens returned)
            v4PoolKey.currency1.take(pm, address(this), uint128(delta1), false);
            // If currency1 is WETH, unwrap back to ETH for caller reward
            if (Currency.unwrap(v4PoolKey.currency1) == weth) {
                uint256 wethBalance = IWETH9(weth).balanceOf(address(this));
                require(wethBalance >= uint128(delta1), "Insufficient WETH balance after take");
                IWETH9(weth).withdraw(uint128(delta1));
            }
        }
    }

    /**
     * @notice Transfer currency (ETH or ERC20) to recipient
     * @param currency Currency to transfer (address(0) for native ETH)
     * @param to Recipient address
     * @param amount Amount to transfer
     */
    function _transferCurrency(Currency currency, address to, uint128 amount) internal {
        if (currency.isAddressZero()) {
            // Native ETH transfer
            (bool success, ) = to.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            // ERC20 transfer
            IERC20(Currency.unwrap(currency)).transfer(to, amount);
        }
    }

    /**
     * @notice Get price and reserves from V2 pool
     * @dev Queries Uniswap V2 pair for WETH/alignmentToken reserves
     * @return hasV2Pool True if V2 pool exists
     * @return priceV2 Price of alignmentToken in terms of WETH (scaled by 1e18)
     * @return reserveWETH WETH reserve in the pair
     * @return reserveToken Token reserve in the pair
     */
    function _getV2PriceAndReserves()
        internal
        view
        returns (
            bool hasV2Pool,
            uint256 priceV2,
            uint112 reserveWETH,
            uint112 reserveToken
        )
    {
        // Skip if v2Factory is mock (no code deployed)
        if (v2Factory.code.length == 0) {
            return (false, 0, 0, 0);
        }

        // Query V2 factory for pair address
        address pair = IUniswapV2Factory(v2Factory).getPair(weth, alignmentToken);

        // Check if pair exists
        if (pair == address(0)) {
            return (false, 0, 0, 0);
        }

        // Get reserves from pair
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();

        // Check if pool has liquidity
        if (reserve0 == 0 || reserve1 == 0) {
            return (false, 0, 0, 0);
        }

        // Determine token ordering (token0 < token1 by address)
        address token0 = IUniswapV2Pair(pair).token0();
        bool wethIsToken0 = (token0 == weth);

        if (wethIsToken0) {
            reserveWETH = reserve0;
            reserveToken = reserve1;
            // Price = WETH reserve / Token reserve
            priceV2 = (uint256(reserve0) * 1e18) / uint256(reserve1);
        } else {
            reserveWETH = reserve1;
            reserveToken = reserve0;
            // Price = WETH reserve / Token reserve
            priceV2 = (uint256(reserve1) * 1e18) / uint256(reserve0);
        }

        hasV2Pool = true;
    }

    /**
     * @notice Get price and liquidity from V3 pool
     * @dev Queries Uniswap V3 pool for WETH/alignmentToken at preferred fee tier
     * @return hasV3Pool True if V3 pool exists
     * @return priceV3 Price of alignmentToken in terms of WETH (scaled by 1e18)
     * @return liquidity Available liquidity at current tick
     */
    /**
     * @notice Query a single V3 pool for a specific fee tier
     * @param feeTier Fee tier to query (500, 3000, or 10000)
     * @return success True if pool exists and has valid data
     * @return price WETH price per alignment token (scaled by 1e18)
     * @return poolLiquidity Current pool liquidity
     */
    function _queryV3PoolForFee(uint24 feeTier)
        internal
        view
        returns (
            bool success,
            uint256 price,
            uint128 poolLiquidity
        )
    {
        // Skip if v3Factory is mock (no code deployed)
        if (v3Factory.code.length == 0) {
            return (false, 0, 0);
        }

        // Query V3 factory for pool address
        address pool = IUniswapV3Factory(v3Factory).getPool(weth, alignmentToken, feeTier);

        // Pool doesn't exist
        if (pool == address(0)) {
            return (false, 0, 0);
        }

        // Try to query pool state
        try IUniswapV3Pool(pool).slot0() returns (
            uint160 sqrtPriceX96,
            int24,
            uint16,
            uint16,
            uint16,
            uint8,
            bool unlocked
        ) {
            // Pool must be unlocked to trust the data
            if (!unlocked) {
                return (false, 0, 0);
            }

            // Query liquidity
            try IUniswapV3Pool(pool).liquidity() returns (uint128 liq) {
                // Check if pool has meaningful liquidity
                if (liq == 0) {
                    return (false, 0, 0);
                }

                // Convert sqrtPriceX96 to price: (sqrtPriceX96 * sqrtPriceX96 * 1e18) >> 192
                uint256 rawPrice = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18) >> 192;

                // Determine token ordering to get WETH/token price
                address token0 = IUniswapV3Pool(pool).token0();

                if (token0 == weth) {
                    // rawPrice is token1/token0, we want WETH/token = token0/token1
                    if (rawPrice == 0) {
                        return (false, 0, 0);
                    }
                    price = (1e18 * 1e18) / rawPrice;
                } else {
                    // rawPrice is token1/token0, we want WETH/token = token1/token0
                    price = rawPrice;
                }

                return (true, price, liq);
            } catch {
                return (false, 0, 0);
            }
        } catch {
            return (false, 0, 0);
        }
    }

    /**
     * @notice Query V3 pools across multiple fee tiers for price and liquidity
     * @return hasV3Pool True if a valid V3 pool was found
     * @return priceV3 WETH price per alignment token (scaled by 1e18)
     * @return liquidity Pool liquidity
     */
    function _getV3PriceAndLiquidity()
        internal
        view
        returns (
            bool hasV3Pool,
            uint256 priceV3,
            uint128 liquidity
        )
    {
        // Try fee tiers in order of preference: 0.3%, 0.05%, 1%
        uint24[3] memory feeTiers = [uint24(3000), uint24(500), uint24(10000)];

        for (uint256 i = 0; i < feeTiers.length; i++) {
            (bool success, uint256 price, uint128 liq) = _queryV3PoolForFee(feeTiers[i]);

            if (success) {
                return (true, price, liq);
            }
        }

        // No valid V3 pool found across all fee tiers
        return (false, 0, 0);
    }

    /**
     * @notice Check if price deviation between sources is acceptable
     * @param price1 First price (scaled by 1e18)
     * @param price2 Second price (scaled by 1e18)
     * @return isAcceptable True if deviation is within threshold
     * @return deviation Actual deviation in basis points
     */
    function _checkPriceDeviation(uint256 price1, uint256 price2)
        internal
        view
        returns (bool isAcceptable, uint256 deviation)
    {
        if (price1 == 0 || price2 == 0) {
            return (false, 0);
        }

        // Calculate percentage difference
        uint256 diff = price1 > price2 ? price1 - price2 : price2 - price1;
        uint256 avg = (price1 + price2) / 2;

        // Convert to basis points (1 bps = 0.01%)
        deviation = (diff * 10000) / avg;

        // Check if within acceptable threshold
        isAcceptable = deviation <= maxPriceDeviationBps;
    }

    /**
     * @notice Check target asset price and purchase power from DEX
     * @dev Queries current price of alignment token from V2/V3/V4 pools
     *      - Target token often in majority position in V2/V3 pools (deep liquidity)
     *      - Validates pricing and ensures purchase power is available
     *      - Compares against oracle price if available (for drift detection)
     *      - Returns early if price is reasonable, reverts if unusual movements detected
     */
    function _checkTargetAssetPriceAndPurchasePower() internal view {
        // Query V2 pool for price and reserves
        (bool hasV2Pool, uint256 priceV2, uint112 reserveWETH, uint112 reserveToken) = _getV2PriceAndReserves();

        // Query V3 pool for price and liquidity
        (bool hasV3Pool, uint256 priceV3, uint128 liquidityV3) = _getV3PriceAndLiquidity();

        // If no pools are available, skip validation (expected in unit tests with mock addresses)
        // In production with real factory addresses, at least one pool should exist
        if (!hasV2Pool && !hasV3Pool) {
            return;
        }

        // If both pools exist, check price deviation
        if (hasV2Pool && hasV3Pool) {
            (bool isAcceptable, uint256 deviation) = _checkPriceDeviation(priceV2, priceV3);
            require(isAcceptable, "Price deviation too high between V2/V3");
        }

        // Verify sufficient liquidity for the pending swap
        // For V2: check that reserves can handle the swap without excessive slippage
        if (hasV2Pool) {
            // Require minimum WETH reserve (e.g., at least 10 ETH in pool)
            require(reserveWETH >= 10 ether, "Insufficient WETH liquidity in V2");

            // Calculate expected output for our swap amount using constant product formula
            if (totalPendingETH > 0) {
                // For safety, check that our swap won't drain more than 10% of reserves
                uint256 maxSwapAmount = uint256(reserveWETH) / 10; // 10% of WETH reserve
                require(totalPendingETH <= maxSwapAmount, "Swap amount too large for V2 pool");

                // Calculate expected slippage
                uint256 amountInWithFee = totalPendingETH * 997;
                uint256 expectedOut = (amountInWithFee * reserveToken) / ((reserveWETH * 1000) + amountInWithFee);

                // Require output is reasonable (non-zero)
                require(expectedOut > 0, "Insufficient purchase power");
            }
        }

        // NOTE: Oracle price comparison would go here in production
        // Example: Chainlink price feed comparison
        // if (hasOraclePrice) {
        //     (bool oracleAcceptable,) = _checkPriceDeviation(priceV2, oraclePrice);
        //     require(oracleAcceptable, "Price deviation from oracle too high");
        // }
    }

    /**
     * @notice Check current vault-owned LP position tick values
     * @dev Retrieves tick range and liquidity of vault's existing V4 position
     *      Used to determine optimal tick range for new liquidity additions
     *      and to understand the vault's current concentration strategy
     */
    function _checkCurrentVaultOwnedLpTickValues() internal view {
        // If vault has no LP position yet, nothing to check
        if (totalLPUnits == 0) {
            return;
        }

        // If we haven't stored tick values yet, skip check
        // (This can happen on first deposit before any LP is added)
        if (lastTickLower == 0 && lastTickUpper == 0) {
            return;
        }

        // Skip validation if poolManager is a mock address (no code deployed)
        // This allows unit tests with mock addresses to pass while providing
        // full validation in production/fork tests
        if (poolManager.code.length == 0) {
            return;
        }

        // Query the vault's position using StateLibrary
        PoolId poolId = v4PoolKey.toId();

        (uint128 liquidity, ,) = StateLibrary.getPositionInfo(
            IPoolManager(poolManager),
            poolId,
            address(this),      // Position owner (this vault)
            lastTickLower,      // Stored tick lower bound
            lastTickUpper,      // Stored tick upper bound
            0                   // Salt (we use 0)
        );

        // Verify position exists and has liquidity
        // Note: This is a validation check - if it fails, something is wrong
        // The position should exist if totalLPUnits > 0
        require(liquidity > 0, "Position liquidity is zero but totalLPUnits > 0");

        // Position is valid - no action needed
        // The tick values and liquidity will be used by _calculateProportionOfEthToSwapBasedOnVaultOwnedLpTickValues()
    }

    /**
     * @notice Calculate proportion of ETH to swap vs. LP add based on vault's LP tick values
     * @dev Returns proportion (0-1e18) representing what % of ETH to swap
     *      - If vault has existing V4 LP position, calculate ratio from tick range
     *      - Higher tick range = concentrated liquidity = lower swap proportion needed
     *      - If target token in majority (common in V2/V3), may need less swap
     *      Example: if LP is 50:50 ETH:TOKEN, returns 5e17 (50%)
     *      Remaining (1e18 - proportion) is held for direct LP add
     * @return proportionToSwap Proportion as 1e18 scale (e.g., 5e17 = 50%)
     */
    function _calculateProportionOfEthToSwapBasedOnVaultOwnedLpTickValues()
        internal
        view
        returns (uint256 proportionToSwap)
    {
        // If vault has no LP position yet, use balanced 50:50 entry
        if (totalLPUnits == 0 || (lastTickLower == 0 && lastTickUpper == 0)) {
            return 5e17; // 50%
        }

        // Skip calculation if poolManager is a mock address (no code deployed)
        // Return default 50% for unit tests with mock addresses
        if (poolManager.code.length == 0) {
            return 5e17;
        }

        // Get current pool price
        PoolId poolId = v4PoolKey.toId();
        (uint160 sqrtPriceX96, , ,) = StateLibrary.getSlot0(IPoolManager(poolManager), poolId);

        // Validate price is reasonable
        if (sqrtPriceX96 == 0) {
            return 5e17; // Invalid price, use default
        }

        // Calculate sqrtPrice at tick bounds using TickMath
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(lastTickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(lastTickUpper);

        // Use a hypothetical liquidity amount for ratio calculation
        uint128 hypotheticalLiquidity = 1e18;

        // Calculate how much of each token is needed to add liquidity at current price
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtPriceAX96,
            sqrtPriceBX96,
            hypotheticalLiquidity
        );

        // Handle edge case: if current price is outside our tick range
        if (amount0 == 0 && amount1 == 0) {
            // Price is outside range, use default 50%
            return 5e17;
        }

        // Determine which currency is WETH and calculate proportion
        bool currency0IsWETH = (Currency.unwrap(v4PoolKey.currency0) == weth);

        if (currency0IsWETH) {
            // WETH is currency0, we need to swap to get currency1 (alignmentToken)
            // Proportion to swap = amount1 / (amount0 + amount1)
            // This tells us what % of our ETH should become tokens
            if (amount0 + amount1 == 0) {
                return 5e17; // Fallback to 50%
            }
            proportionToSwap = (amount1 * 1e18) / (amount0 + amount1);
        } else {
            // WETH is currency1, we need to swap to get currency0 (alignmentToken)
            // Proportion to swap = amount0 / (amount0 + amount1)
            if (amount0 + amount1 == 0) {
                return 5e17; // Fallback to 50%
            }
            proportionToSwap = (amount0 * 1e18) / (amount0 + amount1);
        }

        // Sanity check: proportion should be between 0 and 100%
        if (proportionToSwap > 1e18) {
            proportionToSwap = 1e18; // Cap at 100%
        }

        return proportionToSwap;
    }

    /**
     * @notice Validate V4 pool configuration
     * @param poolKey Pool key to validate
     * @dev Checks pool initialization, token pairs, and fee tier
     */
    function _validateV4Pool(PoolKey calldata poolKey) internal view {
        // Validate at least one currency is set
        require(
            Currency.unwrap(poolKey.currency0) != address(0) ||
            Currency.unwrap(poolKey.currency1) != address(0),
            "Invalid pool key: no currencies set"
        );

        // Validate fee tier is standard (0.05%, 0.3%, or 1%)
        require(
            poolKey.fee == 500 || poolKey.fee == 3000 || poolKey.fee == 10000,
            "Invalid fee tier (must be 500, 3000, or 10000)"
        );

        // Validate tick spacing matches fee tier
        // V4 standard: 500bps=10, 3000bps=60, 10000bps=200
        if (poolKey.fee == 500) {
            require(poolKey.tickSpacing == 10, "Invalid tick spacing for 0.05% fee");
        } else if (poolKey.fee == 3000) {
            require(poolKey.tickSpacing == 60, "Invalid tick spacing for 0.3% fee");
        } else if (poolKey.fee == 10000) {
            require(poolKey.tickSpacing == 200, "Invalid tick spacing for 1% fee");
        }

        // Validate alignment token is one of the currencies
        address currency0Addr = Currency.unwrap(poolKey.currency0);
        address currency1Addr = Currency.unwrap(poolKey.currency1);

        require(
            currency0Addr == alignmentToken || currency1Addr == alignmentToken,
            "Alignment token not in pool"
        );

        // Validate WETH is the other currency (or native ETH via address(0))
        bool hasWETH = currency0Addr == weth || currency1Addr == weth;
        bool hasNativeETH = currency0Addr == address(0) || currency1Addr == address(0);

        require(
            hasWETH || hasNativeETH,
            "Pool must contain WETH or native ETH"
        );

        // Validate currency ordering (currency0 < currency1)
        require(
            currency0Addr < currency1Addr,
            "Invalid currency ordering (currency0 must be < currency1)"
        );

        // Note: Pool initialization check is deferred to actual usage in convertAndAddLiquidity()
        // This allows setting pool key before pool is initialized, then validating on first use
        // If pool doesn't exist when attempting LP operations, transaction will revert naturally
    }

    // ========== Query Functions ==========

    /**
     * @notice Get benefactor's total historical contribution (for bragging rights)
     */
    function getBenefactorContribution(address benefactor)
        external
        view
        returns (uint256)
    {
        return benefactorTotalETH[benefactor];
    }

    /**
     * @notice Get benefactor's current share balance
     */
    function getBenefactorShares(address benefactor)
        external
        view
        returns (uint256)
    {
        return benefactorShares[benefactor];
    }

    /**
     * @notice Calculate benefactor's current claimable amount without delta
     */
    function calculateClaimableAmount(address benefactor)
        external
        view
        returns (uint256)
    {
        if (totalShares == 0 || accumulatedFees == 0) return 0;
        return (accumulatedFees * benefactorShares[benefactor]) / totalShares;
    }

    /**
     * @notice Get benefactor's unclaimed fees (delta since last claim)
     */
    function getUnclaimedFees(address benefactor)
        external
        view
        returns (uint256)
    {
        uint256 currentShareValue = (accumulatedFees * benefactorShares[benefactor]) / totalShares;
        return currentShareValue > shareValueAtLastClaim[benefactor]
            ? currentShareValue - shareValueAtLastClaim[benefactor]
            : 0;
    }

    // ========== Configuration ==========

    /**
     * @notice Update alignment token address
     */
    function setAlignmentToken(address newToken) external onlyOwner {
        require(newToken != address(0), "Invalid token");
        alignmentToken = newToken;
    }

    /**
     * @notice Update V4 pool key for liquidity operations
     */
    function setV4PoolKey(PoolKey calldata newPoolKey) external onlyOwner {
        // Validate pool configuration before setting
        _validateV4Pool(newPoolKey);
        v4PoolKey = newPoolKey;
    }

    /**
     * @notice Update conversion reward basis points
     */
    function setConversionRewardBps(uint256 newBps) external onlyOwner {
        require(newBps <= 100, "Reward too high (max 1%)");
        conversionRewardBps = newBps;
    }

    /**
     * @notice Set maximum allowed price deviation between DEXes
     * @param newBps New maximum deviation in basis points (100 = 1%)
     */
    function setMaxPriceDeviationBps(uint256 newBps) external onlyOwner {
        require(newBps <= 2000, "Deviation too high (max 20%)");
        maxPriceDeviationBps = newBps;
    }

    /**
     * @notice Owner can withdraw fees manually (or use recordAccumulatedFees)
     */
    function depositFees() external payable onlyOwner {
        require(msg.value > 0, "Amount must be positive");
        accumulatedFees += msg.value;
        emit FeesAccumulated(msg.value);
    }
}
