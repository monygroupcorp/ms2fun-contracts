// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {CurrencySettler} from "../../libraries/v4/CurrencySettler.sol";
import {LiquidityAmounts} from "../../libraries/v4/LiquidityAmounts.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IAlignmentVault} from "../../interfaces/IAlignmentVault.sol";
import {IVaultPriceValidator} from "../../interfaces/IVaultPriceValidator.sol";
import {IAlignmentRegistry} from "../../master/interfaces/IAlignmentRegistry.sol";

interface IzRouterV4 {
    function swapV4(
        address to,
        bool exactOut,
        uint24 swapFee,
        int24 tickSpace,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);
}

/// @notice ERC20 interface with decimals (used only for token setup)
interface IERC20Metadata {
    function decimals() external view returns (uint8);
}

/**
 * @title UniAlignmentVault
 * @notice Share-based vault for collecting and distributing fees from ms2fun ecosystem
 * @dev Clone-compatible (EIP-1167): initialized via initialize() instead of constructor.
 *      Swap and price validation are delegated to peripheral contracts.
 *      Implements IAlignmentVault interface for governance compliance.
 */
contract UniAlignmentVault is ReentrancyGuard, Ownable, IUnlockCallback, IAlignmentVault {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ========== Custom Errors ==========

    error InvalidAddress();
    error TargetNotActive();
    error TokenNotInTarget();
    error AmountMustBePositive();
    error NoPendingETH();
    error NoAlignmentTarget();
    error PoolKeyNotSet();
    error InsufficientLiquidity();
    error InvalidPoolKey();
    error InvalidFeeTier();
    error InvalidTickSpacing();
    error AlignmentTokenNotInPool();
    error PoolMustContainETH();
    error InvalidCurrencyOrdering();
    error NoShares();
    error NoFeesToClaim();
    error InsufficientBalance();
    error TransferFailed();
    error NotBenefactor();
    error NotDelegate();
    error PendingETHNotConverted();
    error RewardTooHigh();
    error DeviationTooHigh();
    error ExceedsMaxBps();
    error TreasuryNotSet();
    error AmountMismatch();
    error ContributionBelowMinimum();
    error TooManyConversionParticipants();

    // ── Anti-DoS constants ────────────────────────────────────────────────
    uint256 public constant MIN_CONTRIBUTION = 0.001 ether;
    uint256 public constant MAX_CONVERSION_PARTICIPANTS = 500;

    // ========== Data Structures ==========

    /// @notice Callback data for V4 modifyLiquidity operations
    struct ModifyLiquidityCallbackData {
        IPoolManager.ModifyLiquidityParams params;
    }

    // ========== Mappings ==========

    // Track total ETH contributed per benefactor (for bragging rights)
    mapping(address => uint256) public benefactorTotalETH;

    // Track shares issued to benefactors (for fee claims)
    mapping(address => uint256) public benefactorShares;

    // Track last claim state for multi-claim support
    mapping(address => uint256) public shareValueAtLastClaim;
    mapping(address => uint256) public lastClaimTimestamp;

    // Track pending contributions in current dragnet (reset after each conversion)
    mapping(address => uint256) public pendingETH;

    // Benefactor delegation (fee routing)
    mapping(address => address) public benefactorDelegate;

    // ========== Global State ==========

    uint256 public totalShares;
    uint256 public totalPendingETH;
    uint256 public accumulatedFees;
    uint256 public totalLPUnits;
    uint256 public totalEthLocked;
    uint256 public totalUniqueBenefactors;
    uint256 public lastVaultFeeCollectionTime;
    uint256 public vaultFeeCollectionInterval = 1 days;

    // Protocol yield cut
    uint256 public protocolYieldCutBps = 100; // 1% of LP yield
    address public protocolTreasury;
    uint256 public accumulatedProtocolFees;

    // Dust accumulation
    uint256 public accumulatedDustShares;
    uint256 public dustDistributionThreshold = 1e18;

    // Conversion participants tracking (dragnet)
    address[] public conversionParticipants;
    mapping(address => uint256) public lastConversionParticipantIndex;

    // External contracts (storage, not immutable — required for clone pattern)
    address public weth;
    address public poolManager;
    address public alignmentToken;
    uint8 public alignmentTokenDecimals;
    PoolKey public v4PoolKey;

    // zRouter swap config (set once at initialize)
    address public zRouter;
    uint24  public zRouterFee;
    int24   public zRouterTickSpacing;

    // Peripherals (set once at initialize, owner can update)
    IVaultPriceValidator public priceValidator;

    // Alignment target binding (set once at initialize)
    IAlignmentRegistry public alignmentRegistry;
    uint256 public alignmentTargetId;

    // Clone guard
    bool private _initialized;

    // ========== Configuration ==========

    uint256 public constant CONVERSION_BASE_GAS = 100_000;
    uint256 public constant GAS_PER_BENEFACTOR = 15_000;
    uint256 public standardConversionReward = 0.0012 ether;

    uint24 public v3PreferredFee = 3000;
    uint256 public maxPriceDeviationBps = 500;

    // Position tracking
    int24 public lastTickLower;
    int24 public lastTickUpper;

    // ========== Events ==========

    event LiquidityAdded(
        uint256 ethSwapped,
        uint256 tokenReceived,
        uint256 lpPositionValue,
        uint256 sharesIssued,
        uint256 callerReward
    );
    event DustDistributed(address indexed recipient, uint256 dustShares);

    event ConversionRewardPaid(address indexed caller, uint256 totalReward, uint256 gasCost, uint256 standardReward);
    event ConversionRewardRejected(address indexed caller, uint256 rewardAmount);
    event InsufficientRewardBalance(address indexed caller, uint256 rewardAmount, uint256 contractBalance);

    event ProtocolYieldCollected(uint256 amount);
    event ProtocolYieldCutUpdated(uint256 newBps);
    event ProtocolTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ProtocolFeesWithdrawn(uint256 amount);

    event AlignmentTokenUpdated(address indexed oldToken, address indexed newToken);
    event V4PoolKeyUpdated(bytes32 indexed poolId);
    event ConversionRewardUpdated(uint256 newReward);
    event MaxPriceDeviationUpdated(uint256 newBps);
    event DustDistributionThresholdUpdated(uint256 newThreshold);
    event BenefactorDelegateSet(address indexed benefactor, address indexed delegate);

    // ========== Initialize (clone pattern) ==========

    /// @notice Initialize the vault clone with all required dependencies
    /// @dev Called once by the factory after EIP-1167 cloning. Sets owner to msg.sender (factory).
    /// @param _weth WETH contract address
    /// @param _poolManager Uniswap V4 PoolManager address
    /// @param _alignmentToken Target community token to buy and LP
    /// @param _zRouter zRouter V4 swap router address
    /// @param _zRouterFee Fee tier for zRouter swaps
    /// @param _zRouterTickSpacing Tick spacing for zRouter swaps
    /// @param _priceValidator Oracle/TWAP price validator for manipulation protection
    /// @param _alignmentRegistry Registry that manages approved alignment targets
    /// @param _alignmentTargetId ID of the alignment target this vault serves
    // slither-disable-next-line events-maths
    function initialize(
        address _initialOwner,
        address _weth,
        address _poolManager,
        address _alignmentToken,
        // slither-disable-next-line missing-zero-check
        address _zRouter,
        uint24  _zRouterFee,
        int24   _zRouterTickSpacing,
        IVaultPriceValidator _priceValidator,
        IAlignmentRegistry _alignmentRegistry,
        uint256 _alignmentTargetId
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        _initializeOwner(_initialOwner);

        if (_weth == address(0)) revert InvalidAddress();
        if (_poolManager == address(0)) revert InvalidAddress();
        if (_alignmentToken == address(0)) revert InvalidAddress();
        if (address(_alignmentRegistry) == address(0)) revert InvalidAddress();
        if (!_alignmentRegistry.isAlignmentTargetActive(_alignmentTargetId)) revert TargetNotActive();
        if (!_alignmentRegistry.isTokenInTarget(_alignmentTargetId, _alignmentToken)) revert TokenNotInTarget();

        weth = _weth;
        poolManager = _poolManager;
        alignmentToken = _alignmentToken;
        zRouter = _zRouter;
        zRouterFee = _zRouterFee;
        zRouterTickSpacing = _zRouterTickSpacing;
        priceValidator = _priceValidator;
        alignmentRegistry = _alignmentRegistry;
        alignmentTargetId = _alignmentTargetId;

        // Initialize defaults that can't use declaration initializers with clones
        protocolYieldCutBps = 100;
        standardConversionReward = 0.0012 ether;
        v3PreferredFee = 3000;
        maxPriceDeviationBps = 500;
        vaultFeeCollectionInterval = 1 days;
        dustDistributionThreshold = 1e18;

        try IERC20Metadata(_alignmentToken).decimals() returns (uint8 decimals) {
            alignmentTokenDecimals = decimals;
        } catch {
            alignmentTokenDecimals = 18;
        }
    }

    // ========== Fee Reception ==========

    /// @notice Accept direct ETH contributions, crediting msg.sender as the benefactor
    receive() external payable {
        _receiveExternalContribution();
    }

    function _receiveExternalContribution() private nonReentrant {
        if (msg.value == 0) revert AmountMustBePositive();
        _trackBenefactorContribution(msg.sender, msg.value);
        emit ContributionReceived(msg.sender, msg.value);
    }

    /// @notice Receive an alignment contribution, crediting the specified benefactor
    /// @dev Called by project instances routing their alignment tax to this vault.
    /// @param currency Currency of the contribution (unused — vault only accepts native ETH)
    /// @param amount Contribution amount in wei
    /// @param benefactor Address to credit for this contribution (typically the project instance)
    function receiveContribution(
        Currency currency,
        uint256 amount,
        address benefactor
    ) external payable override nonReentrant {
        if (amount == 0) revert AmountMustBePositive();
        if (msg.value != amount) revert AmountMismatch();
        if (benefactor == address(0)) revert InvalidAddress();
        _trackBenefactorContribution(benefactor, amount);
        emit ContributionReceived(benefactor, amount);
    }

    function _trackBenefactorContribution(address benefactor, uint256 amount) internal {
        if (amount < MIN_CONTRIBUTION) revert ContributionBelowMinimum();
        if(pendingETH[benefactor] == 0){
            if (conversionParticipants.length >= MAX_CONVERSION_PARTICIPANTS) revert TooManyConversionParticipants();
            conversionParticipants.push(benefactor);
        }
        if(benefactorTotalETH[benefactor] == 0){
            totalUniqueBenefactors++;
        }
        benefactorTotalETH[benefactor] += amount;
        pendingETH[benefactor] += amount;
        totalPendingETH += amount;
    }

    // ========== Conversion & Liquidity ==========

    /**
     * @notice Convert accumulated pending ETH to alignment token and add liquidity to V4.
     * @dev Public incentivized function - caller earns reward for execution.
     *      Uses priceValidator for manipulation checks and proportion calculation.
     *      Uses swapRouter for the actual DEX swap.
     * @param minOutTarget Minimum alignment tokens to receive (slippage protection)
     * @return lpPositionValue Total value of LP position added (ethSwapped + tokenReceived)
     */
    // ── Internal result structs for convertAndAddLiquidity helpers ──────────────
    struct SwapLPResult {
        uint256 targetTokenReceived;
        uint256 liquidityUnitsAdded;
    }

    // slither-disable-next-line reentrancy-benign,reentrancy-eth
    function convertAndAddLiquidity(
        uint256 minOutTarget
    ) external nonReentrant returns (uint256 lpPositionValue) {
        if (minOutTarget == 0) revert AmountMustBePositive();
        if (totalPendingETH == 0) revert NoPendingETH();
        if (alignmentToken == address(0)) revert NoAlignmentTarget();
        if (Currency.unwrap(v4PoolKey.currency0) == address(0) && Currency.unwrap(v4PoolKey.currency1) == address(0)) revert PoolKeyNotSet();

        int24 tickLower = TickMath.minUsableTick(v4PoolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(v4PoolKey.tickSpacing);
        uint256 ethToAdd = totalPendingETH;

        priceValidator.validatePrice(alignmentToken, totalPendingETH);
        uint256 proportionToSwap = priceValidator.calculateSwapProportion(
            alignmentToken, lastTickLower, lastTickUpper, poolManager,
            bytes32(PoolId.unwrap(v4PoolKey.toId()))
        );
        uint256 ethToSwap = (ethToAdd * proportionToSwap) / 1e18; // round down: excess stays as ethForLP

        SwapLPResult memory r = _doSwapAndLP(ethToAdd, ethToSwap, minOutTarget, tickLower, tickUpper);

        address[] memory activeBenefactors = _getActiveBenefactors();
        _distributeSharesAndCleanup(ethToAdd, r.liquidityUnitsAdded, activeBenefactors);

        lpPositionValue = ethToSwap + r.targetTokenReceived;
        uint256 callerReward = _payCallerReward(activeBenefactors.length);
        emit LiquidityAdded(ethToSwap, r.targetTokenReceived, lpPositionValue, r.liquidityUnitsAdded, callerReward);
    }

    // slither-disable-next-line arbitrary-send-eth,reentrancy-benign,unused-return
    function _doSwapAndLP(
        uint256 ethToAdd,
        uint256 ethToSwap,
        uint256 minOutTarget,
        int24 tickLower,
        int24 tickUpper
    ) private returns (SwapLPResult memory r) {
        (, r.targetTokenReceived) = IzRouterV4(zRouter).swapV4{value: ethToSwap}(
            address(this), false, zRouterFee, zRouterTickSpacing,
            address(0), alignmentToken, ethToSwap, minOutTarget, type(uint256).max
        );

        uint256 ethRemaining = ethToAdd - ethToSwap;
        (uint256 amount0, uint256 amount1) = Currency.unwrap(v4PoolKey.currency0) == alignmentToken
            ? (r.targetTokenReceived, ethRemaining)
            : (ethRemaining, r.targetTokenReceived);

        r.liquidityUnitsAdded = uint256(_addToLpPosition(amount0, amount1, tickLower, tickUpper));
        totalLPUnits += r.liquidityUnitsAdded;
    }

    // slither-disable-next-line divide-before-multiply
    function _distributeSharesAndCleanup(
        uint256 ethToAdd,
        uint256 totalSharesIssued,
        address[] memory activeBenefactors
    ) private {
        uint256 totalSharesActuallyIssued = 0;
        address largestContributor = activeBenefactors[0];
        uint256 largestContribution = 0;

        for (uint256 i = 0; i < activeBenefactors.length; i++) {
            address benefactor = activeBenefactors[i];
            uint256 contribution = pendingETH[benefactor];

            if (contribution > largestContribution) {
                largestContribution = contribution;
                largestContributor = benefactor;
            }

            uint256 sharePercent = (contribution * 1e18) / ethToAdd; // round down: dust tracked separately
            uint256 sharesToIssue = (totalSharesIssued * sharePercent) / 1e18; // round down: dust accumulated and redistributed

            benefactorShares[benefactor] += sharesToIssue;
            totalShares += sharesToIssue;
            totalSharesActuallyIssued += sharesToIssue;
            pendingETH[benefactor] = 0;
        }

        uint256 dust = totalSharesIssued - totalSharesActuallyIssued;
        accumulatedDustShares += dust;

        if (accumulatedDustShares >= dustDistributionThreshold) {
            uint256 dustToDistribute = accumulatedDustShares;
            benefactorShares[largestContributor] += dustToDistribute;
            totalShares += dustToDistribute;
            accumulatedDustShares = 0;
            emit DustDistributed(largestContributor, dustToDistribute);
        }

        // Initialize watermarks so new shares cannot retroactively claim pre-existing fees.
        // Must run after all share mutations (including dust distribution) are finalized.
        if (accumulatedFees > 0 && totalShares > 0) {
            for (uint256 i = 0; i < activeBenefactors.length; i++) {
                address benefactor = activeBenefactors[i];
                shareValueAtLastClaim[benefactor] =
                    (accumulatedFees * benefactorShares[benefactor]) / totalShares;
            }
        }

        totalEthLocked += ethToAdd;
        totalPendingETH = 0;
        _clearConversionParticipants();
    }

    // slither-disable-next-line arbitrary-send-eth
    function _payCallerReward(uint256 activeBenefactorsLen) private returns (uint256 callerReward) {
        uint256 estimatedGas = CONVERSION_BASE_GAS + (activeBenefactorsLen * GAS_PER_BENEFACTOR);
        uint256 gasCost = estimatedGas * tx.gasprice;
        callerReward = gasCost + standardConversionReward;

        if (address(this).balance >= callerReward && callerReward > 0) {
            (bool success, ) = payable(msg.sender).call{value: callerReward}("");
            if (success) {
                emit ConversionRewardPaid(msg.sender, callerReward, gasCost, standardConversionReward);
            } else {
                emit ConversionRewardRejected(msg.sender, callerReward);
            }
        } else if (callerReward > 0) {
            emit InsufficientRewardBalance(msg.sender, callerReward, address(this).balance);
        }
    }

    // ========== Fee Claims ==========

    function _claimVaultFees() internal returns (uint256 ethCollected, uint256 tokenCollected) {
        if (totalLPUnits == 0) {
            return (0, 0);
        }

        if (poolManager.code.length == 0) {
            return (0, 0);
        }

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: lastTickLower,
            tickUpper: lastTickUpper,
            liquidityDelta: 0,
            salt: 0
        });

        ModifyLiquidityCallbackData memory lpData = ModifyLiquidityCallbackData({
            params: params
        });

        bytes memory result = IPoolManager(poolManager).unlock(abi.encode(lpData));
        BalanceDelta delta = abi.decode(result, (BalanceDelta));

        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        bool currency0IsETH = v4PoolKey.currency0.isAddressZero();

        if (currency0IsETH) {
            ethCollected = delta0 > 0 ? uint256(int256(delta0)) : 0;
            tokenCollected = delta1 > 0 ? uint256(int256(delta1)) : 0;
        } else {
            ethCollected = delta1 > 0 ? uint256(int256(delta1)) : 0;
            tokenCollected = delta0 > 0 ? uint256(int256(delta0)) : 0;
        }

        return (ethCollected, tokenCollected);
    }

    // slither-disable-next-line unused-return
    function _convertVaultFeesToEth(uint256 tokenAmount) internal returns (uint256 ethReceived) {
        if (tokenAmount == 0) return 0;

        // Derive a TWAP-based minimum output to guard against sandwich attacks.
        // If the validator has no price data (new pool / no history), minEthOut stays 0
        // and the swap proceeds unguarded — acceptable as a rare edge case.
        uint256 minEthOut = 0;
        if (address(priceValidator) != address(0)) {
            uint256 ethEstimate = priceValidator.quoteEthForTokens(alignmentToken, tokenAmount);
            if (ethEstimate > 0) {
                minEthOut = ethEstimate * (10000 - maxPriceDeviationBps) / 10000;
            }
        }

        SafeTransferLib.safeApproveWithRetry(alignmentToken, zRouter, tokenAmount);
        (, ethReceived) = IzRouterV4(zRouter).swapV4(
            address(this),
            false,
            zRouterFee,
            zRouterTickSpacing,
            alignmentToken,
            address(0),
            tokenAmount,
            minEthOut,
            type(uint256).max
        );
    }

    // slither-disable-next-line incorrect-equality,reentrancy-benign,reentrancy-no-eth,timestamp
    function _collectAndAccumulateVaultFees() internal {
        if (block.timestamp >= lastVaultFeeCollectionTime + vaultFeeCollectionInterval
            || lastVaultFeeCollectionTime == 0) {

            (uint256 ethCollected, uint256 tokenCollected) = _claimVaultFees();
            uint256 ethFromTokens = _convertVaultFeesToEth(tokenCollected);

            uint256 totalCollected = ethCollected + ethFromTokens;
            if (totalCollected > 0) {
                uint256 protocolCut = (totalCollected * protocolYieldCutBps) / 10000; // round down: favors benefactors
                uint256 benefactorAmount = totalCollected - protocolCut;

                accumulatedFees += benefactorAmount;
                accumulatedProtocolFees += protocolCut;

                lastVaultFeeCollectionTime = block.timestamp;
                emit FeesAccumulated(benefactorAmount);
                if (protocolCut > 0) emit ProtocolYieldCollected(protocolCut);
            }
        }
    }

    /// @notice Claim accumulated LP yield fees for the caller
    /// @dev Triggers vault fee collection first, then pays the caller's unclaimed delta.
    ///      Fees are routed to the benefactor's delegate if one is set.
    /// @return ethClaimed ETH transferred to caller (or their delegate)
    // slither-disable-next-line reentrancy-benign
    function claimFees() external override nonReentrant returns (uint256 ethClaimed) {
        _collectAndAccumulateVaultFees();

        address benefactor = msg.sender;

        if (benefactorShares[benefactor] == 0) revert NoShares();
        if (accumulatedFees == 0) revert NoFeesToClaim();

        uint256 currentShareValue = (accumulatedFees * benefactorShares[benefactor]) / totalShares; // round down: favors vault

        ethClaimed = currentShareValue > shareValueAtLastClaim[benefactor]
            ? currentShareValue - shareValueAtLastClaim[benefactor]
            : 0;

        if (ethClaimed == 0) revert NoFeesToClaim();

        shareValueAtLastClaim[benefactor] = currentShareValue;
        lastClaimTimestamp[benefactor] = block.timestamp;

        address recipient = benefactorDelegate[benefactor];
        if (recipient == address(0)) recipient = benefactor;

        if (address(this).balance < ethClaimed) revert InsufficientBalance();
        (bool success, ) = payable(recipient).call{value: ethClaimed}("");
        if (!success) revert TransferFailed();

        emit FeesClaimed(benefactor, ethClaimed);

        return ethClaimed;
    }

    // ========== Fee Accumulation ==========

    /// @notice Manually record fees accumulated outside of V4 LP (owner-only)
    /// @param feeAmount ETH amount to add to accumulatedFees
    function recordAccumulatedFees(uint256 feeAmount) external onlyOwner {
        if (feeAmount == 0) revert AmountMustBePositive();
        accumulatedFees += feeAmount;
        emit FeesAccumulated(feeAmount);
    }

    // ========== Internal Helpers ==========

    function _getActiveBenefactors() internal view returns (address[] memory) {
        return conversionParticipants;
    }

    function _clearConversionParticipants() internal {
        while (conversionParticipants.length > 0) {
            conversionParticipants.pop();
        }
    }

    // slither-disable-next-line unused-return
    function _addToLpPosition(
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper
    ) internal virtual returns (uint128 liquidityUnits) {
        if (amount0 == 0 || amount1 == 0) revert AmountMustBePositive();

        lastTickLower = tickLower;
        lastTickUpper = tickUpper;

        Currency currency0 = v4PoolKey.currency0;
        Currency currency1 = v4PoolKey.currency1;

        if (!currency0.isAddressZero()) {
            SafeTransferLib.safeApproveWithRetry(Currency.unwrap(currency0), address(poolManager), amount0);
        }
        if (!currency1.isAddressZero()) {
            SafeTransferLib.safeApproveWithRetry(Currency.unwrap(currency1), address(poolManager), amount1);
        }

        PoolId poolId = v4PoolKey.toId();
        (uint160 sqrtPriceX96, , ,) = StateLibrary.getSlot0(IPoolManager(poolManager), poolId);
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidityToAdd = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, amount0, amount1
        );
        if (liquidityToAdd == 0) revert InsufficientLiquidity();
        int256 liquidityDelta = int256(uint256(liquidityToAdd));

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: liquidityDelta,
            salt: 0
        });

        ModifyLiquidityCallbackData memory lpData = ModifyLiquidityCallbackData({
            params: params
        });

        bytes memory result = IPoolManager(poolManager).unlock(abi.encode(lpData));

        BalanceDelta delta = abi.decode(result, (BalanceDelta));

        liquidityUnits = liquidityToAdd;

        return liquidityUnits;
    }

    /// @notice Uniswap V4 PoolManager unlock callback for modifyLiquidity operations
    /// @dev Only callable by the PoolManager. Executes the liquidity modification and settles deltas.
    /// @param data ABI-encoded ModifyLiquidityCallbackData
    /// @return ABI-encoded BalanceDelta from the liquidity modification
    // slither-disable-next-line unused-return
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Unauthorized();

        ModifyLiquidityCallbackData memory lpData = abi.decode(data, (ModifyLiquidityCallbackData));

        (BalanceDelta delta, ) = IPoolManager(poolManager).modifyLiquidity(
            v4PoolKey,
            lpData.params,
            ""
        );

        _settleLPDelta(delta);

        return abi.encode(delta);
    }

    function _settleLPDelta(BalanceDelta delta) internal {
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        IPoolManager pm = IPoolManager(poolManager);

        if (delta0 < 0) {
            v4PoolKey.currency0.settle(pm, address(this), uint128(-delta0), false);
        } else if (delta0 > 0) {
            v4PoolKey.currency0.take(pm, address(this), uint128(delta0), false);
        }

        if (delta1 < 0) {
            v4PoolKey.currency1.settle(pm, address(this), uint128(-delta1), false);
        } else if (delta1 > 0) {
            v4PoolKey.currency1.take(pm, address(this), uint128(delta1), false);
        }
    }

    // ========== Pool Validation ==========

    function _validateV4Pool(PoolKey memory poolKey) internal view {
        if (Currency.unwrap(poolKey.currency0) == address(0) && Currency.unwrap(poolKey.currency1) == address(0)) revert InvalidPoolKey();

        if (poolKey.fee != 500 && poolKey.fee != 3000 && poolKey.fee != 10000) revert InvalidFeeTier();

        if (poolKey.fee == 500) {
            if (poolKey.tickSpacing != 10) revert InvalidTickSpacing();
        } else if (poolKey.fee == 3000) {
            if (poolKey.tickSpacing != 60) revert InvalidTickSpacing();
        } else if (poolKey.fee == 10000) {
            if (poolKey.tickSpacing != 200) revert InvalidTickSpacing();
        }

        address currency0Addr = Currency.unwrap(poolKey.currency0);
        address currency1Addr = Currency.unwrap(poolKey.currency1);

        if (currency0Addr != alignmentToken && currency1Addr != alignmentToken) revert AlignmentTokenNotInPool();

        bool hasNativeETH = currency0Addr == address(0) || currency1Addr == address(0);
        if (!hasNativeETH) revert PoolMustContainETH();

        if (currency0Addr >= currency1Addr) revert InvalidCurrencyOrdering();
    }

    /// @notice Validate the currently configured V4 pool key (reverts if invalid)
    function validateCurrentPoolKey() external view {
        PoolKey memory key = v4PoolKey;
        _validateV4Pool(key);
    }

    // ========== Query Functions ==========

    function getBenefactorContribution(address benefactor)
        external
        view
        override
        returns (uint256)
    {
        return benefactorTotalETH[benefactor];
    }

    function getBenefactorShares(address benefactor)
        external
        view
        override
        returns (uint256)
    {
        return benefactorShares[benefactor];
    }

    function calculateClaimableAmount(address benefactor)
        external
        view
        override
        returns (uint256)
    {
        if (totalShares == 0 || accumulatedFees == 0) return 0;
        return (accumulatedFees * benefactorShares[benefactor]) / totalShares; // round down: favors vault
    }

    /// @notice Get the unclaimed fee delta for a benefactor since their last claim
    /// @param benefactor Address to query
    /// @return Unclaimed ETH amount
    function getUnclaimedFees(address benefactor)
        external
        view
        returns (uint256)
    {
        uint256 currentShareValue = (accumulatedFees * benefactorShares[benefactor]) / totalShares; // round down: favors vault
        return currentShareValue > shareValueAtLastClaim[benefactor]
            ? currentShareValue - shareValueAtLastClaim[benefactor]
            : 0;
    }

    // ========== Vault Info (IAlignmentVault Interface) ==========

    function vaultType() external pure override returns (string memory) {
        return "UniswapV4LP";
    }

    function description() external pure override returns (string memory) {
        return "Full-range liquidity provision on Uniswap V4 with automated fee compounding and benefactor share distribution";
    }

    function supportsCapability(bytes32 capability) external pure override returns (bool) {
        return capability == keccak256("YIELD_GENERATION")
            || capability == keccak256("BENEFACTOR_DELEGATION");
    }

    function currentPolicy() external pure override returns (bytes memory) {
        return "";
    }

    function validateCompliance(address) external pure override returns (bool) {
        return true;
    }

    // ========== Benefactor Delegation ==========

    /// @notice Set a delegate to receive fee claims on behalf of the caller
    /// @dev Caller must be an existing benefactor. Set to address(0) to remove delegation.
    /// @param delegate Address that will receive fee payouts for the caller
    function delegateBenefactor(address delegate) external override {
        if (benefactorShares[msg.sender] == 0 && benefactorTotalETH[msg.sender] == 0) revert NotBenefactor();
        benefactorDelegate[msg.sender] = delegate;
        emit BenefactorDelegateSet(msg.sender, delegate);
    }

    function getBenefactorDelegate(address benefactor) external view override returns (address) {
        address delegate = benefactorDelegate[benefactor];
        return delegate == address(0) ? benefactor : delegate;
    }

    /// @notice Batch claim fees for multiple benefactors as their registered delegate
    /// @dev Caller must be the delegate for every benefactor in the array. Sends one lump-sum payment.
    /// @param benefactors Array of benefactor addresses to claim for
    /// @return totalClaimed Total ETH sent to the caller (delegate)
    // slither-disable-next-line reentrancy-benign
    function claimFeesAsDelegate(address[] calldata benefactors) external override nonReentrant returns (uint256 totalClaimed) {
        _collectAndAccumulateVaultFees();

        for (uint256 i = 0; i < benefactors.length; i++) {
            address benefactor = benefactors[i];

            if (benefactorDelegate[benefactor] != msg.sender) revert NotDelegate();
            if (benefactorShares[benefactor] == 0) revert NoShares();

            if (accumulatedFees == 0) continue;

            uint256 currentShareValue = (accumulatedFees * benefactorShares[benefactor]) / totalShares; // round down: favors vault

            uint256 ethClaimed = currentShareValue > shareValueAtLastClaim[benefactor]
                ? currentShareValue - shareValueAtLastClaim[benefactor]
                : 0;

            if (ethClaimed > 0) {
                shareValueAtLastClaim[benefactor] = currentShareValue;
                lastClaimTimestamp[benefactor] = block.timestamp;
                totalClaimed += ethClaimed;
                emit FeesClaimed(benefactor, ethClaimed);
            }
        }

        if (totalClaimed == 0) revert NoFeesToClaim();
        if (address(this).balance < totalClaimed) revert InsufficientBalance();

        (bool success, ) = payable(msg.sender).call{value: totalClaimed}("");
        if (!success) revert TransferFailed();
    }

    // ========== Configuration ==========

    /// @notice Change the alignment token (must be in the vault's alignment target)
    /// @dev All pending ETH must be converted first. Validates against AlignmentRegistry.
    /// @param newToken New ERC20 token address to buy and LP
    function setAlignmentToken(address newToken) external onlyOwner {
        if (newToken == address(0)) revert InvalidAddress();
        if (totalPendingETH != 0) revert PendingETHNotConverted();
        if (!alignmentRegistry.isTokenInTarget(alignmentTargetId, newToken)) revert TokenNotInTarget();

        address oldToken = alignmentToken;
        alignmentToken = newToken;

        if (newToken.code.length > 0) {
            try IERC20Metadata(newToken).decimals() returns (uint8 decimals) {
                alignmentTokenDecimals = decimals;
            } catch {
                alignmentTokenDecimals = 18;
            }
        } else {
            alignmentTokenDecimals = 18;
        }

        emit AlignmentTokenUpdated(oldToken, newToken);
    }

    /// @notice Set the Uniswap V4 pool key for liquidity operations
    /// @dev Validates fee tier, tick spacing, currency ordering, and alignment token presence.
    /// @param newPoolKey V4 PoolKey struct identifying the target pool
    function setV4PoolKey(PoolKey calldata newPoolKey) external onlyOwner {
        _validateV4Pool(newPoolKey);
        v4PoolKey = newPoolKey;
        emit V4PoolKeyUpdated(keccak256(abi.encode(newPoolKey)));
    }

    /// @notice Set the base reward paid to callers of convertAndAddLiquidity
    /// @param newReward New reward amount in wei (max 0.1 ETH)
    function setStandardConversionReward(uint256 newReward) external onlyOwner {
        if (newReward > 0.1 ether) revert RewardTooHigh();
        standardConversionReward = newReward;
        emit ConversionRewardUpdated(newReward);
    }

    /// @notice Set maximum allowed price deviation for manipulation protection
    /// @param newBps Deviation in basis points (max 2000 = 20%)
    function setMaxPriceDeviationBps(uint256 newBps) external onlyOwner {
        if (newBps > 2000) revert DeviationTooHigh();
        maxPriceDeviationBps = newBps;
        emit MaxPriceDeviationUpdated(newBps);
    }

    /// @notice Set the threshold at which accumulated dust shares are distributed
    /// @param newThreshold Minimum accumulated dust before redistribution (must be > 0)
    function setDustDistributionThreshold(uint256 newThreshold) external onlyOwner {
        if (newThreshold == 0) revert AmountMustBePositive();
        dustDistributionThreshold = newThreshold;
        emit DustDistributionThresholdUpdated(newThreshold);
    }

    /// @notice Deposit ETH directly into the accumulated fees pool (owner-only)
    /// @dev Used for manual fee injection outside of LP yield collection.
    function depositFees() external payable onlyOwner {
        if (msg.value == 0) revert AmountMustBePositive();
        accumulatedFees += msg.value;
        emit FeesAccumulated(msg.value);
    }

    // ========== Protocol Yield Cut ==========

    /// @notice Set the protocol's share of LP yield in basis points
    /// @param _bps Protocol cut in bps (max 1500 = 15%)
    function setProtocolYieldCutBps(uint256 _bps) external onlyOwner {
        if (_bps > 1500) revert ExceedsMaxBps();
        protocolYieldCutBps = _bps;
        emit ProtocolYieldCutUpdated(_bps);
    }

    /// @notice Set the protocol treasury address for yield cut withdrawals
    /// @param _treasury New treasury address (must not be zero)
    function setProtocolTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidAddress();
        address old = protocolTreasury;
        protocolTreasury = _treasury;
        emit ProtocolTreasuryUpdated(old, _treasury);
    }

    /// @notice Withdraw accumulated protocol yield cut to the treasury
    /// @dev Callable by anyone. Sends accumulatedProtocolFees to protocolTreasury.
    // slither-disable-next-line arbitrary-send-eth,reentrancy-events
    function withdrawProtocolFees() external {
        if (protocolTreasury == address(0)) revert TreasuryNotSet();
        uint256 amount = accumulatedProtocolFees;
        if (amount == 0) revert NoFeesToClaim();
        accumulatedProtocolFees = 0;
        (bool success, ) = payable(protocolTreasury).call{value: amount}("");
        if (!success) revert TransferFailed();
        emit ProtocolFeesWithdrawn(amount);
    }
}
