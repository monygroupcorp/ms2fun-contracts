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
 * - Plug in beneficiary module for Phase 2 fee distribution
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

    struct LiquidityPosition {
        bool isV3;
        uint256 positionId; // NFT ID for V3, salt for V4
        address pool;
        uint256 liquidity;
        uint256 feesAccumulated;
        uint256 lastFeeCollection;
    }

    struct AlignmentTarget {
        address token; // Alignment target token (e.g., CULT)
        address v3Pool; // Existing V3 pool address
        address v4Pool; // V4 pool address (if created)
        address weth; // WETH address
        uint256 totalLiquidity;
        uint256 totalFeesCollected;
    }

    // ========== State Variables ==========

    AlignmentTarget public alignmentTarget;

    // Hook management (vault is master of exactly 1 canonical hook)
    address public canonicalHook;
    address public immutable hookFactory;
    address public immutable weth;

    // Benefactor tracking
    mapping(address => BenefactorContribution) public benefactorContributions;
    address[] public registeredBenefactors;

    // Liquidity positions
    LiquidityPosition[] public liquidityPositions;
    mapping(uint256 => uint256) public v3PositionToIndex;
    mapping(bytes32 => uint256) public v4PositionToIndex;

    // LP Position Valuation (Phase 2)
    mapping(address => LPPositionValuation.BenefactorStake) public benefactorStakes;
    LPPositionValuation.BenefactorStake[] public allBenefactorStakes;
    LPPositionValuation.LPPositionMetadata public currentLPPosition;

    // Fee accumulation
    uint256 public accumulatedETH;
    uint256 public accumulatedFees; // Total fees from LP positions
    uint128 public totalETHCollected; // Total across all benefactors

    // Thresholds
    uint256 public minConversionThreshold = 0.01 ether;
    uint256 public minLiquidityThreshold = 0.005 ether;

    // External contracts
    address public v3PositionManager;
    IPoolManager public v4PoolManager;
    address public router;

    // ========== Phase 2 Extension Point ==========
    // This is where beneficiary distribution will plug in
    address public beneficiaryModule;

    // ========== Events ==========

    event BenefactorContributionReceived(address indexed benefactor, uint256 amount, bool isERC404Tax);
    event AlignmentTargetSet(address indexed token, address v3Pool);
    event AlignmentTargetConverted(uint256 ethAmount, uint256 targetAmount, uint256 liquidity);
    event BenefactorTracked(address indexed benefactor, uint256 ethAmount);
    event LiquidityPositionAdded(bool isV3, uint256 positionId, address pool, uint256 liquidity);
    event FeesCollected(uint256 positionIndex, uint256 amount0, uint256 amount1);
    event BeneficiaryModuleSet(address indexed newModule);
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

    // ========== Constructor ==========

    constructor(
        address _alignmentTarget,
        address _v3Pool,
        address _weth,
        address _v3PositionManager,
        address _v4PoolManager,
        address _router,
        address _hookFactory
    ) {
        _initializeOwner(msg.sender);

        require(_alignmentTarget != address(0), "Invalid target");
        require(_weth != address(0), "Invalid WETH");
        require(_v3PositionManager != address(0), "Invalid V3 PM");
        require(_v4PoolManager != address(0), "Invalid V4 PM");
        require(_router != address(0), "Invalid router");
        require(_hookFactory != address(0), "Invalid hook factory");

        // Initialize immutables
        weth = _weth;
        hookFactory = _hookFactory;

        alignmentTarget = AlignmentTarget({
            token: _alignmentTarget,
            v3Pool: _v3Pool,
            v4Pool: address(0),
            weth: _weth,
            totalLiquidity: 0,
            totalFeesCollected: 0
        });

        v3PositionManager = _v3PositionManager;
        v4PoolManager = IPoolManager(_v4PoolManager);
        router = _router;

        // Create canonical hook at deployment (OPTIONAL - can fail gracefully)
        _createCanonicalHook(_v4PoolManager);
    }

    // ========== Fee Reception ==========

    /**
     * @notice Receive ERC404 swap taxes from hooks
     * @dev Open function accepting ETH from any source
     * @param currency Currency of the tax (ETH or token)
     * @param amount Amount of tax received
     * @param benefactor Address of the benefactor/project that generated the tax
     */
    function receiveERC404Tax(
        Currency currency,
        uint256 amount,
        address benefactor
    ) external nonReentrant {
        require(amount > 0, "Amount must be positive");
        require(benefactor != address(0), "Invalid benefactor");

        // Accumulate ETH
        accumulatedETH += amount;

        // Track benefactor contribution in storage
        _trackBenefactorContribution(benefactor, amount);

        // Notify beneficiary module if set (Phase 2)
        if (beneficiaryModule != address(0)) {
            try IBeneficiary(beneficiaryModule).onFeeAccumulated(amount) {} catch {}
        }

        emit BenefactorContributionReceived(benefactor, amount, true);
    }

    /**
     * @notice Receive ERC1155 creator tithes
     * @dev Open function accepting ETH from any source
     * @param benefactor Address of the benefactor/project
     */
    function receiveERC1155Tithe(address benefactor) external payable nonReentrant {
        require(msg.value > 0, "Amount must be positive");
        require(benefactor != address(0), "Invalid benefactor");

        // Accumulate ETH
        accumulatedETH += msg.value;

        // Track benefactor contribution in storage
        _trackBenefactorContribution(benefactor, msg.value);

        // Notify beneficiary module if set (Phase 2)
        if (beneficiaryModule != address(0)) {
            try IBeneficiary(beneficiaryModule).onFeeAccumulated(msg.value) {} catch {}
        }

        emit BenefactorContributionReceived(benefactor, msg.value, false);
    }

    /**
     * @notice Accept direct ETH contributions from any address
     * @dev Enables EOAs and other contracts to contribute directly to the vault
     *      Tracks msg.sender as the benefactor
     */
    receive() external payable nonReentrant {
        require(msg.value > 0, "Amount must be positive");

        // Accumulate ETH
        accumulatedETH += msg.value;

        // Track sender as benefactor
        _trackBenefactorContribution(msg.sender, msg.value);

        // Notify beneficiary module if set (Phase 2)
        if (beneficiaryModule != address(0)) {
            try IBeneficiary(beneficiaryModule).onFeeAccumulated(msg.value) {} catch {}
        }

        emit BenefactorContributionReceived(msg.sender, msg.value, false);
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
     * @notice Track benefactor contribution in storage
     * @dev Stores contribution data for analytics and staking distribution (Phase 2)
     * @param benefactor Address of the benefactor (project, hook, or EOA)
     * @param amount Amount contributed in wei
     */
    function _trackBenefactorContribution(address benefactor, uint256 amount) internal {
        // Initialize benefactor record if not exists
        if (!benefactorContributions[benefactor].exists) {
            benefactorContributions[benefactor] = BenefactorContribution({
                benefactor: benefactor,
                totalETHContributed: 0,
                exists: true
            });
            registeredBenefactors.push(benefactor);
        }

        // Update storage with new contribution amount
        benefactorContributions[benefactor].totalETHContributed += uint128(amount);
        totalETHCollected += uint128(amount);

        emit BenefactorTracked(benefactor, amount);
    }

    // ========== Conversion & Liquidity ==========

    /**
     * @notice Convert accumulated ETH to V4 liquidity position and create benefactor stakes
     * @dev Public function - any caller can trigger conversion and earn 0.5% reward
     *      This creates frozen stakes for benefactors based on current ETH contributions
     * @param minOut Minimum target tokens to receive from swap
     * @param tickLower Lower tick boundary for V4 concentrated liquidity
     * @param tickUpper Upper tick boundary for V4 concentrated liquidity
     * @return lpPositionValue Total value of the LP position added (amount0 + amount1)
     */
    function convertAndAddLiquidityV4(
        uint256 minOut,
        int24 tickLower,
        int24 tickUpper
    ) external nonReentrant returns (uint256 lpPositionValue) {
        require(accumulatedETH >= minConversionThreshold, "Amount too small");
        require(alignmentTarget.token != address(0), "No alignment target set");

        // Step 1: Take snapshot of current benefactor contributions
        address[] memory benefactorsList = new address[](registeredBenefactors.length);
        uint256[] memory contributions = new uint256[](registeredBenefactors.length);

        for (uint256 i = 0; i < registeredBenefactors.length; i++) {
            benefactorsList[i] = registeredBenefactors[i];
            contributions[i] = benefactorContributions[benefactorsList[i]].totalETHContributed;
        }

        // Step 2: Create benefactor stakes (frozen at conversion time)
        uint256 ethToSwap = accumulatedETH;
        accumulatedETH = 0;

        LPPositionValuation.createStakesFromETH(
            benefactorStakes,
            allBenefactorStakes,
            benefactorsList,
            contributions
        );

        emit BenefactorStakesCreated(benefactorsList.length, 100 * 1e16); // 100% = 1e18

        // Step 3: Swap ETH → target token (TODO: implement swap through router)
        // For now, this is a placeholder that would call the vault's swap infrastructure
        uint256 targetTokenReceived = 0; // TODO: actual swap

        // Step 4: Record LP position metadata in library state
        // Value = amount0 + amount1 (for simple tracking)
        lpPositionValue = ethToSwap; // Simplified: assume 1:1 value for now

        LPPositionValuation.recordLPPosition(
            currentLPPosition,
            0, // poolType = V4
            alignmentTarget.v4Pool,
            0, // positionId (will be assigned by V4 pool)
            address(0), // no lpTokenAddress for V4
            ethToSwap, // amount0 placeholder
            targetTokenReceived // amount1 placeholder
        );

        // Step 5: Reward the caller (0.5% of swapped ETH)
        uint256 callerReward = (ethToSwap * 5) / 1000;
        (bool success, ) = payable(msg.sender).call{value: callerReward}("");
        require(success, "Caller reward transfer failed");

        // Step 6: Update tracking
        alignmentTarget.totalLiquidity += lpPositionValue;

        emit ConversionAndLiquidityAddedV4(ethToSwap, targetTokenReceived, lpPositionValue, callerReward);

        return lpPositionValue;
    }

    /**
     * @notice Record accumulated fees from LP position
     * @dev Called after fees are collected from LP positions
     *      These fees are in both token0 and token1 format
     * @param feeAmount0 Accumulated fees in token0
     * @param feeAmount1 Accumulated fees in token1 (typically ETH)
     */
    function recordAccumulatedFees(uint256 feeAmount0, uint256 feeAmount1) external onlyOwner {
        uint256 totalFees = feeAmount0 + feeAmount1;
        accumulatedFees += totalFees;

        // Update position metadata
        LPPositionValuation.updateAccumulatedFees(currentLPPosition, feeAmount0, feeAmount1);

        emit FeesAccumulated(totalFees);
    }

    /**
     * @notice Claim benefactor's share of accumulated fees
     * @dev Benefactor calls this to withdraw their proportional share
     *      Vault automatically converts token0 fees to ETH and sends pure ETH to benefactor
     *      Uses the same swap infrastructure as LP conversions (optimistic model)
     * @return ethAmount Amount of ETH sent to benefactor
     */
    function claimBenefactorFees() external nonReentrant returns (uint256 ethAmount) {
        address benefactor = msg.sender;
        require(
            LPPositionValuation.hasStake(benefactorStakes, benefactor),
            "No stake found for benefactor"
        );

        // Calculate unclaimed fee share for this benefactor
        uint256 unclaimedFees = LPPositionValuation.calculateUnclaimedFees(
            benefactorStakes,
            benefactor,
            accumulatedFees
        );
        require(unclaimedFees > 0, "No unclaimed fees");

        // Record that benefactor has claimed these fees
        LPPositionValuation.recordFeeClaim(benefactorStakes, benefactor, unclaimedFees);

        // Calculate fee breakdown: what portion is token0 vs token1?
        // For now, assume fees are split proportionally based on position composition
        LPPositionValuation.LPPositionMetadata memory position = LPPositionValuation.getLPPosition(
            currentLPPosition
        );

        uint256 positionValue = position.amount0 + position.amount1;
        require(positionValue > 0, "Position has no value");

        // Calculate proportional split
        uint256 token0Portion = (unclaimedFees * position.accumulatedFees0) /
            (position.accumulatedFees0 + position.accumulatedFees1);
        uint256 token1Portion = unclaimedFees - token0Portion;

        // ETH equivalent: token1 is already ETH (or primary token)
        // token0 needs to be sold for ETH (handled optimistically by vault's swap infrastructure)
        // For now, return token1 portion as ETH directly
        ethAmount = token1Portion;

        // TODO: Implement token0 → ETH swap using vault's swap infrastructure
        // This would happen asynchronously after benefactor claims

        // Transfer ETH to benefactor
        (bool success, ) = payable(benefactor).call{value: ethAmount}("");
        require(success, "Fee transfer failed");

        emit BenefactorFeesClaimed(benefactor, ethAmount);

        return ethAmount;
    }

    /**
     * @notice Collect fees from a liquidity position
     */
    function collectFeesFromPosition(uint256 positionIndex) external onlyOwner nonReentrant {
        require(positionIndex < liquidityPositions.length, "Invalid position");

        LiquidityPosition storage position = liquidityPositions[positionIndex];
        // TODO: Implement fee collection based on V3/V4 type

        emit FeesCollected(positionIndex, 0, 0);
    }


    // ========== Phase 2 Extension Point ==========

    /**
     * @notice Set beneficiary module (Phase 2)
     * @dev When ready for Phase 2, deploy VaultBenefactorDistribution
     *      and call this function to activate it
     */
    function setBeneficiaryModule(address newModule) external onlyOwner {
        require(newModule == address(0) || newModule.code.length > 0, "Invalid module");
        beneficiaryModule = newModule;
        emit BeneficiaryModuleSet(newModule);
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
     * @notice Get liquidity positions
     * @return Array of liquidity position structs
     */
    function getLiquidityPositions() external view returns (LiquidityPosition[] memory) {
        return liquidityPositions;
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
     * @notice Get benefactor's stake in current LP position
     * @param benefactor Address of the benefactor
     * @return stake Benefactor stake details (frozen at conversion time)
     */
    function getBenefactorStake(address benefactor)
        external
        view
        returns (LPPositionValuation.BenefactorStake memory stake)
    {
        return benefactorStakes[benefactor];
    }

    /**
     * @notice Get benefactor's unclaimed fee amount
     * @param benefactor Address of the benefactor
     * @return unclaimedFees Amount of unclaimed fees available to claim
     */
    function getBenefactorUnclaimedFees(address benefactor)
        external
        view
        returns (uint256 unclaimedFees)
    {
        return LPPositionValuation.calculateUnclaimedFees(
            benefactorStakes,
            benefactor,
            accumulatedFees
        );
    }

    /**
     * @notice Get current LP position metadata
     * @return position Current LP position details
     */
    function getCurrentLPPosition()
        external
        view
        returns (LPPositionValuation.LPPositionMetadata memory position)
    {
        return LPPositionValuation.getLPPosition(currentLPPosition);
    }

    /**
     * @notice Get all benefactor stakes from last conversion
     * @return stakes Array of all active benefactor stakes
     */
    function getAllBenefactorStakes()
        external
        view
        returns (LPPositionValuation.BenefactorStake[] memory stakes)
    {
        return LPPositionValuation.getAllStakes(allBenefactorStakes);
    }

    /**
     * @notice Get total accumulated fees in LP position
     * @return totalFees Total fees available for distribution
     */
    function getTotalAccumulatedFees() external view returns (uint256 totalFees) {
        return accumulatedFees;
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
        address newV3Pool,
        address newV4Pool
    ) external onlyOwner {
        require(newToken != address(0), "Invalid token");
        alignmentTarget.token = newToken;
        if (newV3Pool != address(0)) alignmentTarget.v3Pool = newV3Pool;
        if (newV4Pool != address(0)) alignmentTarget.v4Pool = newV4Pool;
        emit AlignmentTargetSet(newToken, newV3Pool);
    }
}

// ========== Beneficiary Module Interface ==========

/**
 * @notice Interface for beneficiary modules that plug into the vault
 * @dev Implement this to add custom fee distribution logic (Phase 2+)
 */
interface IBeneficiary {
    /**
     * @notice Called when fees are accumulated
     * @param amount Amount of fees accumulated (in wei)
     */
    function onFeeAccumulated(uint256 amount) external;
}
