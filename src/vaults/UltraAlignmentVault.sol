// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {CurrencySettler} from "../libraries/v4/CurrencySettler.sol";
import {LiquidityAmounts} from "../libraries/v4/LiquidityAmounts.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAlignmentVault} from "../interfaces/IAlignmentVault.sol";
import {IVaultSwapRouter} from "../interfaces/IVaultSwapRouter.sol";
import {IVaultPriceValidator} from "../interfaces/IVaultPriceValidator.sol";

/// @notice ERC20 interface with decimals (used only for token setup)
interface IERC20Metadata {
    function decimals() external view returns (uint8);
}

/**
 * @title UltraAlignmentVault
 * @notice Share-based vault for collecting and distributing fees from ms2fun ecosystem
 * @dev Clone-compatible (EIP-1167): initialized via initialize() instead of constructor.
 *      Swap and price validation are delegated to peripheral contracts.
 *      Implements IAlignmentVault interface for governance compliance.
 */
contract UltraAlignmentVault is ReentrancyGuard, Ownable, IUnlockCallback, IAlignmentVault {
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
    uint256 public protocolYieldCutBps = 500; // 5% of LP yield
    address public protocolTreasury;
    uint256 public accumulatedProtocolFees;

    // Vault creator incentives
    address public factoryCreator;
    address public pendingFactoryCreator;
    uint256 public creatorYieldCutBps;
    uint256 public accumulatedCreatorFees;

    // Dust accumulation
    uint256 public accumulatedDustShares;
    uint256 public dustDistributionThreshold = 1e18;

    // Conversion participants tracking (dragnet)
    address[] public conversionParticipants;
    mapping(address => uint256) public lastConversionParticipantIndex;

    // External contracts (storage, not immutable — required for clone pattern)
    address public weth;
    address public poolManager;
    address public v3Router;
    address public v2Router;
    address public v2Factory;
    address public v3Factory;
    address public alignmentToken;
    uint8 public alignmentTokenDecimals;
    PoolKey public v4PoolKey;

    // Peripherals (set once at initialize, owner can update)
    IVaultSwapRouter    public swapRouter;
    IVaultPriceValidator public priceValidator;

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
    event ProtocolTreasuryUpdated(address indexed newTreasury);
    event ProtocolFeesWithdrawn(uint256 amount);

    event FactoryCreatorFeesWithdrawn(uint256 amount);
    event FactoryCreatorYieldCollected(uint256 amount);
    event FactoryCreatorTransferInitiated(address indexed current, address indexed pending);
    event FactoryCreatorTransferAccepted(address indexed oldCreator, address indexed newCreator);

    event AlignmentTokenUpdated(address indexed oldToken, address indexed newToken);
    event V4PoolKeyUpdated(bytes32 indexed poolId);
    event ConversionRewardUpdated(uint256 newReward);
    event MaxPriceDeviationUpdated(uint256 newBps);
    event DustDistributionThresholdUpdated(uint256 newThreshold);
    event BenefactorDelegateSet(address indexed benefactor, address indexed delegate);

    // ========== Initialize (clone pattern) ==========

    function initialize(
        address _weth,
        address _poolManager,
        address _v3Router,
        address _v2Router,
        address _v2Factory,
        address _v3Factory,
        address _alignmentToken,
        address _factoryCreator,
        uint256 _creatorYieldCutBps,
        IVaultSwapRouter _swapRouter,
        IVaultPriceValidator _priceValidator
    ) external {
        if (_initialized) revert("Already initialized");
        _initialized = true;

        _initializeOwner(msg.sender); // factory becomes owner

        require(_weth != address(0), "Invalid WETH");
        require(_poolManager != address(0), "Invalid pool manager");
        require(_alignmentToken != address(0), "Invalid alignment token");
        require(_creatorYieldCutBps <= 500, "Creator cut exceeds protocol yield cut");

        weth = _weth;
        poolManager = _poolManager;
        v3Router = _v3Router;
        v2Router = _v2Router;
        v2Factory = _v2Factory;
        v3Factory = _v3Factory;
        alignmentToken = _alignmentToken;
        factoryCreator = _factoryCreator;
        creatorYieldCutBps = _creatorYieldCutBps;
        swapRouter = _swapRouter;
        priceValidator = _priceValidator;

        // Initialize defaults that can't use declaration initializers with clones
        protocolYieldCutBps = 500;
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

    receive() external payable {
        _receiveExternalContribution();
    }

    function _receiveExternalContribution() private nonReentrant {
        require(msg.value > 0, "Amount must be positive");
        _trackBenefactorContribution(msg.sender, msg.value);
        emit ContributionReceived(msg.sender, msg.value);
    }

    function receiveInstance(
        Currency currency,
        uint256 amount,
        address benefactor
    ) external payable override nonReentrant {
        require(amount > 0, "Amount must be positive");
        require(benefactor != address(0), "Invalid benefactor");
        _trackBenefactorContribution(benefactor, amount);
        emit ContributionReceived(benefactor, amount);
    }

    function _trackBenefactorContribution(address benefactor, uint256 amount) internal {
        if(pendingETH[benefactor] == 0){
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
    function convertAndAddLiquidity(
        uint256 minOutTarget
    ) external nonReentrant returns (uint256 lpPositionValue) {
        require(totalPendingETH > 0, "No pending ETH to convert");
        require(alignmentToken != address(0), "No alignment target set");
        require(Currency.unwrap(v4PoolKey.currency0) != address(0) || Currency.unwrap(v4PoolKey.currency1) != address(0), "V4 pool key not set");

        // ENFORCE FULL-RANGE LIQUIDITY: Always use min/max usable ticks
        int24 tickLower = TickMath.minUsableTick(v4PoolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(v4PoolKey.tickSpacing);

        uint256 ethToAdd = totalPendingETH;

        // Validate price (manipulation detection)
        priceValidator.validatePrice(alignmentToken, totalPendingETH);

        // Calculate proportion of ETH to swap
        uint256 proportionToSwap = priceValidator.calculateSwapProportion(
            alignmentToken,
            lastTickLower,
            lastTickUpper,
            poolManager,
            bytes32(PoolId.unwrap(v4PoolKey.toId()))
        );
        uint256 ethToSwap = (ethToAdd * proportionToSwap) / 1e18;

        // Swap ETH for alignment token via router
        uint256 targetTokenReceived = swapRouter.swapETHForToken{value: ethToSwap}(
            alignmentToken,
            minOutTarget,
            address(this)
        );

        // Add to LP position
        uint128 newLiquidityUnits;
        {
            uint256 ethRemaining = ethToAdd - ethToSwap;

            (uint256 amount0, uint256 amount1) = Currency.unwrap(v4PoolKey.currency0) == alignmentToken
                ? (targetTokenReceived, ethRemaining)
                : (ethRemaining, targetTokenReceived);

            newLiquidityUnits = _addToLpPosition(amount0, amount1, tickLower, tickUpper);
        }

        uint256 liquidityUnitsAdded = uint256(newLiquidityUnits);
        totalLPUnits += liquidityUnitsAdded;

        uint256 totalSharesIssued = liquidityUnitsAdded;

        // Issue shares to all pending benefactors
        address[] memory activeBenefactors = _getActiveBenefactors();

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

            uint256 sharePercent = (contribution * 1e18) / ethToAdd;
            uint256 sharesToIssue = (totalSharesIssued * sharePercent) / 1e18;

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

        totalEthLocked += ethToAdd;

        totalPendingETH = 0;
        _clearConversionParticipants();

        lpPositionValue = ethToSwap + targetTokenReceived;

        // Pay caller reward (M-04 Security Fix: Gas-based + graceful degradation)
        uint256 estimatedGas = CONVERSION_BASE_GAS + (activeBenefactors.length * GAS_PER_BENEFACTOR);
        uint256 gasCost = estimatedGas * tx.gasprice;
        uint256 callerReward = gasCost + standardConversionReward;

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

    function _convertVaultFeesToEth(uint256 tokenAmount) internal returns (uint256 ethReceived) {
        if (tokenAmount == 0) return 0;
        IERC20(alignmentToken).approve(address(swapRouter), tokenAmount);
        return swapRouter.swapTokenForETH(alignmentToken, tokenAmount, 0, address(this));
    }

    function _collectAndAccumulateVaultFees() internal {
        if (block.timestamp >= lastVaultFeeCollectionTime + vaultFeeCollectionInterval
            || lastVaultFeeCollectionTime == 0) {

            (uint256 ethCollected, uint256 tokenCollected) = _claimVaultFees();
            uint256 ethFromTokens = _convertVaultFeesToEth(tokenCollected);

            uint256 totalCollected = ethCollected + ethFromTokens;
            if (totalCollected > 0) {
                uint256 totalCut = (totalCollected * protocolYieldCutBps) / 10000;
                uint256 creatorCut = (totalCollected * creatorYieldCutBps) / 10000;
                uint256 protocolCut = totalCut - creatorCut;
                uint256 benefactorAmount = totalCollected - totalCut;

                accumulatedFees += benefactorAmount;
                accumulatedProtocolFees += protocolCut;
                accumulatedCreatorFees += creatorCut;

                lastVaultFeeCollectionTime = block.timestamp;
                emit FeesAccumulated(benefactorAmount);
                if (protocolCut > 0) emit ProtocolYieldCollected(protocolCut);
                if (creatorCut > 0) emit FactoryCreatorYieldCollected(creatorCut);
            }
        }
    }

    function claimFees() external override nonReentrant returns (uint256 ethClaimed) {
        _collectAndAccumulateVaultFees();

        address benefactor = msg.sender;

        require(benefactorShares[benefactor] > 0, "No shares");
        require(accumulatedFees > 0, "No fees to claim");

        uint256 currentShareValue = (accumulatedFees * benefactorShares[benefactor]) / totalShares;

        ethClaimed = currentShareValue > shareValueAtLastClaim[benefactor]
            ? currentShareValue - shareValueAtLastClaim[benefactor]
            : 0;

        require(ethClaimed > 0, "No new fees to claim");

        shareValueAtLastClaim[benefactor] = currentShareValue;
        lastClaimTimestamp[benefactor] = block.timestamp;

        address recipient = benefactorDelegate[benefactor];
        if (recipient == address(0)) recipient = benefactor;

        require(address(this).balance >= ethClaimed, "Insufficient ETH for claim");
        (bool success, ) = payable(recipient).call{value: ethClaimed}("");
        require(success, "ETH transfer failed");

        emit FeesClaimed(benefactor, ethClaimed);

        return ethClaimed;
    }

    // ========== Fee Accumulation ==========

    function recordAccumulatedFees(uint256 feeAmount) external onlyOwner {
        require(feeAmount > 0, "Fee amount must be positive");
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

    function _addToLpPosition(
        uint256 amount0,
        uint256 amount1,
        int24 tickLower,
        int24 tickUpper
    ) internal virtual returns (uint128 liquidityUnits) {
        require(amount0 > 0 && amount1 > 0, "Amounts must be positive");

        lastTickLower = tickLower;
        lastTickUpper = tickUpper;

        Currency currency0 = v4PoolKey.currency0;
        Currency currency1 = v4PoolKey.currency1;

        if (!currency0.isAddressZero()) {
            IERC20(Currency.unwrap(currency0)).approve(address(poolManager), amount0);
        }
        if (!currency1.isAddressZero()) {
            IERC20(Currency.unwrap(currency1)).approve(address(poolManager), amount1);
        }

        PoolId poolId = v4PoolKey.toId();
        (uint160 sqrtPriceX96, , ,) = StateLibrary.getSlot0(IPoolManager(poolManager), poolId);
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidityToAdd = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, amount0, amount1
        );
        require(liquidityToAdd > 0, "Insufficient amounts for liquidity");
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

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only PoolManager");

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
        require(
            Currency.unwrap(poolKey.currency0) != address(0) ||
            Currency.unwrap(poolKey.currency1) != address(0),
            "Invalid pool key: no currencies set"
        );

        require(
            poolKey.fee == 500 || poolKey.fee == 3000 || poolKey.fee == 10000,
            "Invalid fee tier (must be 500, 3000, or 10000)"
        );

        if (poolKey.fee == 500) {
            require(poolKey.tickSpacing == 10, "Invalid tick spacing for 0.05% fee");
        } else if (poolKey.fee == 3000) {
            require(poolKey.tickSpacing == 60, "Invalid tick spacing for 0.3% fee");
        } else if (poolKey.fee == 10000) {
            require(poolKey.tickSpacing == 200, "Invalid tick spacing for 1% fee");
        }

        address currency0Addr = Currency.unwrap(poolKey.currency0);
        address currency1Addr = Currency.unwrap(poolKey.currency1);

        require(
            currency0Addr == alignmentToken || currency1Addr == alignmentToken,
            "Alignment token not in pool"
        );

        bool hasNativeETH = currency0Addr == address(0) || currency1Addr == address(0);
        require(hasNativeETH, "Pool must contain native ETH (address(0))");

        require(
            currency0Addr < currency1Addr,
            "Invalid currency ordering (currency0 must be < currency1)"
        );
    }

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
        return (accumulatedFees * benefactorShares[benefactor]) / totalShares;
    }

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

    function delegateBenefactor(address delegate) external override {
        require(benefactorShares[msg.sender] > 0 || benefactorTotalETH[msg.sender] > 0, "Not a benefactor");
        benefactorDelegate[msg.sender] = delegate;
        emit BenefactorDelegateSet(msg.sender, delegate);
    }

    function getBenefactorDelegate(address benefactor) external view override returns (address) {
        address delegate = benefactorDelegate[benefactor];
        return delegate == address(0) ? benefactor : delegate;
    }

    function claimFeesAsDelegate(address[] calldata benefactors) external override nonReentrant returns (uint256 totalClaimed) {
        _collectAndAccumulateVaultFees();

        for (uint256 i = 0; i < benefactors.length; i++) {
            address benefactor = benefactors[i];

            require(benefactorDelegate[benefactor] == msg.sender, "Not delegate for benefactor");
            require(benefactorShares[benefactor] > 0, "No shares");

            if (accumulatedFees == 0) continue;

            uint256 currentShareValue = (accumulatedFees * benefactorShares[benefactor]) / totalShares;

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

        require(totalClaimed > 0, "No fees to claim");
        require(address(this).balance >= totalClaimed, "Insufficient ETH for claims");

        (bool success, ) = payable(msg.sender).call{value: totalClaimed}("");
        require(success, "ETH transfer failed");
    }

    // ========== Vault Creator Fees ==========

    function withdrawCreatorFees() external {
        require(msg.sender == factoryCreator, "Only factory creator");
        uint256 amount = accumulatedCreatorFees;
        require(amount > 0, "No creator fees");
        accumulatedCreatorFees = 0;
        (bool success, ) = payable(factoryCreator).call{value: amount}("");
        require(success, "ETH transfer failed");
        emit FactoryCreatorFeesWithdrawn(amount);
    }

    function transferFactoryCreator(address newCreator) external {
        require(msg.sender == factoryCreator, "Only factory creator");
        require(newCreator != address(0), "Invalid address");
        require(newCreator != factoryCreator, "Already creator");
        pendingFactoryCreator = newCreator;
        emit FactoryCreatorTransferInitiated(factoryCreator, newCreator);
    }

    function acceptFactoryCreator() external {
        require(msg.sender == pendingFactoryCreator, "Only pending creator");
        address old = factoryCreator;
        factoryCreator = pendingFactoryCreator;
        pendingFactoryCreator = address(0);
        emit FactoryCreatorTransferAccepted(old, factoryCreator);
    }

    function creator() external view returns (address) {
        return factoryCreator;
    }

    // ========== Configuration ==========

    function setAlignmentToken(address newToken) external onlyOwner {
        require(newToken != address(0), "Invalid token");
        address oldToken = alignmentToken;
        alignmentToken = newToken;
        emit AlignmentTokenUpdated(oldToken, newToken);
    }

    function setV4PoolKey(PoolKey calldata newPoolKey) external onlyOwner {
        _validateV4Pool(newPoolKey);
        v4PoolKey = newPoolKey;
        emit V4PoolKeyUpdated(keccak256(abi.encode(newPoolKey)));
    }

    function setStandardConversionReward(uint256 newReward) external onlyOwner {
        require(newReward <= 0.1 ether, "Reward too high (max 0.1 ETH)");
        standardConversionReward = newReward;
        emit ConversionRewardUpdated(newReward);
    }

    function setMaxPriceDeviationBps(uint256 newBps) external onlyOwner {
        require(newBps <= 2000, "Deviation too high (max 20%)");
        maxPriceDeviationBps = newBps;
        emit MaxPriceDeviationUpdated(newBps);
    }

    function setDustDistributionThreshold(uint256 newThreshold) external onlyOwner {
        require(newThreshold > 0, "Threshold must be positive");
        dustDistributionThreshold = newThreshold;
        emit DustDistributionThresholdUpdated(newThreshold);
    }

    function depositFees() external payable onlyOwner {
        require(msg.value > 0, "Amount must be positive");
        accumulatedFees += msg.value;
        emit FeesAccumulated(msg.value);
    }

    // ========== Protocol Yield Cut ==========

    function setProtocolYieldCutBps(uint256 _bps) external onlyOwner {
        require(_bps <= 1500, "Max 15%");
        protocolYieldCutBps = _bps;
        emit ProtocolYieldCutUpdated(_bps);
    }

    function setProtocolTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid treasury");
        protocolTreasury = _treasury;
        emit ProtocolTreasuryUpdated(_treasury);
    }

    function withdrawProtocolFees() external {
        require(protocolTreasury != address(0), "Treasury not set");
        uint256 amount = accumulatedProtocolFees;
        require(amount > 0, "No fees");
        accumulatedProtocolFees = 0;
        (bool success, ) = payable(protocolTreasury).call{value: amount}("");
        require(success, "ETH transfer failed");
        emit ProtocolFeesWithdrawn(amount);
    }
}
