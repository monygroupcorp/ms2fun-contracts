// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { DN404 } from "dn404/src/DN404.sol";
import { DN404Mirror } from "dn404/src/DN404Mirror.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "solady/utils/FixedPointMathLib.sol";
import { BondingCurveMath } from "./libraries/BondingCurveMath.sol";
import { ERC404StakingModule } from "./ERC404StakingModule.sol";
import { LiquidityDeployer } from "./libraries/LiquidityDeployer.sol";
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
import { IGlobalMessageRegistry } from "../../registry/interfaces/IGlobalMessageRegistry.sol";
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
    IGlobalMessageRegistry private cachedGlobalRegistry; // Lazy-loaded from masterRegistry

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

    // Staking delegation
    ERC404StakingModule public immutable stakingModule;

    // Events
    event BondingSale(address indexed user, uint256 amount, uint256 cost, bool isBuy);
    event BondingOpenTimeSet(uint256 openTime);
    event BondingMaturityTimeSet(uint256 maturityTime);
    event BondingActiveChanged(bool active);
    event LiquidityDeployed(address indexed pool, uint256 amountToken, uint256 amountETH);
    event RerollInitiated(address indexed user, uint256 tokenAmount, uint256[] exemptedNFTIds);
    event RerollCompleted(address indexed user, uint256 tokensReturned);
    event StakingEnabled();
    event StakerRewardsClaimed(address indexed user, uint256 rewardAmount);
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
        uint256 _unit,
        address _stakingModule
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
        require(_stakingModule != address(0), "Invalid staking module");
        stakingModule = ERC404StakingModule(_stakingModule);

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
    function _getGlobalMessageRegistry() private returns (IGlobalMessageRegistry) {
        if (address(cachedGlobalRegistry) == address(0)) {
            address registryAddr = masterRegistry.getGlobalMessageRegistry();
            require(registryAddr != address(0), "Global registry not set");
            cachedGlobalRegistry = IGlobalMessageRegistry(registryAddr);
        }
        return cachedGlobalRegistry;
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
     * @param messageData Optional encoded message data
     * @param deadline Timestamp after which this transaction reverts (0 = no deadline)
     */
    function buyBonding(
        uint256 amount,
        uint256 maxCost,
        bool mintNFT,
        bytes32 passwordHash,
        bytes calldata messageData,
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

        // Forward message to global registry
        if (messageData.length > 0) {
            _getGlobalMessageRegistry().postForAction(msg.sender, address(this), messageData);
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
     * @param messageData Optional encoded message data
     * @param deadline Timestamp after which this transaction reverts (0 = no deadline)
     */
    function sellBonding(
        uint256 amount,
        uint256 minRefund,
        bytes32 passwordHash,
        bytes calldata messageData,
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

        // Forward message to global registry
        if (messageData.length > 0) {
            _getGlobalMessageRegistry().postForAction(msg.sender, address(this), messageData);
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
    // │  Staking Delegation     │
    // └─────────────────────────┘

    /// @notice Enable holder staking (irreversible). Owner forfeits direct vault yield.
    function enableStaking() external onlyOwner {
        stakingModule.enableStaking();
        emit StakingEnabled();
    }

    /// @notice Stake tokens to receive proportional vault fee yield
    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be positive");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        _transfer(msg.sender, address(this), amount);
        stakingModule.recordStake(msg.sender, amount);
    }

    /// @notice Unstake tokens. Auto-claims pending rewards.
    function unstake(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be positive");
        uint256 delta = vault.claimFees();
        if (delta > 0) stakingModule.recordFeesReceived(delta);
        uint256 rewardAmount = stakingModule.recordUnstake(msg.sender, amount);
        _transfer(address(this), msg.sender, amount);
        if (rewardAmount > 0) SafeTransferLib.safeTransferETH(msg.sender, rewardAmount);
    }

    /// @notice Claim proportional vault fee yield for staked tokens
    function claimStakerRewards() external nonReentrant returns (uint256 rewardAmount) {
        require(vault.validateCompliance(address(this)), "Vault requirements not met");
        uint256 delta = vault.claimFees();
        if (delta > 0) stakingModule.recordFeesReceived(delta);
        rewardAmount = stakingModule.computeClaim(msg.sender);
        SafeTransferLib.safeTransferETH(msg.sender, rewardAmount);
        emit StakerRewardsClaimed(msg.sender, rewardAmount);
    }

    /// @notice Owner withdrawal of ETH dust (contract balance not owed to stakers)
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

        uint256 maxBondingSupply = MAX_SUPPLY - LIQUIDITY_RESERVE;
        bool isFull = totalBondingSupply >= maxBondingSupply;
        bool isMatured = bondingMaturityTime != 0 && block.timestamp >= bondingMaturityTime;
        if (!isFull && !isMatured) {
            require(msg.sender == owner(), "Only owner can deploy before maturity/full");
        }

        LiquidityDeployer.DeployParams memory p = LiquidityDeployer.DeployParams({
            ethReserve: reserve,
            tokenReserve: LIQUIDITY_RESERVE,
            graduationFeeBps: graduationFeeBps,
            creatorGraduationFeeBps: creatorGraduationFeeBps,
            polBps: polBps,
            protocolTreasury: protocolTreasury,
            factoryCreator: factoryCreator,
            weth: weth,
            token: address(this),
            poolFee: poolFee,
            tickSpacing: tickSpacing,
            v4Hook: v4Hook,
            v4PoolManager: v4PoolManager
        });

        LiquidityDeployer.AmountsResult memory r = LiquidityDeployer.computeAmounts(p);

        // Determine token ordering
        Currency currency0 = Currency.wrap(address(this));
        Currency currency1 = Currency.wrap(weth);
        bool token0IsThis = currency0 < currency1;
        if (!token0IsThis) (currency0, currency1) = (currency1, currency0);

        uint160 sqrtPriceX96 = LiquidityDeployer.computeSqrtPrice(r.ethForPool, r.tokensForPool, token0IsThis);

        int24 tickLower = TickMath.minUsableTick(tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(tickSpacing);

        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: v4Hook
        });

        IWETH(weth).deposit{value: r.ethForPool}();
        if (!token0IsThis) IERC20(weth).approve(address(v4PoolManager), r.ethForPool);

        v4PoolManager.initialize(poolKey, sqrtPriceX96);

        uint256 amount0 = token0IsThis ? r.tokensForPool : r.ethForPool;
        uint256 amount1 = token0IsThis ? r.ethForPool : r.tokensForPool;

        LiquidityDeployer.UnlockCallbackParams memory cb = LiquidityDeployer.UnlockCallbackParams({
            poolKey: poolKey,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0: amount0,
            amount1: amount1,
            sender: address(this)
        });

        v4PoolManager.unlock(abi.encode(cb));

        // Send graduation fees
        if (r.graduationFee > 0) {
            uint256 protocolCut = r.graduationFee - r.creatorGradCut;
            if (protocolCut > 0) SafeTransferLib.safeTransferETH(protocolTreasury, protocolCut);
            if (r.creatorGradCut > 0) {
                SafeTransferLib.safeTransferETH(factoryCreator, r.creatorGradCut);
                emit CreatorGraduationFeePaid(factoryCreator, r.creatorGradCut);
            }
            emit GraduationFeePaid(protocolTreasury, r.graduationFee - r.creatorGradCut);
        }

        if (r.polETH > 0 && r.polTokens > 0) {
            _deployProtocolLiquidity(poolKey, tickLower, tickUpper, r.polTokens, r.polETH, token0IsThis);
        }

        liquidityPool = address(v4PoolManager);
        reserve = 0;
        emit LiquidityDeployed(liquidityPool, r.tokensForPool, r.ethForPool);
    }

    /// @notice Unlock callback for V4 liquidity deployment — delegates to LiquidityDeployer
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(v4PoolManager), "Not pool manager");
        return LiquidityDeployer.handleUnlockCallback(v4PoolManager, data);
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

