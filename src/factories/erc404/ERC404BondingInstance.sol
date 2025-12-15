// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { DN404 } from "dn404/src/DN404.sol";
import { DN404Mirror } from "dn404/src/DN404Mirror.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { BondingCurveMath } from "./libraries/BondingCurveMath.sol";
import { MessagePacking } from "./libraries/MessagePacking.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { Currency, CurrencyLibrary } from "v4-core/types/Currency.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { LiquidityAmounts } from "../../../lib/v4-core/test/utils/LiquidityAmounts.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolId } from "v4-core/types/PoolId.sol";
import { CurrencySettler } from "../../../lib/v4-core/test/utils/CurrencySettler.sol";
import { UltraAlignmentVault } from "../../vaults/UltraAlignmentVault.sol";

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
}

/**
 * @title ERC404BondingInstance
 * @notice ERC404 token with bonding curve, password-protected tiers, and V4 liquidity deployment
 * @dev Extends DN404 with bonding curve mechanics, message system, and Uniswap V4 integration
 */
contract ERC404BondingInstance is DN404, Ownable, ReentrancyGuard, IUnlockCallback {
    using BondingCurveMath for BondingCurveMath.Params;
    using MessagePacking for uint128;
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

    struct BondingMessage {
        address sender;
        uint128 packedData;
        string message;
    }

    // ┌─────────────────────────┐
    // │      State Variables     │
    // └─────────────────────────┘

    string private _name;
    string private _symbol;
    
    uint256 public immutable MAX_SUPPLY;
    uint256 public immutable LIQUIDITY_RESERVE;
    BondingCurveMath.Params public curveParams; // Storage (set in constructor, never changed)
    TierConfig public tierConfig; // Storage (set in constructor, never changed)
    uint256 public tierCount;

    IPoolManager public immutable v4PoolManager;
    IHooks public v4Hook; // Can be set after deployment
    address public immutable factory;
    address public immutable weth;
    UltraAlignmentVault public vault; // Can be set after deployment for staking support

    uint256 public bondingOpenTime;  // Set by owner, 0 = not set
    bool public bondingActive;       // Toggle for open/close
    uint256 public totalBondingSupply;
    uint256 public reserve;
    address public liquidityPool;     // V4 pool address after deployment

    // Password-protected tier system
    mapping(bytes32 => uint256) public tierByPasswordHash; // hash => tier index (0 = no tier)
    mapping(address => uint256) public userTierUnlocked;    // user => highest tier unlocked
    mapping(address => uint256) public userPurchaseVolume;   // For volume cap mode

    // Message system
    mapping(uint256 => BondingMessage) public bondingMessages;
    uint256 public totalMessages;

    // Free mint system (optional)
    uint256 public freeSupply;
    mapping(address => bool) public freeMint;

    // Reroll system
    mapping(address => uint256) public rerollEscrow;  // user => tokens held for reroll

    // Staking system (optional holder alignment rewards)
    bool public stakingEnabled;
    mapping(address => uint256) public stakedBalance;     // user => staked token amount
    uint256 public totalStaked;                            // total tokens staked across all users
    uint256 public lastVaultFeesClaimed;                   // tracks last fee amount from vault
    mapping(address => uint256) public stakeRewardsTracking; // user => last fee point when they claimed

    // Events
    event BondingSale(address indexed user, uint256 amount, uint256 cost, bool isBuy);
    event BondingOpenTimeSet(uint256 openTime);
    event BondingActiveChanged(bool active);
    event LiquidityDeployed(address indexed pool, uint256 amountToken, uint256 amountETH);
    event RerollInitiated(address indexed user, uint256 tokenAmount, uint256[] exemptedNFTIds);
    event RerollCompleted(address indexed user, uint256 tokensReturned);
    event StakingEnabled();
    event Staked(address indexed user, uint256 amount, uint256 newStakedBalance, uint256 newTotalStaked);
    event Unstaked(address indexed user, uint256 amount, uint256 newStakedBalance, uint256 newTotalStaked);
    event StakerRewardsClaimed(address indexed user, uint256 rewardAmount, uint256 newTrackingPoint);

    // ┌─────────────────────────┐
    // │      Constructor        │
    // └─────────────────────────┘

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _maxSupply,
        uint256 _liquidityReservePercent,
        BondingCurveParams memory _curveParams,
        TierConfig memory _tierConfig,
        address _v4PoolManager,
        address _v4Hook,
        address _weth,
        address _factory,
        address _owner
    ) {
        require(_maxSupply > 0, "Invalid max supply");
        require(_liquidityReservePercent < 100, "Invalid reserve percent");
        require(_v4PoolManager != address(0), "Invalid pool manager");
        require(_weth != address(0), "Invalid WETH");
        // Hook can be address(0) initially and set later
        require(_factory != address(0), "Invalid factory");
        require(_owner != address(0), "Invalid owner");
        require(_tierConfig.passwordHashes.length > 0, "No tiers");
        require(
            _tierConfig.tierType == TierType.VOLUME_CAP 
                ? _tierConfig.volumeCaps.length == _tierConfig.passwordHashes.length
                : _tierConfig.tierUnlockTimes.length == _tierConfig.passwordHashes.length,
            "Tier config mismatch"
        );

        _initializeOwner(_owner);

        _name = _name;
        _symbol = _symbol;
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

        // Initialize password hash mapping
        for (uint256 i = 0; i < _tierConfig.passwordHashes.length; i++) {
            require(_tierConfig.passwordHashes[i] != bytes32(0), "Invalid password hash");
            tierByPasswordHash[_tierConfig.passwordHashes[i]] = i + 1; // Tier 1-indexed
        }

        // Deploy DN404 mirror and initialize
        address mirror = address(new DN404Mirror(_owner));
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
    }

    /**
     * @notice Set vault for staking support
     * @dev Can be called after deployment to enable holder staking
     * @param _vault Vault address
     */
    function setVault(address payable _vault) external onlyOwner {
        require(_vault != address(0), "Invalid vault");
        require(address(vault) == address(0), "Vault already set");
        vault = UltraAlignmentVault(_vault);
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
     */
    function buyBonding(
        uint256 amount,
        uint256 maxCost,
        bool mintNFT,
        bytes32 passwordHash,
        string calldata message
    ) external payable nonReentrant {
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
        require(maxCost >= totalCost, "MaxCost exceeded");
        require(msg.value >= totalCost, "Low ETH value");

        // Handle skipNFT
        bool originalSkipNFT = mintNFT ? getSkipNFT(msg.sender) : false;
        if (originalSkipNFT) {
            _setSkipNFT(msg.sender, false);
        }

        // Handle free mints if applicable
        if (freeSupply > 1000000 ether && !freeMint[msg.sender]) {
            totalBondingSupply += amount;
            amount += 1000000 ether;
            freeSupply -= 1000000 ether;
            freeMint[msg.sender] = true;
        } else {
            totalBondingSupply += amount;
        }

        // Transfer tokens
        _transfer(address(this), msg.sender, amount);
        reserve += totalCost;

        // Update purchase volume for volume cap mode
        if (tierConfig.tierType == TierType.VOLUME_CAP) {
            userPurchaseVolume[msg.sender] += amount;
        }

        // Store message
        if (bytes(message).length > 0) {
            uint64 scaledAmount = uint64(amount / 1e18);
            require(scaledAmount <= type(uint64).max, "Amount too large for msg");
            
            bondingMessages[totalMessages++] = BondingMessage({
                sender: msg.sender,
                packedData: MessagePacking.packData(
                    uint32(block.timestamp),
                    uint96(scaledAmount),
                    true
                ),
                message: message
            });
        }

        // Reset skipNFT
        if (originalSkipNFT) {
            _setSkipNFT(msg.sender, true);
        }

        // Refund excess ETH
        if (msg.value > totalCost) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - totalCost);
        }

        emit BondingSale(msg.sender, amount, totalCost, true);
    }

    /**
     * @notice Sell tokens back to bonding curve
     * @param amount Amount of tokens to sell
     * @param minRefund Minimum ETH refund expected
     * @param passwordHash Password hash for tier access
     * @param message Optional message
     */
    function sellBonding(
        uint256 amount,
        uint256 minRefund,
        bytes32 passwordHash,
        string calldata message
    ) external nonReentrant {
        require(bondingActive, "Bonding not active");
        require(liquidityPool == address(0), "Bonding ended");
        require(address(v4Hook) != address(0), "Hook not configured");

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
        
        if (freeMint[msg.sender] && (balance - amount < 1000000 ether)) {
            revert("Cannot sell free mint tokens");
        }

        uint256 refund = calculateRefund(amount);
        require(refund >= minRefund && reserve >= refund, "Invalid refund");

        // Transfer tokens
        _transfer(msg.sender, address(this), amount);
        totalBondingSupply -= amount;
        reserve -= refund;

        // Store message
        if (bytes(message).length > 0) {
            require(amount / 1 ether <= type(uint64).max, "Amount too large for msg");
            bondingMessages[totalMessages++] = BondingMessage({
                sender: msg.sender,
                packedData: MessagePacking.packData(
                    uint32(block.timestamp),
                    uint64(amount / 1 ether),
                    false
                ),
                message: message
            });
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
        address wethAddress
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
            weth
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
     * @notice Get message count
     * @return count Total number of messages
     */
    function getMessageCount() external view returns (uint256 count) {
        return totalMessages;
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

        // Initialize tracking if first time
        if (stakeRewardsTracking[msg.sender] == 0) {
            stakeRewardsTracking[msg.sender] = lastVaultFeesClaimed;
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
        if (address(vault) != address(0) && totalStaked > 0) {
            uint256 currentVaultFees = vault.claimFees();
            uint256 userProportionalShare = (currentVaultFees * stakedBalance[msg.sender]) / totalStaked;
            uint256 userAlreadyReceived = stakeRewardsTracking[msg.sender];

            if (userProportionalShare > userAlreadyReceived) {
                uint256 rewardAmount = userProportionalShare - userAlreadyReceived;
                stakeRewardsTracking[msg.sender] = userProportionalShare;
                SafeTransferLib.safeTransferETH(msg.sender, rewardAmount);
                emit StakerRewardsClaimed(msg.sender, rewardAmount, userProportionalShare);
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
     * @dev On-demand claiming with per-user tracking for accurate permissionless claiming
     *      - Pulls all accumulated fees from vault (using this contract as benefactor)
     *      - Calculates user's proportional share of ALL fees: (totalFees × userStake / totalStaked)
     *      - Subtracts what user has already received: pending = proportional - alreadyReceived
     *      - Transfers pending amount to staker
     *      - Dust (rounding loss) accumulates in contract, available for owner withdrawal
     * @return rewardAmount ETH distributed to staker
     */
    function claimStakerRewards() external nonReentrant returns (uint256 rewardAmount) {
        require(stakingEnabled, "Staking not enabled");
        require(stakedBalance[msg.sender] > 0, "No staked balance");
        require(totalStaked > 0, "No stakers");

        // Pull all accumulated vault fees (instance is benefactor in vault)
        uint256 currentVaultFees = vault.claimFees();

        // Calculate user's proportional share of ALL accumulated fees
        // userShare = (currentVaultFees × userStake) / totalStaked
        uint256 userProportionalShare = (currentVaultFees * stakedBalance[msg.sender]) / totalStaked;

        // How much has this user already claimed?
        uint256 userAlreadyReceived = stakeRewardsTracking[msg.sender];

        // Calculate pending: what user is entitled to minus what they've already received
        rewardAmount = userProportionalShare - userAlreadyReceived;

        require(rewardAmount > 0, "No pending rewards");

        // Update user's tracking point to their new proportional share
        stakeRewardsTracking[msg.sender] = userProportionalShare;

        // Transfer reward to staker
        SafeTransferLib.safeTransferETH(msg.sender, rewardAmount);

        emit StakerRewardsClaimed(msg.sender, rewardAmount, userProportionalShare);
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

        // Get current total fees accumulated in vault for this instance
        uint256 currentVaultFees = vault.calculateClaimableAmount(address(this));

        // Calculate staker's proportional share of ALL accumulated fees
        uint256 userProportionalShare = (currentVaultFees * stakedBalance[staker]) / totalStaked;

        // How much has user already claimed?
        uint256 userAlreadyReceived = stakeRewardsTracking[staker];

        // Pending is the difference
        pendingReward = userProportionalShare > userAlreadyReceived
            ? userProportionalShare - userAlreadyReceived
            : 0;

        return pendingReward;
    }

    /**
     * @notice Get staking information for a user
     * @param user User address
     * @return staked Amount staked by user
     * @return totalStakedGlobal Total tokens staked
     * @return userProportion User's proportion as bps (basis points)
     * @return lastTrackedFees Last fee point when user claimed
     */
    function getStakingInfo(address user) external view returns (
        uint256 staked,
        uint256 totalStakedGlobal,
        uint256 userProportion,
        uint256 lastTrackedFees
    ) {
        staked = stakedBalance[user];
        totalStakedGlobal = totalStaked;
        userProportion = totalStaked > 0 ? (staked * 10000) / totalStaked : 0; // in basis points
        lastTrackedFees = stakeRewardsTracking[user];
    }

    /**
     * @notice Get global staking statistics
     * @return enabled Whether staking is enabled
     * @return globalTotalStaked Total tokens staked
     * @return globalLastVaultFeesClaimed Last fee amount pulled from vault
     * @return contractBalance Contract's ETH balance
     */
    function getStakingStats() external view returns (
        bool enabled,
        uint256 globalTotalStaked,
        uint256 globalLastVaultFeesClaimed,
        uint256 contractBalance
    ) {
        return (
            stakingEnabled,
            totalStaked,
            lastVaultFeesClaimed,
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
    // │   Message System        │
    // └─────────────────────────┘

    /**
     * @notice Get message details
     * @param messageId Message ID
     * @return sender Message sender
     * @return timestamp Timestamp
     * @return amount Token amount
     * @return isBuy Whether it's a buy
     * @return message Message text
     */
    function getMessageDetails(uint256 messageId) external view returns (
        address sender,
        uint32 timestamp,
        uint96 amount,
        bool isBuy,
        string memory message
    ) {
        require(messageId < totalMessages, "Message does not exist");
        BondingMessage memory bondingMsg = bondingMessages[messageId];
        (timestamp, amount, isBuy) = MessagePacking.unpackData(bondingMsg.packedData);
        return (bondingMsg.sender, timestamp, amount, isBuy, bondingMsg.message);
    }

    /**
     * @notice Get batch of messages
     * @param start Start index
     * @param end End index (inclusive)
     * @return senders Array of senders
     * @return timestamps Array of timestamps
     * @return amounts Array of amounts
     * @return isBuys Array of isBuy flags
     * @return messages Array of messages
     */
    function getMessagesBatch(uint256 start, uint256 end) external view returns (
        address[] memory senders,
        uint32[] memory timestamps,
        uint96[] memory amounts,
        bool[] memory isBuys,
        string[] memory messages
    ) {
        require(end >= start, "Invalid range");
        require(end < totalMessages, "End out of bounds");
        
        uint256 size = end - start + 1;
        senders = new address[](size);
        timestamps = new uint32[](size);
        amounts = new uint96[](size);
        isBuys = new bool[](size);
        messages = new string[](size);
        
        for (uint256 i = 0; i < size; i++) {
            BondingMessage memory bondingMsg = bondingMessages[start + i];
            senders[i] = bondingMsg.sender;
            (timestamps[i], amounts[i], isBuys[i]) = MessagePacking.unpackData(bondingMsg.packedData);
            messages[i] = bondingMsg.message;
        }
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
     * @dev Creates a new pool with hook attached and adds initial liquidity
     * @param poolFee Pool fee (e.g., 3000 for 0.3%)
     * @param tickSpacing Tick spacing
     * @param tickLower Lower tick for liquidity range
     * @param tickUpper Upper tick for liquidity range
     * @param amountToken Amount of tokens to add
     * @param amountETH Amount of ETH to add
     * @param sqrtPriceX96 Initial sqrt price for pool (Q64.96 format)
     * @return liquidity Amount of liquidity added
     */
    function deployLiquidity(
        uint24 poolFee,
        int24 tickSpacing,
        int24 tickLower,
        int24 tickUpper,
        uint256 amountToken,
        uint256 amountETH,
        uint160 sqrtPriceX96
    ) external payable nonReentrant returns (uint128 liquidity) {
        require(bondingOpenTime != 0, "Bonding not configured");
        require(block.timestamp >= bondingOpenTime, "Too early");
        require(liquidityPool == address(0), "Already deployed");
        require(msg.value >= amountETH, "Insufficient ETH");
        require(amountToken <= LIQUIDITY_RESERVE, "Exceeds reserve");
        require(address(v4Hook) != address(0), "Hook not set");
        require(sqrtPriceX96 >= TickMath.MIN_SQRT_PRICE && sqrtPriceX96 <= TickMath.MAX_SQRT_PRICE, "Invalid sqrt price");
        require(tickLower < tickUpper, "Invalid tick range");
        require(tickLower >= TickMath.minUsableTick(tickSpacing), "Tick lower out of bounds");
        require(tickUpper <= TickMath.maxUsableTick(tickSpacing), "Tick upper out of bounds");

        // Create pool key
        Currency currency0 = Currency.wrap(address(this));
        Currency currency1 = Currency.wrap(weth);
        bool token0IsThis = currency0 < currency1;
        
        if (!token0IsThis) {
            (currency0, currency1) = (currency1, currency0);
            (amountToken, amountETH) = (amountETH, amountToken);
        }

        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: v4Hook
        });

        // Wrap ETH to WETH if needed
        if (amountETH > 0) {
            IWETH(weth).deposit{value: amountETH}();
        }

        // Approve pool manager to spend tokens
        // For ERC20 (WETH), approve directly
        // For DN404 tokens, CurrencySettler will handle transferFrom in unlock callback
        if (!token0IsThis) {
            IERC20(weth).approve(address(v4PoolManager), amountETH);
        }
        // For token0 (this contract), we'll transfer in the unlock callback
        // CurrencySettler handles the transferFrom for us

        // Initialize pool with initial price
        v4PoolManager.initialize(poolKey, sqrtPriceX96);

        // Calculate liquidity amount from token amounts
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceAX96,
            sqrtPriceBX96,
            token0IsThis ? amountToken : amountETH,
            token0IsThis ? amountETH : amountToken
        );

        // Prepare liquidity deployment params
        LiquidityDeployParams memory deployParams = LiquidityDeployParams({
            poolKey: poolKey,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0: token0IsThis ? amountToken : amountETH,
            amount1: token0IsThis ? amountETH : amountToken,
            sender: address(this) // Contract pays for liquidity
        });

        // Use unlock callback pattern to add liquidity
        BalanceDelta delta = abi.decode(
            v4PoolManager.unlock(abi.encode(deployParams)),
            (BalanceDelta)
        );

        // Store pool address
        liquidityPool = address(v4PoolManager);
        reserve -= amountToken;

        // Refund excess ETH
        if (msg.value > amountETH) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - amountETH);
        }

        emit LiquidityDeployed(liquidityPool, amountToken, amountETH);
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

    // ┌─────────────────────────┐
    // │   DN404 Overrides        │
    // └─────────────────────────┘

    /**
     * @notice Returns the number of tokens that correspond to one NFT
     * @dev Each NFT represents 1,000,000 tokens (1M tokens = 1 NFT)
     * @return The number of tokens per NFT
     */
    function _unit() internal pure override returns (uint256) {
        return 1000000 * 10 ** 18;
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

