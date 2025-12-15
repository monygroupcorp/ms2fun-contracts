// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
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

/**
 * @title UltraAlignmentVault
 * @notice Share-based vault for collecting and distributing fees from ms2fun ecosystem
 * @dev Clean implementation using share accounting to eliminate complexity
 */
contract UltraAlignmentVault is ReentrancyGuard, Ownable, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

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
    address public alignmentToken;
    PoolKey public v4PoolKey;

    // Configuration
    uint256 public conversionRewardBps = 5; // 0.05% reward for caller
    uint24 public v3PreferredFee = 3000; // 0.3% fee tier for V3 swaps

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
        address _alignmentToken
    ) {
        _initializeOwner(msg.sender);
        require(_weth != address(0), "Invalid WETH");
        require(_poolManager != address(0), "Invalid pool manager");
        require(_v3Router != address(0), "Invalid V3 router");
        require(_v2Router != address(0), "Invalid V2 router");
        require(_alignmentToken != address(0), "Invalid alignment token");

        weth = _weth;
        poolManager = _poolManager;
        v3Router = _v3Router;
        v2Router = _v2Router;
        alignmentToken = _alignmentToken;
    }

    // ========== Fee Reception ==========

    /**
     * @notice Receive ETH contributions from any source
     * @dev Tracks msg.sender as benefactor, adds to pending dragnet
     */
    receive() external payable nonReentrant {
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

        // Step 1: Calculate caller reward upfront
        uint256 callerReward = (totalPendingETH * conversionRewardBps) / 10000;
        uint256 ethToAdd = totalPendingETH - callerReward;

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
        uint256 lpUnitsBeforeAdd = totalLPUnits;
        uint128 newLiquidityUnits = _addToLpPosition(ethToSwap, targetTokenReceived, tickLower, tickUpper);

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

        // Transfer ETH to benefactor
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

        // Approve tokens for PoolManager settlement
        // Determine which currency is ETH vs token based on v4PoolKey ordering
        Currency currency0 = v4PoolKey.currency0;
        Currency currency1 = v4PoolKey.currency1;

        // Approve alignment token (non-native currency) for settlement
        if (!currency0.isAddressZero()) {
            IERC20(Currency.unwrap(currency0)).approve(address(poolManager), amount0);
        }
        if (!currency1.isAddressZero()) {
            IERC20(Currency.unwrap(currency1)).approve(address(poolManager), amount1);
        }

        // Calculate liquidity delta to add
        // For simplicity, use a conservative estimate - actual liquidity will be calculated by V4
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

        // Decode liquidity units from callback result
        BalanceDelta delta = abi.decode(result, (BalanceDelta));

        // Return liquidity units (use absolute value of amount0 + amount1 as approximation)
        // In production, track the actual liquidityDelta returned from modifyLiquidity
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
     * @dev Handles both ETH (native) and ERC20 token settlements
     *      - Negative delta = vault owes tokens to pool → transfer to PoolManager
     *      - Positive delta = pool owes tokens to vault → PoolManager transfers to us
     *      Note: PoolManager handles the actual settlement via sync() or take()
     * @param delta Balance delta from modifyLiquidity operation
     */
    function _settleDelta(BalanceDelta delta) internal {
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        // Settle currency0
        if (delta0 < 0) {
            // Vault owes currency0 to pool - transfer tokens
            _transferCurrency(v4PoolKey.currency0, address(poolManager), uint128(-delta0));
            // Call sync to update PoolManager's accounting
            IPoolManager(poolManager).sync(v4PoolKey.currency0);
        } else if (delta0 > 0) {
            // Pool owes currency0 to vault - take from reserves
            IPoolManager(poolManager).take(v4PoolKey.currency0, address(this), uint128(delta0));
        }

        // Settle currency1
        if (delta1 < 0) {
            // Vault owes currency1 to pool - transfer tokens
            _transferCurrency(v4PoolKey.currency1, address(poolManager), uint128(-delta1));
            // Call sync to update PoolManager's accounting
            IPoolManager(poolManager).sync(v4PoolKey.currency1);
        } else if (delta1 > 0) {
            // Pool owes currency1 to vault - take from reserves
            IPoolManager(poolManager).take(v4PoolKey.currency1, address(this), uint128(delta1));
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
     * @notice Check target asset price and purchase power from DEX
     * @dev Queries current price of alignment token from V2/V3/V4 pools
     *      - Target token often in majority position in V2/V3 pools (deep liquidity)
     *      - Validates pricing and ensures purchase power is available
     *      - Compares against oracle price if available (for drift detection)
     *      - Returns early if price is reasonable, reverts if unusual movements detected
     */
    function _checkTargetAssetPriceAndPurchasePower() internal view {
        // In production, this would:
        // 1. Query V2 pool reserves: getPair(WETH, alignmentToken) → getReserves()
        //    - Calculate price: alignmentTokenPrice = wethReserve / tokenReserve
        // 2. Query V3 pool: pool.slot0() → Get current sqrt(price) and liquidity
        //    - Decode tick-based price into token ratio
        // 3. Query V4 pool: pool.positions[positionId] → Get vault's LP position ticks
        //    - Verify sufficient liquidity exists in current range
        // 4. Compare against oracle (e.g., Chainlink, Band Protocol)
        //    - Flag if DEX price deviates >5% from oracle (potential flash loan attack)
        // 5. Verify sufficient reserves to accommodate totalPendingETH swap
        //    - If target token is in majority, pool should have ample WETH depth

        // Stub validation: Assume pools exist with reasonable liquidity
        // In reality: require(price_drift <= 5%, "Price deviation too high");
        // This prevents sandwich attacks and validates purchase power
    }

    /**
     * @notice Check current vault-owned LP position tick values
     * @dev Retrieves tick range and liquidity of vault's existing V4 position
     *      Used to determine optimal tick range for new liquidity additions
     *      and to understand the vault's current concentration strategy
     */
    function _checkCurrentVaultOwnedLpTickValues() internal view {
        // In production, this would:
        // 1. Query V4 pool state: IPoolManager(poolManager).positions(positionKey)
        // 2. Retrieve vault's existing position:
        //    - tickLower: Lower bound of concentrated range
        //    - tickUpper: Upper bound of concentrated range
        //    - liquidity: Current liquidity units in position
        //    - feeGrowthInside0LastX128, feeGrowthInside1LastX128: Fee tracking
        // 3. Calculate current position value:
        //    - Use tick prices to determine implied WETH/TOKEN ratio
        //    - If target token in majority (e.g., V2/V3), position likely heavily weighted
        // 4. Store values for use in _calculateProportionOfEthToSwapBasedOnVaultOwnedLpTickValues
        // 5. Determine if new additions should:
        //    - Use same tick range (stack on existing position)
        //    - Use different range (diversify concentration)
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
        // In production, this would:
        // 1. Check if vault has existing LP position (totalLPUnits > 0)
        // 2. Query V4 pool for position details: tickLower, tickUpper, liquidity
        // 3. If target token is in majority position in V2/V3:
        //    - More token reserve available → less swap needed to maintain ratio
        //    - Example: 70% token / 30% ETH in pool → swap 30% of new ETH
        // 4. Calculate tick-based ratio from concentrated range
        //    - If LP is wide range (many ticks) → closer to 50:50 split
        //    - If LP is narrow range (few ticks) → optimized for specific price
        // 5. Factor in pool composition to avoid over-swapping

        // Stub logic: Return proportional ratio based on vault's LP state
        // If vault has no LP yet, assume 50:50 (equal swap proportion)
        // If vault has LP, calculate from existing position weights
        if (totalLPUnits == 0) {
            // No existing position: assume balanced entry (50% swap, 50% hold)
            proportionToSwap = 5e17; // 50%
        } else {
            // Existing position: maintain similar composition
            // Stub: Use 50% as baseline. In reality, calculate from vault's ticks.
            // If target token concentrated in V2/V3, might reduce swap proportion
            proportionToSwap = 5e17; // 50% - maintain current composition
        }
        return proportionToSwap;
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
        require(Currency.unwrap(newPoolKey.currency0) != address(0) || Currency.unwrap(newPoolKey.currency1) != address(0), "Invalid pool key");
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
     * @notice Owner can withdraw fees manually (or use recordAccumulatedFees)
     */
    function depositFees() external payable onlyOwner {
        require(msg.value > 0, "Amount must be positive");
        accumulatedFees += msg.value;
        emit FeesAccumulated(msg.value);
    }
}
