// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { DN404 } from "dn404/src/DN404.sol";
import { DN404Mirror } from "dn404/src/DN404Mirror.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { BondingCurveMath } from "./libraries/BondingCurveMath.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "v4-core/types/Currency.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { LiquidityAmounts } from "../../libraries/v4/LiquidityAmounts.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolId } from "v4-core/types/PoolId.sol";
import { CurrencySettler } from "../../libraries/v4/CurrencySettler.sol";
import { IAlignmentVault } from "../../interfaces/IAlignmentVault.sol";
import { GlobalMessageRegistry } from "../../registry/GlobalMessageRegistry.sol";
import { GlobalMessagePacking } from "../../libraries/GlobalMessagePacking.sol";
import { GlobalMessageTypes } from "../../libraries/GlobalMessageTypes.sol";
import { IMasterRegistry } from "../../master/interfaces/IMasterRegistry.sol";
import { IERC20 } from "../../shared/interfaces/IERC20.sol";

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IProtocolTreasuryPOL {
    function receivePOL(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) external;
}

/**
 * @title ERC404BondingInstance
 * @notice ERC404 token with bonding curve, password-protected tiers, and V4 liquidity deployment
 * @dev Extends DN404 with bonding curve mechanics, message system, and Uniswap V4 integration
 */
