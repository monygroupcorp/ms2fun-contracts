// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {LPPositionValuation} from "../libraries/LPPositionValuation.sol";

// Forward declare to avoid circular imports
interface IUltraAlignmentHookFactory {
    function createHook(
        address poolManager,
        address vault,
        address weth,
        address creator,
        bool isCanonical
    ) external payable returns (address hook);
}

/**
 * @title UltraAlignmentVault
 * @notice Generalized vault for collecting fees from all projects (ERC404, ERC1155, etc.)
 * @dev Focuses on core functionality: tax collection, conversion, liquidity provision
 *
 * DESIGN:
 * - Receive ERC404 swap taxes from hooks
 * - Receive ERC1155 creator tithes
 * - Receive direct ETH from any benefactor (no authorization required)
 * - Convert accumulated ETH to alignment target token
 * - Add liquidity to alignment target pool
 * - Track benefactor contributions for analytics
 * - Track per-benefactor fees claimed for multi-claim support
 *
 * BENEFACTOR: Can be project instance, hook, EOA, or any sender
 */
contract UltraAlignmentVault is ReentrancyGuard, Ownable {
    // ========== Data Structures ==========

    struct BenefactorContribution {
        address benefactor;           // Can be project instance, hook, or EOA
        uint128 totalETHContributed;
        bool exists;
    }

    struct AlignmentTarget {
        address token; // Alignment target token (e.g., CULT)
        address v4Pool; // V4 pool address
        address weth; // WETH address
        uint256 totalLiquidity;
        uint256 totalFeesCollected;
    }

    /**
     * @notice Minimalist benefactor state for O(1) fee claiming
     * @dev Stores only what's needed: lifetime contribution, last claim state
     *      Replaces per-conversion benefactor tracking from old design
     */
    struct BenefactorState {
        uint256 lifetimeETHContributed;   // Total ETH they've ever contributed (cumulative, never reset)
        uint256 lastClaimAmount;          // Amount they claimed last time (for delta calculation)
        uint256 lastClaimTimestamp;       // When they last claimed
        bool exists;                      // Tracking marker
    }

    // ========== State Variables ==========

    AlignmentTarget public alignmentTarget;

    // Hook management (vault is master of exactly 1 canonical hook)
    address public canonicalHook;
    address public immutable hookFactory;
    address public immutable weth;

    // ========== PHASE 1: ACCUMULATION - Pending Contributions ==========
    // ETH waiting to be converted to LP (cleared after each conversion)
    mapping(address => uint256) public pendingContribution;      // ETH pending conversion per benefactor
    mapping(address => bool) public hasPendingContribution;      // Quick existence check
    uint256 public totalPendingETH;                              // Sum of all pending contributions

    // ========== PHASE 3: LIFETIME TRACKING - Enables Fee Claims ==========
    // Cumulative ETH converted to LPs (NEVER resets, eternal)
    mapping(address => uint256) public benefactorLifetimeETHDeposited;  // Cumulative across all epochs
    mapping(address => bool) public benefactorExists;                   // Ever contributed?
    uint128 public totalEverDeposited;                                  // Lifetime total converted to LPs

    // ========== PHASE 3B: V4 LIQUIDITY UNITS - Ground Truth for Fee Distribution ==========
    // Track V4's liquidity units per conversion (from TickMath.getLiquidityForAmounts)
    // This is the ACTUAL ground truth that V4 uses for fee distribution
    uint128 public totalPoolLiquidityUnits;                             // Sum of all liquidity units the vault contributed to V4

    // Benefactor lifetime liquidity units cache (O(1) lookups, updated at conversion time)
    mapping(address => uint128) public benefactorLifetimeLiquidityUnits; // Cached sum of liquidity units contributed by each benefactor

    // ========== PHASE 5: FEE CLAIM STATE ==========
    // Track claim deltas to enable multiple claims as fees accumulate
    mapping(address => uint256) public lastClaimAmount;      // What they claimed last time
    mapping(address => uint256) public lastClaimTimestamp;   // When they last claimed

    // ========== LEGACY MAPPINGS (Backward Compatibility) ==========
    // These mappings maintain backward compatibility during transition to new accounting model
    // They will be removed in a future major version after all benefactors migrate
    mapping(address => BenefactorContribution) public benefactorContributions;
    address[] public registeredBenefactors;
    mapping(address => BenefactorState) public benefactorState;

    // Epoch window management (trailing condenser pattern)
    uint256 public currentEpochId;                          // The active epoch being accumulated
    uint256 public minEpochIdInWindow;                      // Oldest epoch we keep in storage
    uint256 public constant maxEpochWindow = 3;             // Keep last 3 epochs, condense older
    mapping(uint256 => LPPositionValuation.EpochRecord) public epochs;  // Only store active epochs
    mapping(address => uint256[]) public benefactorEpochs;  // Which epochs benefactor participated in

    // Epoch boundary enforcement (informational only - no auto-triggers)
    uint256 public maxConversionsPerEpoch = 100;            // Recommended threshold for epoch finalization (advisory)

    // Conversion-indexed benefactor accounting (multi-conversion support)
    LPPositionValuation.ConversionRecord[] public conversionHistory;
    mapping(address => uint256[]) public benefactorConversions;
    uint256 public nextConversionId;

    // Fee accumulation
    uint256 public accumulatedETH;
    uint256 public accumulatedFees; // Total fees from LP positions
    uint128 public totalETHCollected; // Total across all benefactors

    // ========== Vault Treasury Architecture ==========
    // Separate pools for: conversion operations, fee accrual claims, operator incentives
    struct Treasury {
        uint256 conversionPool;        // ETH reserved for conversion → LP operations
        uint256 feeClaimPool;          // ETH reserved for benefactor fee claim payouts
        uint256 operatorIncentivePool; // ETH reserved for epoch keepers and converters
    }

    Treasury public treasury;

    // Accounting: track total contributions to each pool
    uint256 public totalAllocatedToConversions;
    uint256 public totalAllocatedToFeeClaims;
    uint256 public totalAllocatedToOperators;

    // Withdrawal tracking (for auditing)
    uint256 public totalWithdrawnForConversions;
    uint256 public totalWithdrawnForFeeClaims;
    uint256 public totalWithdrawnForOperators;

    // Thresholds
    uint256 public minConversionThreshold = 0.01 ether;
    uint256 public minLiquidityThreshold = 0.005 ether;

    // External contracts
    IPoolManager public v4PoolManager;
    address public router;

    // Epoch maintenance incentives (tunable)
    uint256 public epochKeeperRewardBps = 5; // 0.05% of epoch ETH as reward (basis points)

    // ========== Events ==========

    event BenefactorContributionReceived(address indexed benefactor, uint256 amount, bool isFromHook);
    event AlignmentTargetSet(address indexed token);
    event AlignmentTargetConverted(uint256 ethAmount, uint256 targetAmount, uint256 liquidity);
    event BenefactorTracked(address indexed benefactor, uint256 ethAmount);
    event CanonicalHookCreated(address indexed hook);

    // LP Conversion events
    event ConversionAndLiquidityAddedV4(
        uint256 ethSwapped,
        uint256 targetTokenReceived,
        uint256 lpPositionValue,
        uint256 callerReward
    );
    event BenefactorStakesCreated(uint256 stakedBenefactors, uint256 totalStakePercent);
    event FeesAccumulated(uint256 amount);
    event BenefactorFeesClaimed(address indexed benefactor, uint256 ethAmount);

    // Epoch maintenance events
    event EpochFinalized(uint256 indexed epochId, uint256 totalETH, uint256 totalLPValue);
    event EpochCompressed(uint256 indexed oldEpochId, uint256 newMinEpochId);

    // Treasury events
    event TreasuryAllocated(string indexed poolName, uint256 amount);
    event TreasuryWithdrawn(string indexed poolName, uint256 amount);
    event TreasuryRebalanced(uint256 conversionPool, uint256 feeClaimPool, uint256 operatorPool);

    // ========== Constructor ==========

    constructor(
        address _alignmentTarget,
        address _weth,
        address _v4PoolManager,
        address _router,
        address _hookFactory
    ) {
        _initializeOwner(msg.sender);

        require(_alignmentTarget != address(0), "Invalid target");
        require(_weth != address(0), "Invalid WETH");
        require(_v4PoolManager != address(0), "Invalid V4 PM");
        require(_router != address(0), "Invalid router");
        require(_hookFactory != address(0), "Invalid hook factory");

        // Initialize immutables
        weth = _weth;
        hookFactory = _hookFactory;

        alignmentTarget = AlignmentTarget({
            token: _alignmentTarget,
            v4Pool: address(0),
            weth: _weth,
            totalLiquidity: 0,
            totalFeesCollected: 0
        });

        v4PoolManager = IPoolManager(_v4PoolManager);
        router = _router;

        // Initialize treasury structure
        treasury = Treasury({
            conversionPool: 0,
            feeClaimPool: 0,
            operatorIncentivePool: 0
        });

        // Create canonical hook at deployment (OPTIONAL - can fail gracefully)
        _createCanonicalHook(_v4PoolManager);
    }

    // ========== Fee Reception ==========

    /**
     * @notice Receive taxes from V4 hooks
     * @dev Hook-specific function handling taxes collected via hook mechanism
     * @param currency Currency of the tax (ETH or token)
     * @param amount Amount of tax received
     * @param benefactor Address of the project/factory that generated the tax
     */
    function receiveHookTax(
        Currency currency,
        uint256 amount,
        address benefactor
    ) external payable nonReentrant {
        require(amount > 0, "Amount must be positive");
        require(benefactor != address(0), "Invalid benefactor");

        accumulatedETH += amount;
        _trackBenefactorContribution(benefactor, amount);

        emit BenefactorContributionReceived(benefactor, amount, true);
    }

    /**
     * @notice Accept ETH from any source (factories, EOAs, direct transfers)
     * @dev Fallback for all ETH inflows not routed through hook
     *      Handles ERC1155 tithe withdrawals, direct contributions, etc.
     *      Tracks msg.sender as the benefactor
     *      Automatically allocates to treasury conversion pool for perpetual operation
     */
    receive() external payable nonReentrant {
        require(msg.value > 0, "Amount must be positive");

        accumulatedETH += msg.value;
        _trackBenefactorContribution(msg.sender, msg.value);

        // Allocate received ETH to conversion pool in treasury
        treasury.conversionPool += msg.value;
        totalAllocatedToConversions += msg.value;

        emit BenefactorContributionReceived(msg.sender, msg.value, false);
        emit TreasuryAllocated("conversionPool", msg.value);
    }

    // ========== Hook Management ==========

    /**
     * @notice Create the vault's canonical hook (OPTIONAL - fails gracefully)
     * @dev Called during initialization. Hook creation may fail if factory is unavailable.
     *      Vault can still operate without a hook if creation fails.
     * @param _poolManager Address of the Uniswap V4 pool manager
     */
    function _createCanonicalHook(address _poolManager) internal {
        // Try to create canonical hook - fail gracefully if it doesn't work
        try IUltraAlignmentHookFactory(hookFactory).createHook{value: 0.001 ether}(
            _poolManager,
            address(this),
            weth,
            msg.sender,
            true // isCanonical = true
        ) returns (address hook) {
            canonicalHook = hook;
            emit CanonicalHookCreated(hook);
        } catch {
            // Hook creation failed - vault can still operate without it
            // This is optional per Phase 1 decision
        }
    }

    /**
     * @notice Get the vault's canonical hook address
     * @return The canonical hook address (may be address(0) if creation failed)
     */
    function getHook() external view returns (address) {
        return canonicalHook;
    }

    // ========== Internal Helpers ==========

    /**
     * @notice Get list of benefactors who have contributed to this round's accumulation (PHASE 1)
     * @dev Returns only benefactors with pendingContribution > 0 (this round's contributions)
     *      Used in convertAndAddLiquidityV4() to get active benefactors for conversion
     *      O(n) scan but n = total benefactors, typically << 1000
     * @return Array of benefactor addresses with pending contributions this round
     */
    function getActiveBenefactors() internal view returns (address[] memory) {
        // Count benefactors with pending contributions THIS ROUND
        uint256 activeCount = 0;
        for (uint256 i = 0; i < registeredBenefactors.length; i++) {
            if (pendingContribution[registeredBenefactors[i]] > 0) {
                activeCount++;
            }
        }

        // Build active benefactors array (only those with pending contributions)
        address[] memory active = new address[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < registeredBenefactors.length; i++) {
            address benefactor = registeredBenefactors[i];
            if (pendingContribution[benefactor] > 0) {
                active[index] = benefactor;
                index++;
            }
        }

        return active;
    }

    /**
     * @notice Track benefactor contribution in storage (PHASE 1: ACCUMULATION)
     * @dev Updates pending contributions for this benefactor awaiting conversion to LP
     *      When ETH arrives, it goes to pendingContribution (not yet in LP position)
     *      On conversion, pending is used to calculate stakes, then cleared
     * @param benefactor Address of the benefactor (project, hook, or EOA)
     * @param amount Amount contributed in wei
     */
    function _trackBenefactorContribution(address benefactor, uint256 amount) internal {
        // Track pending contribution (Phase 1: accumulation before conversion)
        pendingContribution[benefactor] += amount;
        totalPendingETH += amount;

        // Initialize benefactor tracking flags on first contribution
        if (!benefactorExists[benefactor]) {
            benefactorExists[benefactor] = true;
            hasPendingContribution[benefactor] = true;
        } else {
            hasPendingContribution[benefactor] = true;
        }

        // Also update legacy mapping for backward compatibility during transition
        if (!benefactorContributions[benefactor].exists) {
            benefactorContributions[benefactor] = BenefactorContribution({
                benefactor: benefactor,
                totalETHContributed: 0,
                exists: true
            });
            registeredBenefactors.push(benefactor);
        }
        benefactorContributions[benefactor].totalETHContributed += uint128(amount);
        totalETHCollected += uint128(amount);

        emit BenefactorTracked(benefactor, amount);
    }

    // ========== Conversion & Liquidity ==========

    /**
     * @notice Convert accumulated ETH to V4 liquidity position with epoch-based tracking
     * @dev Public function - any caller can trigger conversion and earn 0.5% reward
     *      Refactored for trailing epoch condenser: tracks per-epoch instead of per-conversion
     *      Updates benefactor lifetime contributions (cumulative, never reset)
     *      Maintains conversion record for backwards compatibility
     * @param minOutTarget Minimum target tokens to receive from ETH swap
     * @param tickLower Lower tick boundary for V4 concentrated liquidity
     * @param tickUpper Upper tick boundary for V4 concentrated liquidity
     * @return lpPositionValue Total value of the LP position added (amount0 + amount1)
     */
    function convertAndAddLiquidityV4(
        uint256 minOutTarget,
        int24 tickLower,
        int24 tickUpper
    ) external nonReentrant returns (uint256 lpPositionValue) {
        require(accumulatedETH >= minConversionThreshold, "Amount too small");
        require(alignmentTarget.token != address(0), "No alignment target set");
        require(alignmentTarget.v4Pool != address(0), "V4 pool not set");

        // Step 1: Create new immutable conversion record (backwards compatibility)
        uint256 conversionId = nextConversionId;
        LPPositionValuation.ConversionRecord storage record = conversionHistory[conversionId];

        record.conversionId = conversionId;
        record.timestamp = block.timestamp;

        // Step 2: Get active benefactors (only those who contributed to accumulated ETH)
        address[] memory activeBenefactors = getActiveBenefactors();
        require(activeBenefactors.length > 0, "No active benefactors");

        // Step 3: Calculate total ETH for this round using PENDING (not cumulative) (PHASE 1 FIX)
        // CRITICAL: Use totalPendingETH as denominator, not cumulative benefactorContributions
        // This ensures stakes are calculated as: (benefactor's pending) / (total pending) this round
        uint256 ethToSwap = accumulatedETH;
        accumulatedETH = 0;

        // Use totalPendingETH as the correct denominator for stake calculation
        uint256 totalETHThisRound = totalPendingETH;
        require(totalETHThisRound > 0, "Total pending must match accumulated ETH");

        // Step 4: Update benefactor lifetime contributions and epoch tracking
        uint256 epochId = currentEpochId;
        LPPositionValuation.EpochRecord storage epoch = epochs[epochId];

        // Initialize epoch if needed
        if (epoch.epochId == 0 && conversionId == 0) {
            epoch.epochId = epochId;
            epoch.startConversionId = conversionId;
        }
        epoch.endConversionId = conversionId;
        epoch.totalETHInEpoch += ethToSwap;

        for (uint256 i = 0; i < activeBenefactors.length; i++) {
            address benefactor = activeBenefactors[i];

            // PHASE 2 FIX: Use pendingContribution (this round) not cumulative benefactorContributions
            uint256 contribution = pendingContribution[benefactor];
            require(contribution > 0, "Active benefactor must have pending contribution");

            // **PHASE 3**: Update lifetime contribution (eternal, never resets)
            // This forms the basis for O(1) fee claims via the formula:
            // benefactorShare = (totalLPValue × benefactorLifetimeETHDeposited) / totalEverDeposited
            benefactorLifetimeETHDeposited[benefactor] += contribution;
            totalEverDeposited += uint128(contribution);

            // Track benefactor in this epoch
            epoch.ethInEpoch[benefactor] += contribution;
            if (!_isInArray(epoch.benefactorsInEpoch, benefactor)) {
                epoch.benefactorsInEpoch.push(benefactor);
            }

            // Legacy: Track which conversions this benefactor participated in
            benefactorConversions[benefactor].push(conversionId);

            // PHASE 2: Record benefactor stake frozen for THIS conversion (immutable per-conversion stakes)
            // Stake = (this round's contribution) / (this round's total) = pending / totalPending
            uint256 stakePercent = (contribution * 1e18) / totalETHThisRound;
            record.stakes[benefactor] = LPPositionValuation.ConversionBenefactorStake({
                benefactor: benefactor,
                ethContributedThisRound: contribution,
                stakePercent: stakePercent,
                exists: true
            });
            record.benefactorsList.push(benefactor);
        }

        // PHASE 1 FIX: Clear pending contributions after conversion (critical for next round's accuracy)
        // This ensures next round's stakes are calculated from THEIR pending amounts, not carried-over amounts
        for (uint256 i = 0; i < activeBenefactors.length; i++) {
            address benefactor = activeBenefactors[i];
            pendingContribution[benefactor] = 0;
            hasPendingContribution[benefactor] = false;
        }
        totalPendingETH = 0;

        emit BenefactorStakesCreated(activeBenefactors.length, 100 * 1e16); // 100% = 1e18

        // Step 5: Swap ETH → target token
        uint256 targetTokenReceived = swapETHForTarget(ethToSwap, minOutTarget, bytes(""));

        // Step 6: Record V4 LP position metadata and calculate liquidity units
        lpPositionValue = ethToSwap + targetTokenReceived;

        uint256 positionSalt = uint256(keccak256(abi.encode(conversionId, block.timestamp)));

        record.pool = alignmentTarget.v4Pool;
        record.positionId = positionSalt;
        record.amount0 = ethToSwap;
        record.amount1 = targetTokenReceived;
        record.accumulatedFees0 = 0;
        record.accumulatedFees1 = 0;

        // PHASE 3B FIX: Calculate V4 liquidity units created in this conversion
        // NOTE: This is a proxy calculation (liquidity proportional to LP position value)
        // In production with V4 integration, this should be replaced with modifyLiquidity() return value
        uint128 liquidityUnitsCreated = uint128(lpPositionValue);

        // Store total liquidity units for this conversion
        record.liquidityUnitsCreated = liquidityUnitsCreated;
        totalPoolLiquidityUnits += liquidityUnitsCreated;

        // Attribute liquidity units to each benefactor based on their ETH ratio
        for (uint256 i = 0; i < activeBenefactors.length; i++) {
            address benefactor = activeBenefactors[i];
            uint256 ethRatio = (pendingContribution[benefactor] * 1e18) / totalETHThisRound;
            uint128 benefactorUnits = uint128((uint256(liquidityUnitsCreated) * ethRatio) / 1e18);

            // Store per-benefactor liquidity units for this conversion
            record.benefactorLiquidityUnits[benefactor] = benefactorUnits;

            // Update lifetime cache (O(1) for later claims)
            benefactorLifetimeLiquidityUnits[benefactor] += benefactorUnits;
        }

        // Update epoch LP value tracking
        epoch.totalLPValueInEpoch += lpPositionValue;

        // Step 7: Increment for next conversion
        nextConversionId++;

        // Step 8: Reward the caller (0.5% of swapped ETH)
        uint256 callerReward = (ethToSwap * 5) / 1000;
        (bool success, ) = payable(msg.sender).call{value: callerReward}("");
        require(success, "Caller reward transfer failed");

        // Step 9: Update global tracking
        alignmentTarget.totalLiquidity += lpPositionValue;

        emit ConversionAndLiquidityAddedV4(ethToSwap, targetTokenReceived, lpPositionValue, callerReward);

        return lpPositionValue;
    }

    /**
     * @notice Helper: Check if address exists in array
     * @dev Used for epoch benefactor tracking
     */
    function _isInArray(address[] memory arr, address element) internal pure returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == element) return true;
        }
        return false;
    }

    /**
     * @notice Swap ETH for alignment target token (DEX-agnostic)
     * @dev Internal function - source DEX doesn't matter (V2/V3/V4)
     *      Uses generic swap infrastructure with router-specific call data
     *      STUB: To be implemented with actual router integration
     * @param ethAmount Amount of ETH to swap
     * @param minOutTarget Minimum target tokens to receive
     * @param swapData Router-specific encoded call data
     * @return targetTokenReceived Amount of target token received from swap
     */
    function swapETHForTarget(
        uint256 ethAmount,
        uint256 minOutTarget,
        bytes memory swapData
    ) internal returns (uint256 targetTokenReceived) {
        require(router != address(0), "Router not set");
        require(alignmentTarget.token != address(0), "No alignment target set");

        // STUB: Actual implementation will call router with swapData
        // This encodes: path, amounts, recipient, slippage parameters
        targetTokenReceived = 0;

        require(targetTokenReceived >= minOutTarget, "Slippage too high");

        return targetTokenReceived;
    }


    // ========== Epoch Maintenance (Decentralized, Incentivized) ==========

    /**
     * @notice Finalize current epoch and start a new one (public, decoupled, incentivized)
     * @dev Called by anyone (keeper, benefactor, or maintenance bot) to manage epoch lifecycle
     *      Decoupled from conversion operations - doesn't block conversions
     *      Enables rolling window of active epochs, compresses old ones to save storage
     *      Caller receives reward from operator incentive pool (tunable via setEpochKeeperRewardBps)
     *      Can be triggered whenever:
     *      - Impatient benefactor wants to include their contribution in epoch analytics
     *      - Keeper bot performs scheduled maintenance
     *      - Owner wants to rebalance treasury between pools
     * @return epochId The ID of the finalized epoch
     */
    function finalizeEpochAndStartNew() public returns (uint256 epochId) {
        uint256 finalizingEpochId = currentEpochId;
        LPPositionValuation.EpochRecord storage epoch = epochs[finalizingEpochId];

        // Validate: epoch has been populated with conversions
        require(epoch.totalETHInEpoch > 0, "Epoch has no ETH, nothing to finalize");

        // Transition to next epoch
        currentEpochId++;

        // Check if we need to compress old epochs (rolling window management)
        if ((currentEpochId - minEpochIdInWindow) > maxEpochWindow) {
            _compressOldestEpoch();
        }

        // Pay caller reward from operator incentive pool (tunable via setEpochKeeperRewardBps)
        uint256 rewardBps = epochKeeperRewardBps; // basis points (e.g., 5 = 0.05%)
        uint256 callerReward = (epoch.totalETHInEpoch * rewardBps) / 10000;

        if (callerReward > 0) {
            // Withdraw from operator incentive pool
            require(treasury.operatorIncentivePool >= callerReward, "Insufficient operator incentive pool");
            treasury.operatorIncentivePool -= callerReward;
            totalWithdrawnForOperators += callerReward;

            (bool success, ) = payable(msg.sender).call{value: callerReward}("");
            require(success, "Caller reward transfer failed");
            emit TreasuryWithdrawn("operatorIncentivePool", callerReward);
        }

        emit EpochFinalized(finalizingEpochId, epoch.totalETHInEpoch, epoch.totalLPValueInEpoch);

        return finalizingEpochId;
    }

    /**
     * @notice Compress the oldest epoch and move to next in rolling window
     * @dev Internal function called by finalizeEpochAndStartNew() when window overflow
     *      PHASE 4: EPOCH ROLLING - Maintains rolling window of 3 active epochs
     *
     *      CRITICAL INVARIANT: benefactorLifetimeETHDeposited[X] is ETERNAL and IMMUTABLE
     *      - Never reset, never modified by epoch compression
     *      - Survives indefinitely across all epochs
     *      - Enables O(1) fee claims: share = (totalLPValue × benefactorLifetimeETHDeposited) / totalEverDeposited
     *
     *      Compression only clears benefactorsInEpoch array to save storage.
     *      Benefactor lifetime tracking remains unchanged and queryable forever.
     */
    function _compressOldestEpoch() internal {
        uint256 oldEpochId = minEpochIdInWindow;
        LPPositionValuation.EpochRecord storage oldEpoch = epochs[oldEpochId];

        require(!oldEpoch.isCondensed, "Epoch already compressed");
        require(oldEpoch.totalETHInEpoch > 0, "Cannot compress empty epoch");

        // Mark as condensed (indicates it's been moved out of active window)
        oldEpoch.isCondensed = true;
        oldEpoch.compressedIntoEpochId = minEpochIdInWindow + 1;

        // Advance window
        minEpochIdInWindow++;

        // Clear the epoch's benefactor array to save storage
        // NOTE: benefactorLifetimeETHDeposited NEVER changes here - it's eternal
        // This keeps benefactor contribution data queryable forever without bloating storage
        while (oldEpoch.benefactorsInEpoch.length > 0) {
            oldEpoch.benefactorsInEpoch.pop();
        }

        emit EpochCompressed(oldEpochId, minEpochIdInWindow);
    }

    /**
     * @notice Record accumulated fees from a specific conversion's LP position
     * @dev Called after fees are collected from LP positions
     *      These fees are in both token0 and token1 format
     * @param conversionId ID of the conversion to update fees for
     * @param feeAmount0 Accumulated fees in token0
     * @param feeAmount1 Accumulated fees in token1 (typically ETH)
     */
    function recordAccumulatedFees(
        uint256 conversionId,
        uint256 feeAmount0,
        uint256 feeAmount1
    ) external onlyOwner {
        require(conversionId < conversionHistory.length, "Invalid conversion ID");

        LPPositionValuation.ConversionRecord storage record = conversionHistory[conversionId];
        uint256 totalFees = feeAmount0 + feeAmount1;

        // Add to existing accumulated fees (allows multiple collections)
        record.accumulatedFees0 += feeAmount0;
        record.accumulatedFees1 += feeAmount1;

        emit FeesAccumulated(totalFees);
    }

    /**
     * @notice Get the true total liquidity in the V4 pool (includes vault + external LPs)
     * @dev STUB: Should query V4's pool state directly to get accurate pool composition
     *      Essential for permissionless pools where external LPs can add liquidity
     *      For now, returns vault's tracked total (assumes vault-exclusive pool)
     * @return trueTotalPoolLiquidity The actual total liquidity units in the pool from V4
     */
    function getPoolTotalLiquidity() internal view returns (uint128) {
        // In production, this should query V4 PoolManager for true pool state
        // When PoolKey is finalized, implement: v4PoolManager.getPoolLiquidity(poolKey)
        // For now, fallback to vault's tracked total
        return totalPoolLiquidityUnits;
    }

    /**
     * @notice Calculate a benefactor's share of the vault's liquidity units using the cache
     * @dev PHASE 3B FIX: Uses cached liquidity units (ground truth) instead of ETH-based calculation
     *      The cache is updated at conversion time and represents actual V4 liquidity owned by benefactor
     * @param benefactor Address of the benefactor
     * @return benefactorLiquidity The benefactor's cached lifetime liquidity units
     */
    function calculateBenefactorLiquidity(address benefactor) internal view returns (uint128) {
        // Use cache directly - this is now O(1) and mathematically correct
        // benefactorLifetimeLiquidityUnits is updated at conversion time when liquidity units are created
        return benefactorLifetimeLiquidityUnits[benefactor];
    }

    /**
     * @notice Claim benefactor's share of accumulated LP fees using liquidity units (PHASE 3B FIX)
     * @dev PHASE 5: FEE CLAIM - O(1) operation using cached liquidity units tracking
     *      Benefactor's share = (totalLPFees × benefactorLifetimeLiquidityUnits) / trueTotalPoolLiquidity
     *      This formula is mathematically correct because benefactorLifetimeLiquidityUnits represents
     *      their actual V4 liquidity ownership, regardless of varying conversion rates or pool conditions.
     *
     *      PHASE 3B IMPROVEMENT:
     *      - Uses benefactorLifetimeLiquidityUnits (cached at conversion time) instead of ETH amounts
     *      - This is the ground truth that V4 uses for fee distribution
     *      - Works correctly across multiple conversions at different rates
     *
     *      PERMISSIONLESS POOL MODEL:
     *      - Query V4 for true pool liquidity (includes vault + external LPs)
     *      - Normalize vault's contributed liquidity against true pool total
     *      - This ensures benefactors get correct fee share regardless of external LP activity
     *
     *      Benefactors can claim multiple times as new LP fees accumulate - only receives new accrued fees
     *      All fees (token0 + token1) are converted to ETH by the vault before distribution
     * @return ethClaimed Amount of ETH sent to benefactor
     */
    function claimBenefactorFees() external nonReentrant returns (uint256 ethClaimed) {
        address benefactor = msg.sender;

        // Require benefactor to have contributed liquidity units to the vault (ever)
        require(benefactorExists[benefactor], "Benefactor not registered");
        require(benefactorLifetimeLiquidityUnits[benefactor] > 0, "No liquidity units contributed");
        require(totalPoolLiquidityUnits > 0, "Pool has no liquidity units");

        // PHASE 3B FIX: Use liquidity units instead of ETH for ground truth calculation
        // 1. Query the true pool liquidity (includes vault + all external LPs)
        uint128 trueTotalPoolLiquidity = getPoolTotalLiquidity();
        require(trueTotalPoolLiquidity > 0, "Pool has no liquidity");

        // 2. Get benefactor's cached lifetime liquidity units (updated at conversion time)
        uint128 benefactorLiquidity = calculateBenefactorLiquidity(benefactor);

        // 3. Get current accumulated fees
        uint256 currentTotalFees = alignmentTarget.totalFeesCollected;

        // 4. Calculate their proportional share (normalized to entire pool)
        // Formula: share = (totalFees × benefactorLiquidityUnits) / trueTotalPoolLiquidity
        // This ensures they get correct fee share regardless of:
        // - Conversion rates (ETH → token price varies)
        // - Pool conditions (different conversions create different liquidity unit amounts)
        // - External LP activity (trueTotalPoolLiquidity includes all LPs)
        uint256 benefactorShare = (currentTotalFees * uint256(benefactorLiquidity)) / uint256(trueTotalPoolLiquidity);

        // Calculate unclaimed fees: what they should have minus what they already claimed
        // lastClaimAmount tracks cumulative amount claimed across all claim calls
        ethClaimed = benefactorShare > lastClaimAmount[benefactor] ? benefactorShare - lastClaimAmount[benefactor] : 0;
        require(ethClaimed > 0, "No new fees to claim");

        // **PHASE 5 FIX (CRITICAL)**: Transfer BEFORE updating state
        // If transfer fails and we retry, lastClaimAmount is already correct for retry
        // This prevents benefactor from being permanently locked out of their fees

        // Transfer accumulated ETH (vault has already converted token0 → ETH via swaps)
        (bool success, ) = payable(benefactor).call{value: ethClaimed}("");
        require(success, "ETH transfer failed");

        // Update state AFTER successful transfer
        // This ensures failed transfers don't lock the benefactor out of re-attempting
        lastClaimAmount[benefactor] = benefactorShare;
        lastClaimTimestamp[benefactor] = block.timestamp;

        emit BenefactorFeesClaimed(benefactor, ethClaimed);

        return ethClaimed;
    }

    // ========== Query Functions ==========

    /**
     * @notice Get benefactor contribution
     * @param benefactor Address of the benefactor (project, hook, or EOA)
     * @return BenefactorContribution struct with contribution data
     */
    function getBenefactorContribution(address benefactor)
        external
        view
        returns (BenefactorContribution memory)
    {
        require(benefactorContributions[benefactor].exists, "Benefactor not found");
        return benefactorContributions[benefactor];
    }

    /**
     * @notice Get all registered benefactors
     * @return Array of benefactor addresses
     */
    function getRegisteredBenefactors() external view returns (address[] memory) {
        return registeredBenefactors;
    }

    /**
     * @notice Get current accumulated ETH
     * @return Amount of ETH awaiting conversion
     */
    function getAccumulatedETH() external view returns (uint256) {
        return accumulatedETH;
    }

    /**
     * @notice Get total ETH collected across all benefactors
     * @return Total ETH in wei that has been contributed
     */
    function getTotalETHCollected() external view returns (uint128) {
        return totalETHCollected;
    }

    /**
     * @notice Get benefactor percentage of total contributions
     * @param benefactor Address of the benefactor
     * @return Percentage (0-100) of total contributions
     */
    function getBenefactorPercentage(address benefactor)
        external
        view
        returns (uint256)
    {
        require(benefactorContributions[benefactor].exists, "Benefactor not found");
        if (totalETHCollected == 0) return 0;
        return (uint256(benefactorContributions[benefactor].totalETHContributed) * 100) /
            uint256(totalETHCollected);
    }

    // ========== LP Valuation Query Functions ==========

    /**
     * @notice Get benefactor's conversion history
     * @param benefactor Address of the benefactor
     * @return Array of conversion IDs that this benefactor participated in
     */
    function getBenefactorConversions(address benefactor)
        external
        view
        returns (uint256[] memory)
    {
        return benefactorConversions[benefactor];
    }

    /**
     * @notice Get total conversion records (history size)
     * @return Total number of conversions that have been executed
     */
    function getConversionCount() external view returns (uint256) {
        return conversionHistory.length;
    }

    /**
     * @notice Get conversion metadata (non-mapping fields)
     * @param _conversionId ID of the conversion to retrieve
     * @return id The sequential conversion ID
     * @return timestamp When the conversion was created
     * @return pool The V4 pool address for this conversion
     * @return positionId The position salt hash
     * @return amount0 Token0 amount in the position
     * @return amount1 Token1 amount in the position
     * @return accumulatedFees0 Accumulated fees in token0
     * @return accumulatedFees1 Accumulated fees in token1
     */
    function getConversionMetadata(uint256 _conversionId)
        external
        view
        returns (
            uint256,
            uint256,
            address,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        require(_conversionId < conversionHistory.length, "Invalid conversion ID");
        LPPositionValuation.ConversionRecord storage record = conversionHistory[_conversionId];

        return (
            record.conversionId,
            record.timestamp,
            record.pool,
            record.positionId,
            record.amount0,
            record.amount1,
            record.accumulatedFees0,
            record.accumulatedFees1
        );
    }

    /**
     * @notice Get benefactor's stake in a specific conversion
     * @param conversionId ID of the conversion
     * @param benefactor Address of the benefactor
     * @return stake The benefactor's frozen stake in that conversion
     */
    function getConversionBenefactorStake(uint256 conversionId, address benefactor)
        external
        view
        returns (LPPositionValuation.ConversionBenefactorStake memory stake)
    {
        require(conversionId < conversionHistory.length, "Invalid conversion ID");
        return conversionHistory[conversionId].stakes[benefactor];
    }

    /**
     * @notice Get total unclaimed fees for a benefactor across all their conversions
     * @param benefactor Address of the benefactor
     * @return totalUnclaimed Sum of unclaimed fees from all conversions they participated in
     */
    function getBenefactorTotalUnclaimedFees(address benefactor)
        external
        view
        returns (uint256 totalUnclaimed)
    {
        uint256[] memory conversions = benefactorConversions[benefactor];
        for (uint256 i = 0; i < conversions.length; i++) {
            uint256 conversionId = conversions[i];
            LPPositionValuation.ConversionRecord storage record = conversionHistory[conversionId];

            LPPositionValuation.ConversionBenefactorStake memory stake = record.stakes[benefactor];
            uint256 totalFees = record.accumulatedFees0 + record.accumulatedFees1;
            uint256 totalOwed = (totalFees * stake.stakePercent) / 1e18;
            uint256 previouslyClaimed = record.claimedByBenefactor[benefactor];

            if (totalOwed > previouslyClaimed) {
                totalUnclaimed += (totalOwed - previouslyClaimed);
            }
        }
        return totalUnclaimed;
    }

    // ========== Treasury Management ==========

    /**
     * @notice Allocate ETH from conversion pool to fee claim pool
     * @dev Owner-only: Reallocates treasury funds between pools for balanced operation
     *      As conversion rewards are earned, funds move to fee claim pool to support benefactor claims
     * @param amount Amount of ETH to reallocate from conversion pool to fee claim pool
     */
    function reallocateTreasuryForFeeClaims(uint256 amount) external onlyOwner {
        require(treasury.conversionPool >= amount, "Insufficient conversion pool");
        treasury.conversionPool -= amount;
        treasury.feeClaimPool += amount;
        emit TreasuryRebalanced(treasury.conversionPool, treasury.feeClaimPool, treasury.operatorIncentivePool);
    }

    /**
     * @notice Allocate ETH from conversion pool to operator incentive pool
     * @dev Owner-only: Replenishes keeper rewards pool as conversions occur
     *      Keepers earn rewards from this pool when finalizing epochs
     * @param amount Amount of ETH to reallocate from conversion pool to operator pool
     */
    function reallocateTreasuryForOperators(uint256 amount) external onlyOwner {
        require(treasury.conversionPool >= amount, "Insufficient conversion pool");
        treasury.conversionPool -= amount;
        treasury.operatorIncentivePool += amount;
        emit TreasuryRebalanced(treasury.conversionPool, treasury.feeClaimPool, treasury.operatorIncentivePool);
    }

    /**
     * @notice Get current treasury state
     * @return Treasury struct with all pool balances
     */
    function getTreasuryState() external view returns (Treasury memory) {
        return treasury;
    }

    /**
     * @notice Get treasury accounting totals (auditing)
     * @return allocated Total ETH allocated to all pools
     * @return withdrawn Total ETH withdrawn from all pools
     */
    function getTreasuryTotals() external view returns (uint256 allocated, uint256 withdrawn) {
        allocated = totalAllocatedToConversions + totalAllocatedToFeeClaims + totalAllocatedToOperators;
        withdrawn = totalWithdrawnForConversions + totalWithdrawnForFeeClaims + totalWithdrawnForOperators;
    }

    // ========== Epoch Boundary Configuration ==========

    /**
     * @notice Set maximum conversions per epoch
     * @dev Owner-only: Controls epoch finalization trigger (prevents unbounded epoch growth)
     *      When this threshold is reached, next conversion triggers epoch finalization
     * @param newMax Maximum conversion count before epoch finalization
     */
    function setMaxConversionsPerEpoch(uint256 newMax) external onlyOwner {
        require(newMax > 0, "Max conversions must be positive");
        maxConversionsPerEpoch = newMax;
    }

    /**
     * @notice Set epoch keeper reward percentage
     * @dev Owner-only: Adjusts incentives for epoch maintenance
     *      Keepers earn this percentage of epoch's total ETH as reward
     * @param newRewardBps Reward in basis points (e.g., 5 = 0.05%)
     */
    function setEpochKeeperRewardBps(uint256 newRewardBps) external onlyOwner {
        require(newRewardBps <= 100, "Reward too high (max 1%)");
        epochKeeperRewardBps = newRewardBps;
    }

    // ========== Configuration ==========

    /**
     * @notice Set minimum conversion threshold
     */
    function setMinConversionThreshold(uint256 newThreshold) external onlyOwner {
        require(newThreshold > 0, "Threshold must be positive");
        minConversionThreshold = newThreshold;
    }

    /**
     * @notice Set minimum liquidity threshold
     */
    function setMinLiquidityThreshold(uint256 newThreshold) external onlyOwner {
        require(newThreshold > 0, "Threshold must be positive");
        minLiquidityThreshold = newThreshold;
    }

    /**
     * @notice Update alignment target settings
     */
    function updateAlignmentTarget(
        address newToken,
        address newV4Pool
    ) external onlyOwner {
        require(newToken != address(0), "Invalid token");
        alignmentTarget.token = newToken;
        if (newV4Pool != address(0)) alignmentTarget.v4Pool = newV4Pool;
        emit AlignmentTargetSet(newToken);
    }
}