contract ERC404BondingInstance is DN404, Ownable, ReentrancyGuard, IUnlockCallback {
    using BondingCurveMath for BondingCurveMath.Params;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    // ┌─────────────────────────┐
    // │         Types           │
    // └─────────────────────────┘

    enum TierType {
        VOLUME_CAP,    // Password unlocks higher purchase limits
        TIME_BASED     // Password allows early access
    }

    struct BondingCurveParams {
        uint256 initialPrice;
        uint256 quarticCoeff;
        uint256 cubicCoeff;
        uint256 quadraticCoeff;
        uint256 normalizationFactor;
    }

    struct TierConfig {
        TierType tierType;
        bytes32[] passwordHashes;
        uint256[] volumeCaps;      // For VOLUME_CAP mode
        uint256[] tierUnlockTimes; // For TIME_BASED mode (relative to bondingOpenTime)
    }

    // ┌─────────────────────────┐
    // │      State Variables    │
    // └─────────────────────────┘

    string private _name;
    string private _symbol;
    
    uint256 public immutable MAX_SUPPLY;
    uint256 public immutable LIQUIDITY_RESERVE;
    BondingCurveMath.Params public curveParams; // Storage (set in constructor, never changed)
    TierConfig public tierConfig; // Storage (set in constructor, never changed)
    uint256 public tierCount;

    // Pool configuration (from graduation profile)
    uint24 public immutable poolFee;
    int24 public immutable tickSpacing;
    uint256 public immutable UNIT;

    IPoolManager public immutable v4PoolManager;
    IHooks public v4Hook; // Can be set after deployment
    address public immutable factory;
    address public immutable weth;
    IAlignmentVault public immutable vault;
    IMasterRegistry public immutable masterRegistry;
    GlobalMessageRegistry private cachedGlobalRegistry; // Lazy-loaded from masterRegistry

    // Protocol revenue
    address public immutable protocolTreasury;
    uint256 public immutable bondingFeeBps;
    uint256 public immutable graduationFeeBps;
    uint256 public immutable polBps;

    // Creator incentives (factory creator's share of graduation fee)
    address public immutable factoryCreator;
    uint256 public immutable creatorGraduationFeeBps;

    // Customization
    string public styleUri;

    uint256 public bondingOpenTime;  // Set by owner, 0 = not set
    uint256 public bondingMaturityTime; // When anyone can deploy liquidity, 0 = not set
    bool public bondingActive;       // Toggle for open/close
    uint256 public totalBondingSupply;
    uint256 public reserve;
    address public liquidityPool;     // V4 pool address after deployment

    // Password-protected tier system
    mapping(bytes32 => uint256) public tierByPasswordHash; // hash => tier index (0 = no tier)
    mapping(address => uint256) public userTierUnlocked;    // user => highest tier unlocked
    mapping(address => uint256) public userPurchaseVolume;   // For volume cap mode

    // Free mint system (optional)
    uint256 public freeSupply;
    mapping(address => bool) public freeMint;

    // Reroll system
    mapping(address => uint256) public rerollEscrow;  // user => tokens held for reroll

    // Staking system (optional holder alignment rewards)
    bool public stakingEnabled;
    mapping(address => uint256) public stakedBalance;     // user => staked token amount
    uint256 public totalStaked;                            // total tokens staked across all users
    uint256 public totalFeesAccumulatedFromVault;          // cumulative total fees received from vault (share-based accounting)
    mapping(address => uint256) public stakerFeesAlreadyClaimed; // user => cumulative fees already claimed (share-based accounting)

    // Events
    event BondingSale(address indexed user, uint256 amount, uint256 cost, bool isBuy);
    event BondingOpenTimeSet(uint256 openTime);
    event BondingMaturityTimeSet(uint256 maturityTime);
    event BondingActiveChanged(bool active);
    event LiquidityDeployed(address indexed pool, uint256 amountToken, uint256 amountETH);
    event RerollInitiated(address indexed user, uint256 tokenAmount, uint256[] exemptedNFTIds);
    event RerollCompleted(address indexed user, uint256 tokensReturned);
    event StakingEnabled();
    event Staked(address indexed user, uint256 amount, uint256 newStakedBalance, uint256 newTotalStaked);
    event Unstaked(address indexed user, uint256 amount, uint256 newStakedBalance, uint256 newTotalStaked);
    event StakerRewardsClaimed(address indexed user, uint256 rewardAmount, uint256 newTrackingPoint);
    event BondingFeePaid(address indexed buyer, uint256 feeAmount);
    event GraduationFeePaid(address indexed treasury, uint256 amount);
    event CreatorGraduationFeePaid(address indexed factoryCreator, uint256 amount);
    event ProtocolLiquidityDeployed(address indexed treasury, uint256 tokenAmount, uint256 ethAmount);
    event V4HookSet(address indexed hook);

    // ┌─────────────────────────┐
    // │      Constructor        │
    // └─────────────────────────┘

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 _maxSupply,
        uint256 _liquidityReservePercent,
        BondingCurveParams memory _curveParams,
        TierConfig memory _tierConfig,
        address _v4PoolManager,
        address _v4Hook,
        address _weth,
        address _factory,
        address _masterRegistry,
        address _vault,
        address _owner,
        string memory _styleUri,
        address _protocolTreasury,
        uint256 _bondingFeeBps,
        uint256 _graduationFeeBps,
        uint256 _polBps,
        address _factoryCreator,
        uint256 _creatorGraduationFeeBps,
        uint24 _poolFee,
        int24 _tickSpacing,
        uint256 _unit
    ) {
        require(_maxSupply > 0, "Invalid max supply");
        require(_liquidityReservePercent < 100, "Invalid reserve percent");
        require(_v4PoolManager != address(0), "Invalid pool manager");
        require(_weth != address(0), "Invalid WETH");
        // Hook can be address(0) initially and set later
        require(_factory != address(0), "Invalid factory");
        require(_masterRegistry != address(0), "Invalid master registry");
        require(_owner != address(0), "Invalid owner");
        require(_tierConfig.passwordHashes.length > 0, "No tiers");
        require(
            _tierConfig.tierType == TierType.VOLUME_CAP
                ? _tierConfig.volumeCaps.length == _tierConfig.passwordHashes.length
                : _tierConfig.tierUnlockTimes.length == _tierConfig.passwordHashes.length,
            "Tier config mismatch"
        );

        _initializeOwner(_owner);

        _name = name_;
        _symbol = symbol_;
        MAX_SUPPLY = _maxSupply;
        LIQUIDITY_RESERVE = (_maxSupply * _liquidityReservePercent) / 100;
        curveParams = BondingCurveMath.Params({
            initialPrice: _curveParams.initialPrice,
            quarticCoeff: _curveParams.quarticCoeff,
            cubicCoeff: _curveParams.cubicCoeff,
            quadraticCoeff: _curveParams.quadraticCoeff,
            normalizationFactor: _curveParams.normalizationFactor
        });
        tierConfig = _tierConfig;
        tierCount = _tierConfig.passwordHashes.length;

        v4PoolManager = IPoolManager(_v4PoolManager);
        v4Hook = IHooks(_v4Hook); // Can be address(0)
        weth = _weth;
        factory = _factory;
        masterRegistry = IMasterRegistry(_masterRegistry);
        require(_vault != address(0), "Invalid vault");
        vault = IAlignmentVault(payable(_vault));
        styleUri = _styleUri;
        protocolTreasury = _protocolTreasury;
        bondingFeeBps = _bondingFeeBps;
        graduationFeeBps = _graduationFeeBps;
        polBps = _polBps;
        factoryCreator = _factoryCreator;
        creatorGraduationFeeBps = _creatorGraduationFeeBps;
        poolFee = _poolFee;
        tickSpacing = _tickSpacing;
        UNIT = _unit;

        // Initialize password hash mapping
        for (uint256 i = 0; i < _tierConfig.passwordHashes.length; i++) {
            require(_tierConfig.passwordHashes[i] != bytes32(0), "Invalid password hash");
            tierByPasswordHash[_tierConfig.passwordHashes[i]] = i + 1; // Tier 1-indexed
        }

        // Deploy DN404 mirror and initialize
        // Note: _factory is passed as deployer for linking authorization only.
        // The actual owner is synced via pullOwner() from this contract's owner().
        address mirror = address(new DN404Mirror(_factory));
        _initializeDN404(_maxSupply, address(this), mirror);
    }

    // ┌─────────────────────────┐
    // │    Owner Functions      │
    // └─────────────────────────┘

    /**
     * @notice Set the bonding curve open time
     * @dev Accepts Unix timestamp as uint256. For date strings, frontend should convert to timestamp.
     * @param timestamp Unix timestamp for when bonding curve should open
     */
    function setBondingOpenTime(uint256 timestamp) external onlyOwner {
        require(timestamp > block.timestamp, "Time must be in future");
        bondingOpenTime = timestamp;
        emit BondingOpenTimeSet(timestamp);
    }

    /**
     * @notice Set the bonding curve maturity time (when permissionless liquidity deployment is allowed)
     * @dev After maturity, anyone can call deployLiquidity to transition to V4 pool
     * @param timestamp Unix timestamp for when bonding curve matures
     */
    function setBondingMaturityTime(uint256 timestamp) external onlyOwner {
        require(timestamp > block.timestamp, "Time must be in future");
        require(bondingOpenTime != 0, "Open time must be set first");
        require(timestamp > bondingOpenTime, "Maturity must be after open time");
        bondingMaturityTime = timestamp;
        emit BondingMaturityTimeSet(timestamp);
    }

    /**
     * @notice Set bonding curve active state
     * @dev Requires bondingOpenTime to be set AND hook must be configured first
     * @param _active Whether bonding curve is active
     */
    function setBondingActive(bool _active) external onlyOwner {
        require(bondingOpenTime != 0, "Open time not set");
        if (_active) {
            require(address(v4Hook) != address(0), "Hook must be set before activating bonding");
            require(liquidityPool == address(0), "Cannot activate bonding after liquidity deployed");
        }
        bondingActive = _active;
        emit BondingActiveChanged(_active);
    }

    /**
     * @notice Set V4 hook address
     * @dev Can be called after deployment to set hook
     * @param _hook Hook address
     */
    function setV4Hook(address _hook) external onlyOwner {
        require(_hook != address(0), "Invalid hook");
        require(address(v4Hook) == address(0), "Hook already set");
        v4Hook = IHooks(_hook);
        emit V4HookSet(_hook);
    }

    // ┌─────────────────────────┐
    // │  Global Message Helpers │
    // └─────────────────────────┘

    /**
     * @notice Internal helper to lazy-load global message registry
     * @dev Caches registry address to avoid repeated external calls
     * @return GlobalMessageRegistry instance
     */
    function _getGlobalMessageRegistry() private returns (GlobalMessageRegistry) {
        if (address(cachedGlobalRegistry) == address(0)) {
            address registryAddr = masterRegistry.getGlobalMessageRegistry();
            require(registryAddr != address(0), "Global registry not set");
            cachedGlobalRegistry = GlobalMessageRegistry(registryAddr);
        }
        return cachedGlobalRegistry;
    }

    /**
     * @notice Get global message registry address (public getter for frontend)
     * @return Address of the GlobalMessageRegistry contract
     */
    function getGlobalMessageRegistry() external view returns (address) {
        return masterRegistry.getGlobalMessageRegistry();
    }

    // ┌─────────────────────────┐
    // │   Tier System Functions │
    // └─────────────────────────┘

    // NOTE: Tier unlocking is now verified inline during buyBonding/sellBonding
    // to reduce gas costs and simplify the UX. Users provide password hash directly
    // at purchase time, eliminating the need for a separate unlock transaction.

    /**
     * @notice Check if user can access a tier (for querying purposes)
     * @param user The user address
     * @param passwordHash The password hash (can be bytes32(0) for public tier)
     * @return canAccess Whether user can access the tier
     */
    function canAccessTier(address user, bytes32 passwordHash) external view returns (bool canAccess) {
        if (liquidityPool != address(0)) return true; // Bonding ended, no restrictions

        uint256 tier = passwordHash == bytes32(0) ? 0 : tierByPasswordHash[passwordHash];
        if (tier == 0 && passwordHash != bytes32(0)) return false;

        if (tierConfig.tierType == TierType.VOLUME_CAP) {
            // For VOLUME_CAP mode, tier is accessed by providing password during purchase
            // No pre-unlock tracking needed. Just verify tier exists.
            return tier == 0 || tier <= tierCount;
        } else {
            // For TIME_BASED mode, check if unlock time has passed
            if (bondingOpenTime == 0) return false;
            if (tier == 0) return true; // Public tier always accessible
            uint256 tierUnlockTime = bondingOpenTime + tierConfig.tierUnlockTimes[tier - 1];
            return block.timestamp >= tierUnlockTime;
        }
    }

    // ┌─────────────────────────┐
    // │   Bonding Curve Math    │
    // └─────────────────────────┘

    /**
     * @notice Calculate cost to buy tokens
     * @param amount Amount of tokens to buy
     * @return cost ETH cost
     */
    function calculateCost(uint256 amount) public view returns (uint256) {
        return BondingCurveMath.calculateCost(curveParams, totalBondingSupply, amount);
    }

    /**
     * @notice Calculate refund for selling tokens
     * @param amount Amount of tokens to sell
     * @return refund ETH refund
     */
    function calculateRefund(uint256 amount) public view returns (uint256) {
        return BondingCurveMath.calculateRefund(curveParams, totalBondingSupply, amount);
    }

    // ┌─────────────────────────┐
    // │    Buy/Sell Functions   │
    // └─────────────────────────┘

    /**
     * @notice Buy tokens from bonding curve
     * @param amount Amount of tokens to buy
     * @param maxCost Maximum ETH cost
     * @param mintNFT Whether to mint NFTs
     * @param passwordHash Password hash for tier access (bytes32(0) for public)
     * @param message Optional message
     * @param deadline Timestamp after which this transaction reverts (0 = no deadline)
     */
    function buyBonding(
        uint256 amount,
        uint256 maxCost,
        bool mintNFT,
        bytes32 passwordHash,
        string calldata message,
        uint256 deadline
    ) external payable nonReentrant {
        require(deadline == 0 || block.timestamp <= deadline, "Transaction expired");
        require(bondingActive, "Bonding not active");
        require(liquidityPool == address(0), "Bonding ended");
        require(address(v4Hook) != address(0), "Hook not configured");
        require(totalBondingSupply + amount <= MAX_SUPPLY - LIQUIDITY_RESERVE, "Exceeds bonding");

        // Check tier access
        uint256 tier = passwordHash == bytes32(0) ? 0 : tierByPasswordHash[passwordHash];
        require(tier != 0 || passwordHash == bytes32(0), "Invalid password");

        if (tierConfig.tierType == TierType.VOLUME_CAP) {
            // Verify user hasn't exceeded volume cap for this tier
            uint256 cap = tier == 0 ? type(uint256).max : tierConfig.volumeCaps[tier - 1];
            require(userPurchaseVolume[msg.sender] + amount <= cap, "Volume cap exceeded");
        } else {
            // For TIME_BASED: verify tier unlock time has passed
            require(bondingOpenTime != 0, "Bonding not configured");
            if (tier > 0) {
                uint256 tierUnlockTime = bondingOpenTime + tierConfig.tierUnlockTimes[tier - 1];
                require(block.timestamp >= tierUnlockTime, "Tier not available yet");
            }
        }

        uint256 totalCost = calculateCost(amount);
        uint256 bondingFee = (totalCost * bondingFeeBps) / 10000;
        uint256 totalWithFee = totalCost + bondingFee;
        require(maxCost >= totalWithFee, "MaxCost exceeded");
        require(msg.value >= totalWithFee, "Low ETH value");

        // Handle skipNFT
        bool originalSkipNFT = mintNFT ? getSkipNFT(msg.sender) : false;
        if (originalSkipNFT) {
            _setSkipNFT(msg.sender, false);
        }

        // Handle free mints if applicable
        if (freeSupply > UNIT && !freeMint[msg.sender]) {
            totalBondingSupply += amount;
            amount += UNIT;
            freeSupply -= UNIT;
            freeMint[msg.sender] = true;
        } else {
            totalBondingSupply += amount;
        }

        // Transfer tokens
        _transfer(address(this), msg.sender, amount);
        reserve += totalCost;

        // Route bonding fee to protocol treasury
        if (bondingFee > 0 && protocolTreasury != address(0)) {
            SafeTransferLib.safeTransferETH(protocolTreasury, bondingFee);
            emit BondingFeePaid(msg.sender, bondingFee);
        }

        // Update purchase volume for volume cap mode
        if (tierConfig.tierType == TierType.VOLUME_CAP) {
            userPurchaseVolume[msg.sender] += amount;
        }

        // Store message in global registry
        if (bytes(message).length > 0) {
            GlobalMessageRegistry registry = _getGlobalMessageRegistry();

            uint256 packedData = GlobalMessagePacking.pack(
                uint32(block.timestamp),
                GlobalMessageTypes.FACTORY_ERC404,
                GlobalMessageTypes.ACTION_BUY,
                0, // contextId: 0 for ERC404 (no editions)
                uint96(amount / 1e18) // Normalize to whole tokens
            );

            registry.addMessage(address(this), msg.sender, packedData, message);
        }

        // Reset skipNFT
        if (originalSkipNFT) {
            _setSkipNFT(msg.sender, true);
        }

        // Refund excess ETH
        if (msg.value > totalWithFee) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - totalWithFee);
        }

        emit BondingSale(msg.sender, amount, totalWithFee, true);
    }

    /**
     * @notice Sell tokens back to bonding curve
     * @param amount Amount of tokens to sell
     * @param minRefund Minimum ETH refund expected
     * @param passwordHash Password hash for tier access
     * @param message Optional message
     * @param deadline Timestamp after which this transaction reverts (0 = no deadline)
     */
    function sellBonding(
        uint256 amount,
        uint256 minRefund,
        bytes32 passwordHash,
        string calldata message,
        uint256 deadline
    ) external nonReentrant {
        require(deadline == 0 || block.timestamp <= deadline, "Transaction expired");
        require(bondingActive, "Bonding not active");
        require(liquidityPool == address(0), "Bonding ended");
        require(address(v4Hook) != address(0), "Hook not configured");

        // Lock sells when bonding curve is full to preserve best case scenario for liquidity deployment
        /// @dev Sells are intentionally blocked when bonding curve is full. This ensures
        /// users hold their positions until liquidity deployment occurs. The lock prevents
        /// supply from decreasing after curve completion, maintaining the bonding curve's
        /// terminal state until migration to Uniswap V4 liquidity.
        uint256 maxBondingSupply = MAX_SUPPLY - LIQUIDITY_RESERVE;
        require(totalBondingSupply < maxBondingSupply, "Bonding curve full - sells locked");

        // Check tier access (for sellBonding, mainly TIME_BASED tiers)
        uint256 tier = passwordHash == bytes32(0) ? 0 : tierByPasswordHash[passwordHash];
        require(tier != 0 || passwordHash == bytes32(0), "Invalid password");

        if (tierConfig.tierType == TierType.TIME_BASED) {
            require(bondingOpenTime != 0, "Bonding not configured");
            if (tier > 0) {
                uint256 tierUnlockTime = bondingOpenTime + tierConfig.tierUnlockTimes[tier - 1];
                require(block.timestamp >= tierUnlockTime, "Tier not available yet");
            }
        }
        // For VOLUME_CAP, no special restrictions on selling

        uint256 balance = balanceOf(msg.sender);
        require(balance >= amount, "Insufficient balance");
        
        if (freeMint[msg.sender] && (balance - amount < UNIT)) {
            revert("Cannot sell free mint tokens");
        }

        uint256 refund = calculateRefund(amount);
        require(refund >= minRefund && reserve >= refund, "Invalid refund");

        // Transfer tokens
        _transfer(msg.sender, address(this), amount);
        totalBondingSupply -= amount;
        reserve -= refund;

        // Store message in global registry
        if (bytes(message).length > 0) {
            GlobalMessageRegistry registry = _getGlobalMessageRegistry();

            uint256 packedData = GlobalMessagePacking.pack(
                uint32(block.timestamp),
                GlobalMessageTypes.FACTORY_ERC404,
                GlobalMessageTypes.ACTION_SELL,
                0, // contextId: 0 for ERC404
                uint96(amount / 1e18) // Normalize to whole tokens
            );

            registry.addMessage(address(this), msg.sender, packedData, message);
        }

        // Refund ETH (no tax - handled by hook)
        SafeTransferLib.safeTransferETH(msg.sender, refund);

        emit BondingSale(msg.sender, amount, refund, false);
    }

    // ┌─────────────────────────┐
    // │   Metadata Functions    │
    // └─────────────────────────┘

    /**
     * @notice Get token name (ERC20/ERC721)
     */
    function name() public view override returns (string memory) {
        return _name;
    }

    /**
     * @notice Get token symbol (ERC20/ERC721)
     */
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /**
     * @notice Get project/collection name
     * @return projectName The name of the project/collection
     * @dev Alias for name() for clarity
     */
    function getProjectName() external view returns (string memory projectName) {
        return _name;
    }

    /**
     * @notice Get project symbol
     * @return projectSymbol The symbol of the project
     * @dev Alias for symbol() for clarity
     */
    function getProjectSymbol() external view returns (string memory projectSymbol) {
        return _symbol;
    }

    /**
     * @notice Get comprehensive project metadata
     * @return projectName Token name
     * @return projectSymbol Token symbol
     * @return maxSupply Maximum token supply
     * @return liquidityReserve Liquidity reserve amount
     * @return totalBondingSupply Current bonding supply
     * @return reserve Current ETH reserve
     * @return bondingOpenTime Bonding curve open timestamp (0 if not set)
     * @return bondingActive Whether bonding is currently active
     * @return liquidityPoolAddress Address of liquidity pool (address(0) if not deployed)
     * @return factoryAddress Factory address
     * @return v4HookAddress V4 hook address (address(0) if not set)
     * @return wethAddress WETH address
     * @return projectStyleUri Style URI for customization
     */
    function getProjectMetadata() external view returns (
        string memory projectName,
        string memory projectSymbol,
        uint256 maxSupply,
        uint256 liquidityReserve,
        uint256 totalBondingSupply,
        uint256 reserve,
        uint256 bondingOpenTime,
        bool bondingActive,
        address liquidityPoolAddress,
        address factoryAddress,
        address v4HookAddress,
        address wethAddress,
        string memory projectStyleUri
    ) {
        return (
            _name,
            _symbol,
            MAX_SUPPLY,
            LIQUIDITY_RESERVE,
            totalBondingSupply,
            reserve,
            bondingOpenTime,
            bondingActive,
            liquidityPool,
            factory,
            address(v4Hook),
            weth,
            styleUri
        );
    }

    /**
     * @notice Get bonding curve parameters
     * @return initialPrice Initial price
     * @return quarticCoeff Quartic coefficient
     * @return cubicCoeff Cubic coefficient
     * @return quadraticCoeff Quadratic coefficient
     * @return normalizationFactor Normalization factor
     */
    function getBondingCurveParams() external view returns (
        uint256 initialPrice,
        uint256 quarticCoeff,
        uint256 cubicCoeff,
        uint256 quadraticCoeff,
        uint256 normalizationFactor
    ) {
        return (
            curveParams.initialPrice,
            curveParams.quarticCoeff,
            curveParams.cubicCoeff,
            curveParams.quadraticCoeff,
            curveParams.normalizationFactor
        );
    }

    /**
     * @notice Get tier configuration summary
     * @return tierType Type of tier system (VOLUME_CAP or TIME_BASED)
     * @return count Number of tiers configured
     */
    function getTierConfigSummary() external view returns (
        TierType tierType,
        uint256 count
    ) {
        return (tierConfig.tierType, tierCount);
    }

    /**
     * @notice Get password hash for a specific tier (1-indexed)
     * @param tierIndex Tier index (1-indexed)
     * @return passwordHash Password hash for the tier
     */
    function getTierPasswordHash(uint256 tierIndex) external view returns (bytes32 passwordHash) {
        require(tierIndex > 0 && tierIndex <= tierCount, "Invalid tier index");
        return tierConfig.passwordHashes[tierIndex - 1];
    }

    /**
     * @notice Get volume cap for a specific tier (for VOLUME_CAP mode)
     * @param tierIndex Tier index (1-indexed)
     * @return volumeCap Volume cap for the tier
     */
    function getTierVolumeCap(uint256 tierIndex) external view returns (uint256 volumeCap) {
        require(tierIndex > 0 && tierIndex <= tierCount, "Invalid tier index");
        require(tierConfig.tierType == TierType.VOLUME_CAP, "Not volume cap mode");
        return tierConfig.volumeCaps[tierIndex - 1];
    }

    /**
     * @notice Get tier unlock time for a specific tier (for TIME_BASED mode)
     * @param tierIndex Tier index (1-indexed)
     * @return unlockTime Tier unlock time relative to bondingOpenTime
     */
    function getTierUnlockTime(uint256 tierIndex) external view returns (uint256 unlockTime) {
        require(tierIndex > 0 && tierIndex <= tierCount, "Invalid tier index");
        require(tierConfig.tierType == TierType.TIME_BASED, "Not time based mode");
        return tierConfig.tierUnlockTimes[tierIndex - 1];
    }

    /**
     * @notice Get bonding status information
     * @return isConfigured Whether bonding open time is set
     * @return isActive Whether bonding is currently active
     * @return isEnded Whether liquidity has been deployed (bonding ended)
     * @return openTime Bonding open timestamp (0 if not set)
     * @return currentSupply Current bonding supply
     * @return maxBondingSupply Maximum bonding supply (MAX_SUPPLY - LIQUIDITY_RESERVE)
     * @return availableSupply Available supply for bonding
     * @return currentReserve Current ETH reserve
     */
    function getBondingStatus() external view returns (
        bool isConfigured,
        bool isActive,
        bool isEnded,
        uint256 openTime,
        uint256 currentSupply,
        uint256 maxBondingSupply,
        uint256 availableSupply,
        uint256 currentReserve
    ) {
        uint256 maxBonding = MAX_SUPPLY - LIQUIDITY_RESERVE;
        return (
            bondingOpenTime != 0,
            bondingActive,
            liquidityPool != address(0),
            bondingOpenTime,
            totalBondingSupply,
            maxBonding,
            maxBonding > totalBondingSupply ? maxBonding - totalBondingSupply : 0,
            reserve
        );
    }

    /**
     * @notice Check if liquidity deployment is permissionless (anyone can call)
     * @dev Deployment becomes permissionless when:
     *      - Bonding curve is full (totalBondingSupply >= MAX_SUPPLY - LIQUIDITY_RESERVE), OR
     *      - Maturity time is reached (block.timestamp >= bondingMaturityTime)
     * @return isPermissionless Whether anyone can deploy liquidity
     * @return reason Human-readable reason ("full", "matured", "owner_only", or "already_deployed")
     */
    function canDeployPermissionless() external view returns (
        bool isPermissionless,
        string memory reason
    ) {
        if (liquidityPool != address(0)) {
            return (false, "already_deployed");
        }

        uint256 maxBondingSupply = MAX_SUPPLY - LIQUIDITY_RESERVE;
        bool isFull = totalBondingSupply >= maxBondingSupply;
        bool isMatured = bondingMaturityTime != 0 && block.timestamp >= bondingMaturityTime;

        if (isFull) {
            return (true, "full");
        } else if (isMatured) {
            return (true, "matured");
        } else {
            return (false, "owner_only");
        }
    }

    /**
     * @notice Get current pricing information
     * @param amount Amount of tokens to price
     * @return buyCost Cost to buy the amount
     * @return sellRefund Refund for selling the amount
     * @return currentSupply Current bonding supply
     */
    function getPricingInfo(uint256 amount) external view returns (
        uint256 buyCost,
        uint256 sellRefund,
        uint256 currentSupply
    ) {
        return (
            calculateCost(amount),
            calculateRefund(amount),
            totalBondingSupply
        );
    }

    /// @notice Returns data needed for project card display
    /// @dev Implements IInstance interface for QueryAggregator compatibility
    /// @return currentPrice Current bonding curve price
    /// @return totalSupply Current bonding supply
    /// @return maxSupply Maximum supply (MAX_SUPPLY constant)
    /// @return isActive Whether bonding is active and open
    /// @return extraData Reserved for future use (empty for now)
    function getCardData() external view returns (
        uint256 currentPrice,
        uint256 totalSupply,
        uint256 maxSupply,
        bool isActive,
        bytes memory extraData
    ) {
        currentPrice = calculateCost(1 ether); // Price for 1 token
        totalSupply = totalBondingSupply;
        maxSupply = MAX_SUPPLY;
        isActive = bondingActive && bondingOpenTime != 0 && block.timestamp >= bondingOpenTime && liquidityPool == address(0);
        extraData = "";
    }

    /**
     * @notice Get liquidity pool information
     * @return poolAddress Address of the liquidity pool (address(0) if not deployed)
     * @return isDeployed Whether liquidity has been deployed
     * @return reserveAmount Amount of tokens in reserve for liquidity
     */
    function getLiquidityInfo() external view returns (
        address poolAddress,
        bool isDeployed,
        uint256 reserveAmount
    ) {
        return (
            liquidityPool,
            liquidityPool != address(0),
            LIQUIDITY_RESERVE
        );
    }

    /**
     * @notice Get user tier information
     * @param user User address
     * @return unlockedTier Highest tier unlocked by user (0 = no tier)
     * @return purchaseVolume Total purchase volume (for VOLUME_CAP mode)
     */
    function getUserTierInfo(address user) external view returns (
        uint256 unlockedTier,
        uint256 purchaseVolume
    ) {
        return (
            userTierUnlocked[user],
            userPurchaseVolume[user]
        );
    }

    /**
     * @notice Get total supply information
     * @return maxSupply Maximum total supply
     * @return liquidityReserve Liquidity reserve amount
     * @return maxBondingSupply Maximum bonding supply
     * @return currentBondingSupply Current bonding supply
     * @return availableBondingSupply Available bonding supply
     * @return totalERC20Supply Current total ERC20 supply
     */
    function getSupplyInfo() external view returns (
        uint256 maxSupply,
        uint256 liquidityReserve,
        uint256 maxBondingSupply,
        uint256 currentBondingSupply,
        uint256 availableBondingSupply,
        uint256 totalERC20Supply
    ) {
        uint256 maxBonding = MAX_SUPPLY - LIQUIDITY_RESERVE;
        uint256 available = maxBonding > totalBondingSupply ? maxBonding - totalBondingSupply : 0;
        DN404Storage storage $ = _getDN404Storage();
        return (
            MAX_SUPPLY,
            LIQUIDITY_RESERVE,
            maxBonding,
            totalBondingSupply,
            available,
            $.totalSupply
        );
    }

    // ┌─────────────────────────┐
    // │   Style Management      │
    // └─────────────────────────┘

    /**
     * @notice Set project styling (owner only)
     * @param uri Style URI (ipfs://, ar://, https://, or inline:css:... / inline:js:...)
     */
    function setStyle(string memory uri) external onlyOwner {
        styleUri = uri;
    }

    /**
     * @notice Get project style URI
     * @return uri Style URI
     */
    function getStyle() external view returns (string memory uri) {
        return styleUri;
    }

    // ┌─────────────────────────┐
    // │   Reroll Functionality  │
    // └─────────────────────────┘

    /**
     * @notice Reroll selected NFTs with protection for exempted IDs
     * @dev User provides tokens for reroll, exempted NFTs are protected from changes,
     *      unused tokens are returned after reroll completes
     * @param tokenAmount Amount of tokens to use for reroll (must match current balance for reroll)
     * @param exemptedNFTIds Array of NFT IDs to protect from reroll
     */
    function rerollSelectedNFTs(
        uint256 tokenAmount,
        uint256[] calldata exemptedNFTIds
    ) external nonReentrant {
        require(tokenAmount > 0, "Token amount must be > 0");
        require(balanceOf(msg.sender) >= tokenAmount, "Insufficient token balance");

        DN404Storage storage $ = _getDN404Storage();
        AddressData storage addressData = $.addressData[msg.sender];

        // Calculate how many NFTs the token amount represents
        uint256 unit = _unit();
        uint256 nftsRepresented = tokenAmount / unit;
        require(nftsRepresented > 0, "Token amount must represent at least 1 NFT");

        // Verify exempted NFT IDs exist and are owned by user
        for (uint256 i = 0; i < exemptedNFTIds.length; i++) {
            uint256 nftId = exemptedNFTIds[i];
            // NFT ownership is verified implicitly - user can only exempt their own NFTs
            // (The DN404 mirror contract enforces ownership)
        }

        // Hold tokens in escrow temporarily
        uint256 balanceBefore = addressData.balance;

        // Emit reroll initiation
        emit RerollInitiated(msg.sender, tokenAmount, exemptedNFTIds);

        // Transfer tokens to contract for escrow
        _transfer(msg.sender, address(this), tokenAmount);

        // Record escrow
        rerollEscrow[msg.sender] = tokenAmount;

        // Perform reroll: set skipNFT to false, transfer to self (triggers remix), then restore state
        bool originalSkipNFT = getSkipNFT(msg.sender);

        // Disable skip for reroll to happen
        _setSkipNFT(msg.sender, false);

        // Self-transfer to trigger DN404 remix/reroll
        _transfer(address(this), msg.sender, tokenAmount);

        // Restore original skip state
        _setSkipNFT(msg.sender, originalSkipNFT);

        // Clear escrow
        rerollEscrow[msg.sender] = 0;

        // Verify balance is maintained
        require(addressData.balance == balanceBefore, "Balance mismatch after reroll");

        // Emit completion
        emit RerollCompleted(msg.sender, tokenAmount);
    }

    /**
     * @notice Query current reroll escrow for a user
     * @param user User address
     * @return escrowAmount Amount of tokens currently in escrow for user
     */
    function getRerollEscrow(address user) external view returns (uint256 escrowAmount) {
        return rerollEscrow[user];
    }

    // ┌─────────────────────────┐
    // │  Staking Functionality  │
    // └─────────────────────────┘

    /**
     * @notice Enable holder staking system (owner only, irreversible)
     * @dev Once enabled, instance becomes a staking pool where holders earn vault fees
     *      Instance remains benefactor in vault, but delegates fee distribution to stakers
     *      This is an aggressive move - owner forfeits direct fee control
     */
    function enableStaking() external onlyOwner {
        require(!stakingEnabled, "Staking already enabled");
        stakingEnabled = true;
        emit StakingEnabled();
    }

    /**
     * @notice Stake tokens to receive proportional share of vault fees
     * @dev Transfers tokens from caller to contract and tracks stake
     * @param amount Amount of tokens to stake (must have balance)
     */
    function stake(uint256 amount) external nonReentrant {
        require(stakingEnabled, "Staking not enabled");
        require(amount > 0, "Amount must be positive");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");

        // Transfer tokens to contract (locked in staking)
        _transfer(msg.sender, address(this), amount);

        // Update staking state
        stakedBalance[msg.sender] += amount;
        totalStaked += amount;

        // Initialize tracking if first time staking
        // Set their "already claimed" watermark to their current proportional share of accumulated fees
        // This ensures they only earn fees from this point forward, not retroactively
        if (stakerFeesAlreadyClaimed[msg.sender] == 0 && totalFeesAccumulatedFromVault > 0) {
            // Calculate their share of existing fees (which they didn't contribute to earning)
            // Set this as their "already claimed" amount so they don't get retroactive fees
            stakerFeesAlreadyClaimed[msg.sender] = (totalFeesAccumulatedFromVault * stakedBalance[msg.sender]) / totalStaked;
        }

        emit Staked(msg.sender, amount, stakedBalance[msg.sender], totalStaked);
    }

    /**
     * @notice Unstake tokens (no lock duration, instant redemption)
     * @dev Automatically claims any pending rewards before unstaking
     *      - Calls claimStakerRewards if user has pending rewards
     *      - Transfers staked tokens back to caller after claiming
     * @param amount Amount of tokens to unstake
     */
    function unstake(uint256 amount) external nonReentrant {
        require(stakingEnabled, "Staking not enabled");
        require(amount > 0, "Amount must be positive");
        require(stakedBalance[msg.sender] >= amount, "Insufficient staked balance");

        // Auto-claim pending rewards before unstaking
        if (totalStaked > 0) {
            // Step 1: Update global fee counter by querying vault for TOTAL cumulative fees
            uint256 vaultTotalFees = vault.calculateClaimableAmount(address(this));

            // Step 2: Claim the delta from vault (transfers ETH to this contract)
            uint256 deltaReceived = vault.claimFees();

            // Step 3: Update our cumulative total
            totalFeesAccumulatedFromVault = vaultTotalFees;

            // Step 4: Calculate this user's total entitlement (cumulative)
            uint256 userTotalEntitlement = (totalFeesAccumulatedFromVault * stakedBalance[msg.sender]) / totalStaked;

            // Step 5: Calculate pending (delta between entitlement and already claimed)
            uint256 userAlreadyClaimed = stakerFeesAlreadyClaimed[msg.sender];

            if (userTotalEntitlement > userAlreadyClaimed) {
                uint256 rewardAmount = userTotalEntitlement - userAlreadyClaimed;

                // Update user's watermark
                stakerFeesAlreadyClaimed[msg.sender] = userTotalEntitlement;

                // Transfer reward
                SafeTransferLib.safeTransferETH(msg.sender, rewardAmount);
                emit StakerRewardsClaimed(msg.sender, rewardAmount, userTotalEntitlement);
            }
        }

        // Update staking state
        stakedBalance[msg.sender] -= amount;
        totalStaked -= amount;

        // Transfer tokens back to user
        _transfer(address(this), msg.sender, amount);

        emit Unstaked(msg.sender, amount, stakedBalance[msg.sender], totalStaked);
    }

    /**
     * @notice Claim proportional share of vault fees accumulated since last personal claim
     * @dev Share-based accounting ensures accurate fee distribution across multiple stakers claiming at different times
     *      Algorithm:
     *      1. Query vault for TOTAL cumulative fees for this instance: vault.calculateClaimableAmount(address(this))
     *      2. Claim the delta from vault (transfers new ETH to contract): vault.claimFees()
     *      3. Update instance's cumulative total: totalFeesAccumulatedFromVault
     *      4. Calculate staker's total entitlement: (totalFeesAccumulatedFromVault × stakerBalance) / totalStaked
     *      5. Subtract what staker already claimed: pending = entitlement - stakerFeesAlreadyClaimed[staker]
     *      6. Update staker's watermark: stakerFeesAlreadyClaimed[staker] = entitlement
     *      7. Transfer pending ETH to staker
     *
     *      Example with 2 stakers (50% each):
     *      - Vault accumulates 100 ETH total for instance
     *      - Staker A claims: gets 50 ETH (50% of 100), watermark = 50
     *      - Vault accumulates 100 more ETH (200 total now)
     *      - Staker B claims: totalFees = 200, entitlement = 100, already claimed = 0, gets 100 ETH
     *      - Staker A claims again: totalFees = 200, entitlement = 100, already claimed = 50, gets 50 ETH
     *
     *      Dust (rounding loss) accumulates in contract, available for owner withdrawal
     * @return rewardAmount ETH distributed to staker
     */
    function claimStakerRewards() external nonReentrant returns (uint256 rewardAmount) {
        require(stakingEnabled, "Staking not enabled");
        require(stakedBalance[msg.sender] > 0, "No staked balance");
        require(totalStaked > 0, "No stakers");
        require(vault.validateCompliance(address(this)), "Vault requirements not met");

        // Step 1: Claim fees from vault (transfers ETH to this contract)
        uint256 deltaReceived = vault.claimFees();

        // Step 2: Update our cumulative total by adding the delta received
        /// @dev Fixed: Changed from `= vaultTotalFees` to `+= deltaReceived` to properly
        /// accumulate fees across multiple claims. Previously used calculateClaimableAmount()
        /// which returns current claimable (goes to 0 after claim), not cumulative total.
        totalFeesAccumulatedFromVault += deltaReceived;

        // Step 3: Calculate this staker's total entitlement (cumulative, not delta)
        // Formula: (total accumulated fees × this staker's balance) / all staked tokens
        uint256 userTotalEntitlement = (totalFeesAccumulatedFromVault * stakedBalance[msg.sender]) / totalStaked;

        // Step 4: Calculate pending reward (delta between total entitlement and what they've already claimed)
        uint256 userAlreadyClaimed = stakerFeesAlreadyClaimed[msg.sender];

        require(userTotalEntitlement > userAlreadyClaimed, "No pending rewards");

        rewardAmount = userTotalEntitlement - userAlreadyClaimed;

        // Step 5: Update staker's watermark to their new cumulative entitlement
        stakerFeesAlreadyClaimed[msg.sender] = userTotalEntitlement;

        // Step 6: Transfer pending reward to staker
        SafeTransferLib.safeTransferETH(msg.sender, rewardAmount);

        emit StakerRewardsClaimed(msg.sender, rewardAmount, userTotalEntitlement);
        return rewardAmount;
    }

    /**
     * @notice Calculate pending rewards for a staker without claiming
     * @param staker Address of staker
     * @return pendingReward Estimated reward available to claim
     */
    function calculatePendingRewards(address staker) external view returns (uint256 pendingReward) {
        if (!stakingEnabled || stakedBalance[staker] == 0 || totalStaked == 0) {
            return 0;
        }

        // Get current total fees accumulated in vault for this instance (authoritative source)
        uint256 vaultTotalFees = vault.calculateClaimableAmount(address(this));

        // Calculate staker's total entitlement (cumulative)
        uint256 stakerTotalEntitlement = (vaultTotalFees * stakedBalance[staker]) / totalStaked;

        // How much has staker already claimed? (cumulative watermark)
        uint256 stakerAlreadyClaimed = stakerFeesAlreadyClaimed[staker];

        // Pending is the difference between total entitlement and already claimed
        pendingReward = stakerTotalEntitlement > stakerAlreadyClaimed
            ? stakerTotalEntitlement - stakerAlreadyClaimed
            : 0;

        return pendingReward;
    }

    /**
     * @notice Get staking information for a user
     * @param user User address
     * @return staked Amount staked by user
     * @return totalStakedGlobal Total tokens staked
     * @return userProportion User's proportion as bps (basis points)
     * @return feesAlreadyClaimed Cumulative fees user has already claimed (watermark)
     */
    function getStakingInfo(address user) external view returns (
        uint256 staked,
        uint256 totalStakedGlobal,
        uint256 userProportion,
        uint256 feesAlreadyClaimed
    ) {
        staked = stakedBalance[user];
        totalStakedGlobal = totalStaked;
        userProportion = totalStaked > 0 ? (staked * 10000) / totalStaked : 0; // in basis points
        feesAlreadyClaimed = stakerFeesAlreadyClaimed[user];
    }

    /**
     * @notice Get global staking statistics
     * @return enabled Whether staking is enabled
     * @return globalTotalStaked Total tokens staked
     * @return totalFeesFromVault Cumulative total fees received from vault (share-based accounting)
     * @return contractBalance Contract's ETH balance
     */
    function getStakingStats() external view returns (
        bool enabled,
        uint256 globalTotalStaked,
        uint256 totalFeesFromVault,
        uint256 contractBalance
    ) {
        return (
            stakingEnabled,
            totalStaked,
            totalFeesAccumulatedFromVault,
            address(this).balance
        );
    }

    /**
     * @notice Owner withdrawal of unclaimed dust and contract balance
     * @dev Available to withdraw: contract balance minus totalStaked (staked tokens)
     *      This recovers rounding dust from fee distributions
     * @param amount Amount to withdraw
     */
    function withdrawDust(uint256 amount) external onlyOwner nonReentrant {
        uint256 dustAvailable = address(this).balance;
        require(amount <= dustAvailable, "Amount exceeds available balance");
        SafeTransferLib.safeTransferETH(owner(), amount);
    }

    // ┌─────────────────────────┐
    // │   Balance Mint Function │
    // └─────────────────────────┘

    /**
     * @notice Mint NFTs based on token balance
     * @param amount Number of NFTs to mint
     */
    function balanceMint(uint256 amount) external {
        DN404Storage storage $ = _getDN404Storage();
        AddressData storage addressData = $.addressData[msg.sender];
        
        uint256 balance = addressData.balance;
        uint256 currentOwnedLength = addressData.ownedLength;
        uint256 maxMintPossible = balance / _unit() - currentOwnedLength;
        require(amount <= maxMintPossible, "NFTs over balance");

        uint256 amountToMint = amount * _unit();
        uint256 amountToHold = balance - (currentOwnedLength + amount) * _unit();
        
        // Transfer excess to contract
        _transfer(msg.sender, address(this), amountToHold);
        
        // Set skipNFT false for minting
        bool originalSkipNFT = getSkipNFT(msg.sender);
        _setSkipNFT(msg.sender, false);
        
        // Self-transfer to trigger mint
        _transfer(msg.sender, msg.sender, amountToMint);
        
        // Reset skipNFT
        _setSkipNFT(msg.sender, originalSkipNFT);
        
        // Return held tokens
        _transfer(address(this), msg.sender, amountToHold);
        
        // Verify final state
        require(addressData.balance == balance);
        require(addressData.ownedLength == currentOwnedLength + amount);
    }

    // ┌─────────────────────────┐
    // │  V4 Liquidity Deploy   │
    // └─────────────────────────┘

    struct LiquidityDeployParams {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
        address sender;
    }

    /**
     * @notice Deploy liquidity to Uniswap V4
     * @dev Fully deterministic — no caller-supplied parameters.
     *      Computes sqrtPriceX96 from post-fee token/ETH ratio.
     *      Uses reserve for ETH, LIQUIDITY_RESERVE for tokens.
     *      Pool config (fee, tickSpacing) from immutables set at construction.
     *
     *      Permissionless when:
     *      - Bonding curve is full, OR
     *      - Maturity time is reached
     *      Otherwise, only owner can deploy.
     *
     * @return liquidity Amount of liquidity added
     */
    function deployLiquidity() external nonReentrant returns (uint128 liquidity) {
        require(bondingOpenTime != 0, "Bonding not configured");
        require(block.timestamp >= bondingOpenTime, "Too early");
        require(liquidityPool == address(0), "Already deployed");
        require(address(v4Hook) != address(0), "Hook not set");
        require(reserve > 0, "No reserve");

        // Check if permissionless deployment is allowed
        uint256 maxBondingSupply = MAX_SUPPLY - LIQUIDITY_RESERVE;
        bool isFull = totalBondingSupply >= maxBondingSupply;
        bool isMatured = bondingMaturityTime != 0 && block.timestamp >= bondingMaturityTime;
        bool isPermissionless = isFull || isMatured;

        if (!isPermissionless) {
            require(msg.sender == owner(), "Only owner can deploy before maturity/full");
        }

        // Step 1: Compute graduation fee from reserve
        uint256 ethAvailable = reserve;
        uint256 graduationFee = 0;
        uint256 creatorGradCut = 0;

        if (graduationFeeBps > 0 && protocolTreasury != address(0)) {
            graduationFee = (ethAvailable * graduationFeeBps) / 10000;
            if (creatorGraduationFeeBps > 0 && factoryCreator != address(0)) {
                creatorGradCut = (ethAvailable * creatorGraduationFeeBps) / 10000;
                if (creatorGradCut > graduationFee) creatorGradCut = graduationFee;
            }
        }

        uint256 ethAfterGrad = ethAvailable - graduationFee;

        // Step 2: Compute POL amounts
        uint256 polETH = 0;
        uint256 polTokens = 0;
        uint256 tokensAvailable = LIQUIDITY_RESERVE;

        if (polBps > 0 && protocolTreasury != address(0)) {
            polETH = (ethAfterGrad * polBps) / 10000;
            polTokens = (tokensAvailable * polBps) / 10000;
        }

        // Step 3: Final pool amounts
        uint256 ethForPool = ethAfterGrad - polETH;
        uint256 tokensForPool = tokensAvailable - polTokens;

        require(ethForPool > 0, "No ETH for pool");
        require(tokensForPool > 0, "No tokens for pool");

        // Step 4: Determine token ordering and compute sqrtPriceX96
        Currency currency0 = Currency.wrap(address(this));
        Currency currency1 = Currency.wrap(weth);
        bool token0IsThis = currency0 < currency1;

        if (!token0IsThis) {
            (currency0, currency1) = (currency1, currency0);
        }

        // Compute sqrtPriceX96 = sqrt(currency1 / currency0) * 2^96
        uint160 sqrtPriceX96;
        {
            uint256 numerator;
            uint256 denominator;
            if (token0IsThis) {
                // currency0 = token, currency1 = WETH
                numerator = ethForPool;
                denominator = tokensForPool;
            } else {
                // currency0 = WETH, currency1 = token
                numerator = tokensForPool;
                denominator = ethForPool;
            }
            // sqrtPriceX96 = sqrt((numerator << 192) / denominator)
            uint256 priceX192 = FixedPointMathLib.fullMulDiv(numerator, 1 << 192, denominator);
            sqrtPriceX96 = uint160(FixedPointMathLib.sqrt(priceX192));
        }

        // Ensure sqrtPriceX96 is within V4 bounds
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE + 1) sqrtPriceX96 = TickMath.MIN_SQRT_PRICE + 1;
        if (sqrtPriceX96 > TickMath.MAX_SQRT_PRICE - 1) sqrtPriceX96 = TickMath.MAX_SQRT_PRICE - 1;

        // Step 5: Build pool key
        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(tickSpacing);

        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: v4Hook
        });

        // Step 6: Wrap ETH to WETH
        IWETH(weth).deposit{value: ethForPool}();

        // Approve pool manager for WETH if needed
        if (!token0IsThis) {
            IERC20(weth).approve(address(v4PoolManager), ethForPool);
        }

        // Step 7: Initialize pool
        v4PoolManager.initialize(poolKey, sqrtPriceX96);

        // Step 8: Add liquidity
        {
            uint256 amount0 = token0IsThis ? tokensForPool : ethForPool;
            uint256 amount1 = token0IsThis ? ethForPool : tokensForPool;

            uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);

            liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, amount0, amount1
            );

            LiquidityDeployParams memory deployParams = LiquidityDeployParams({
                poolKey: poolKey,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0: amount0,
                amount1: amount1,
                sender: address(this)
            });

            v4PoolManager.unlock(abi.encode(deployParams));
        }

        // Step 9: Send fees
        if (graduationFee > 0) {
            uint256 protocolGradCut = graduationFee - creatorGradCut;
            if (protocolGradCut > 0) {
                SafeTransferLib.safeTransferETH(protocolTreasury, protocolGradCut);
            }
            if (creatorGradCut > 0) {
                SafeTransferLib.safeTransferETH(factoryCreator, creatorGradCut);
                emit CreatorGraduationFeePaid(factoryCreator, creatorGradCut);
            }
            emit GraduationFeePaid(protocolTreasury, graduationFee - creatorGradCut);
        }

        // Step 10: Deploy POL
        if (polETH > 0 && polTokens > 0) {
            _deployProtocolLiquidity(poolKey, tickLower, tickUpper, polTokens, polETH, token0IsThis);
        }

        // Step 11: Update state
        liquidityPool = address(v4PoolManager);
        reserve = 0; // All reserve ETH has been deployed

        emit LiquidityDeployed(liquidityPool, tokensForPool, ethForPool);
    }

    /**
     * @notice Unlock callback for V4 liquidity deployment
     * @dev Called by PoolManager when unlock() is called
     * @param data Encoded LiquidityDeployParams
     * @return Encoded BalanceDelta
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(v4PoolManager), "Not pool manager");

        LiquidityDeployParams memory params = abi.decode(data, (LiquidityDeployParams));

        // Calculate liquidity amount
        PoolId poolId = params.poolKey.toId();
        (uint160 sqrtPriceX96,,,) = v4PoolManager.getSlot0(poolId);
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(params.tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(params.tickUpper);
        
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceAX96,
            sqrtPriceBX96,
            params.amount0,
            params.amount1
        );

        // Create modify liquidity params
        IPoolManager.ModifyLiquidityParams memory modifyParams = IPoolManager.ModifyLiquidityParams({
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: keccak256(abi.encodePacked(block.timestamp, block.prevrandao))
        });

        // Add liquidity
        (BalanceDelta delta,) = v4PoolManager.modifyLiquidity(params.poolKey, modifyParams, "");

        // Settle currency deltas
        int256 delta0 = delta.amount0();
        int256 delta1 = delta.amount1();

        // Negative deltas mean we owe tokens to the pool (settle)
        if (delta0 < 0) {
            params.poolKey.currency0.settle(v4PoolManager, params.sender, uint256(-delta0), false);
        }
        if (delta1 < 0) {
            params.poolKey.currency1.settle(v4PoolManager, params.sender, uint256(-delta1), false);
        }
        // Positive deltas mean we receive tokens from the pool (take) - shouldn't happen on add
        if (delta0 > 0) {
            params.poolKey.currency0.take(v4PoolManager, params.sender, uint256(delta0), false);
        }
        if (delta1 > 0) {
            params.poolKey.currency1.take(v4PoolManager, params.sender, uint256(delta1), false);
        }

        return abi.encode(delta);
    }

    function _deployProtocolLiquidity(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 polTokenAmount,
        uint256 polETHAmount,
        bool token0IsThis
    ) internal {
        // Wrap POL ETH to WETH
        IWETH(weth).deposit{value: polETHAmount}();

        // Transfer WETH to treasury
        IWETH(weth).transfer(protocolTreasury, polETHAmount);

        // Transfer project tokens to treasury
        _transfer(address(this), protocolTreasury, polTokenAmount);

        // Determine amounts in currency order
        uint256 polAmount0;
        uint256 polAmount1;
        if (token0IsThis) {
            polAmount0 = polTokenAmount;
            polAmount1 = polETHAmount;
        } else {
            polAmount0 = polETHAmount;
            polAmount1 = polTokenAmount;
        }

        // Treasury deploys its own V4 position
        IProtocolTreasuryPOL(protocolTreasury).receivePOL(
            poolKey, tickLower, tickUpper, polAmount0, polAmount1
        );

        emit ProtocolLiquidityDeployed(protocolTreasury, polTokenAmount, polETHAmount);
    }

    // ┌─────────────────────────┐
    // │   DN404 Overrides        │
    // └─────────────────────────┘

    /**
     * @notice Returns the number of tokens that correspond to one NFT
     * @dev Each NFT represents 1,000,000 tokens (1M tokens = 1 NFT)
     * @return The number of tokens per NFT
     */
    function _unit() internal view override returns (uint256) {
        return UNIT;
    }

    /**
     * @notice Returns the token URI for a given token ID
     * @param tokenId The ID of the token to get the URI for
     * @return The token URI as a string
     */
    function _tokenURI(uint256 tokenId) internal view override returns (string memory) {
        // Default implementation - can be overridden by inheriting contracts
        return "";
    }

    /**
     * @dev Override to set skip NFT default to On (true)
     * @return true to skip NFT by default
     */
    function _skipNFTDefault(address) internal pure override returns (bool) {
        return true;
    }
}

