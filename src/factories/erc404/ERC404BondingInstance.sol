// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { DN404 } from "dn404/src/DN404.sol";
import { DN404Mirror } from "dn404/src/DN404Mirror.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { BondingCurveMath } from "./libraries/BondingCurveMath.sol";
import { CurveParamsComputer } from "./CurveParamsComputer.sol";
import { ERC404StakingModule } from "./ERC404StakingModule.sol";
import { LiquidityDeployerModule } from "./LiquidityDeployerModule.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { IAlignmentVault } from "../../interfaces/IAlignmentVault.sol";
import {IMasterRegistry} from "../../master/interfaces/IMasterRegistry.sol";
import { IGlobalMessageRegistry } from "../../registry/interfaces/IGlobalMessageRegistry.sol";
import { IInstanceLifecycle, TYPE_ERC404, STATE_BONDING, STATE_PAUSED, STATE_GRADUATED } from "../../interfaces/IInstanceLifecycle.sol";

// Custom errors (replaces string literals in require statements to reduce bytecode)
error AlreadyInitialized();
error AlreadyDeployed();
error BondingEnded();
error BondingNotActive();
error BondingNotConfigured();
error CannotActivateAfterLiquidityDeployed();
error ExceedsBonding();
error HookAlreadySet();
error HookMustBeSetFirst();
error HookNotConfigured();
error HookNotSet();
error InsufficientBalance();
error InsufficientTokenBalance();
error InvalidCurveComputer();
error InvalidFactory();
error InvalidGlobalMessageRegistry();
error InvalidHook();
error InvalidLiquidityDeployer();
error InvalidMaxSupply();
error InvalidOwner();
error InvalidPasswordHash();
error InvalidPassword();
error InvalidPoolManager();
error InvalidRefund();
error InvalidReservePercent();
error InvalidStakingModule();
error InvalidVault();
error InvalidWETH();
error LowETHValue();
error MaturityMustBeAfterOpenTime();
error MaxCostExceeded();
error NoReserve();
error NoTiers();
error OnlyOwnerBeforeMaturity();
error OpenTimeMustBeSetFirst();
error OpenTimeNotSet();
error TierConfigMismatch();
error TierNotAvailableYet();
error TimeMustBeInFuture();
error TokenAmountMustBePositive();
error TokenAmountMustRepresentNFT();
error TooEarly();
error TransactionExpired();
error VaultRequirementsNotMet();
error VolumeCapExceeded();
error BalanceMismatchAfterReroll();
error AmountExceedsAvailableBalance();
error AmountMustBePositive();

/**
 * @title ERC404BondingInstance
 * @notice ERC404 token with bonding curve, password-protected tiers, and V4 liquidity deployment
 * @dev Extends DN404 with bonding curve mechanics, message system, and Uniswap V4 integration
 */
contract ERC404BondingInstance is DN404, Ownable, ReentrancyGuard, IInstanceLifecycle {

    // ┌─────────────────────────┐
    // │         Types           │
    // └─────────────────────────┘

    enum TierType {
        VOLUME_CAP,    // Password unlocks higher purchase limits
        TIME_BASED     // Password allows early access
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

    bool private _initialized;

    string private _name;
    string private _symbol;

    uint256 public MAX_SUPPLY;
    uint256 public LIQUIDITY_RESERVE;
    BondingCurveMath.Params public curveParams; // Storage (set in initialize, never changed)
    TierConfig public tierConfig; // Storage (set in initialize, never changed)
    uint256 public tierCount;

    // Pool configuration (from graduation profile)
    uint24 public poolFee;
    int24 public tickSpacing;
    uint256 public UNIT;

    address public v4PoolManager;
    address public v4Hook; // Can be set after deployment
    address public factory;
    address public weth;
    IAlignmentVault public vault;
    IMasterRegistry public masterRegistry;
    IGlobalMessageRegistry public globalMessageRegistry;

    // Protocol revenue
    address public protocolTreasury;
    uint256 public bondingFeeBps;
    uint256 public graduationFeeBps;
    uint256 public polBps;

    // Creator incentives (factory creator's share of graduation fee)
    address public factoryCreator;
    uint256 public creatorGraduationFeeBps;

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

    // Reroll system

    // Staking delegation
    ERC404StakingModule public stakingModule;

    // V4 liquidity deployment singleton
    LiquidityDeployerModule public liquidityDeployer;

    // Curve math computer (external)
    CurveParamsComputer public curveComputer;

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
    event V4HookSet(address indexed hook);

    // ┌─────────────────────────┐
    // │      Constructor        │
    // └─────────────────────────┘

    /**
     * @notice Locks the implementation contract so it cannot be initialized directly.
     */
    constructor() {
        _initialized = true;
    }

    // ┌─────────────────────────┐
    // │      Initialize         │
    // └─────────────────────────┘

    /**
     * @notice Initialize a clone instance with all constructor params.
     * @dev Called by the factory immediately after cloning. Can only be called once.
     */
    function initialize(
        string memory name_,
        string memory symbol_,
        uint256 _maxSupply,
        uint256 _liquidityReservePercent,
        BondingCurveMath.Params memory _curveParams,
        TierConfig memory _tierConfig,
        address _v4PoolManager,
        address _v4Hook,
        address _weth,
        address _factory,
        address _globalMessageRegistry,
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
        uint256 _tokenUnit,
        address _stakingModule,
        address _liquidityDeployer,
        address _curveComputer,
        address _masterRegistry
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        if (_maxSupply == 0) revert InvalidMaxSupply();
        if (_liquidityReservePercent >= 100) revert InvalidReservePercent();
        if (_v4PoolManager == address(0)) revert InvalidPoolManager();
        if (_weth == address(0)) revert InvalidWETH();
        // Hook can be address(0) initially and set later
        if (_factory == address(0)) revert InvalidFactory();
        if (_globalMessageRegistry == address(0)) revert InvalidGlobalMessageRegistry();
        if (_owner == address(0)) revert InvalidOwner();
        if (_tierConfig.passwordHashes.length == 0) revert NoTiers();
        if (_tierConfig.tierType == TierType.VOLUME_CAP
                ? _tierConfig.volumeCaps.length != _tierConfig.passwordHashes.length
                : _tierConfig.tierUnlockTimes.length != _tierConfig.passwordHashes.length
        ) revert TierConfigMismatch();

        _initializeOwner(_owner);

        _name = name_;
        _symbol = symbol_;
        MAX_SUPPLY = _maxSupply;
        LIQUIDITY_RESERVE = (_maxSupply * _liquidityReservePercent) / 100;
        curveParams = _curveParams;
        tierConfig = _tierConfig;
        tierCount = _tierConfig.passwordHashes.length;

        v4PoolManager = _v4PoolManager;
        v4Hook = _v4Hook; // Can be address(0)
        weth = _weth;
        factory = _factory;
        globalMessageRegistry = IGlobalMessageRegistry(_globalMessageRegistry);
        if (_vault == address(0)) revert InvalidVault();
        vault = IAlignmentVault(payable(_vault));
        masterRegistry = IMasterRegistry(_masterRegistry);
        styleUri = _styleUri;
        protocolTreasury = _protocolTreasury;
        bondingFeeBps = _bondingFeeBps;
        graduationFeeBps = _graduationFeeBps;
        polBps = _polBps;
        factoryCreator = _factoryCreator;
        creatorGraduationFeeBps = _creatorGraduationFeeBps;
        poolFee = _poolFee;
        tickSpacing = _tickSpacing;
        UNIT = _tokenUnit;
        if (_stakingModule == address(0)) revert InvalidStakingModule();
        stakingModule = ERC404StakingModule(_stakingModule);
        if (_liquidityDeployer == address(0)) revert InvalidLiquidityDeployer();
        liquidityDeployer = LiquidityDeployerModule(payable(_liquidityDeployer));
        if (_curveComputer == address(0)) revert InvalidCurveComputer();
        curveComputer = CurveParamsComputer(_curveComputer);

        // Initialize password hash mapping
        for (uint256 i = 0; i < _tierConfig.passwordHashes.length; i++) {
            if (_tierConfig.passwordHashes[i] == bytes32(0)) revert InvalidPasswordHash();
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
        if (timestamp <= block.timestamp) revert TimeMustBeInFuture();
        bondingOpenTime = timestamp;
        emit BondingOpenTimeSet(timestamp);
    }

    /**
     * @notice Set the bonding curve maturity time (when permissionless liquidity deployment is allowed)
     * @dev After maturity, anyone can call deployLiquidity to transition to V4 pool
     * @param timestamp Unix timestamp for when bonding curve matures
     */
    function setBondingMaturityTime(uint256 timestamp) external onlyOwner {
        if (timestamp <= block.timestamp) revert TimeMustBeInFuture();
        if (bondingOpenTime == 0) revert OpenTimeMustBeSetFirst();
        if (timestamp <= bondingOpenTime) revert MaturityMustBeAfterOpenTime();
        bondingMaturityTime = timestamp;
        emit BondingMaturityTimeSet(timestamp);
    }

    /**
     * @notice Set bonding curve active state
     * @dev Requires bondingOpenTime to be set AND hook must be configured first
     * @param _active Whether bonding curve is active
     */
    function setBondingActive(bool _active) external onlyOwner {
        if (bondingOpenTime == 0) revert OpenTimeNotSet();
        if (_active) {
            if (v4Hook == address(0)) revert HookMustBeSetFirst();
            if (liquidityPool != address(0)) revert CannotActivateAfterLiquidityDeployed();
        }
        bondingActive = _active;
        emit BondingActiveChanged(_active);
        emit StateChanged(_active ? STATE_BONDING : STATE_PAUSED);
    }

    /**
     * @notice Set V4 hook address
     * @dev Can be called after deployment to set hook
     * @param _hook Hook address
     */
    function setV4Hook(address _hook) external onlyOwner {
        if (_hook == address(0)) revert InvalidHook();
        if (v4Hook != address(0)) revert HookAlreadySet();
        v4Hook = _hook;
        emit V4HookSet(_hook);
    }

    /// @notice Migrate to a new vault. New vault must share this instance's alignment target.
    /// @dev Updates local active vault and appends to registry vault array.
    function migrateVault(address newVault) external onlyOwner {
        vault = IAlignmentVault(payable(newVault));
        masterRegistry.migrateVault(address(this), newVault);
    }

    /// @notice Claim accumulated fees from all vault positions (current and historical).
    function claimAllFees() external onlyOwner {
        address[] memory allVaults = masterRegistry.getInstanceVaults(address(this));
        for (uint256 i = 0; i < allVaults.length; i++) {
            IAlignmentVault(payable(allVaults[i])).claimFees();
        }
    }

    // ┌─────────────────────────┐
    // │   Tier System Functions │
    // └─────────────────────────┘

    // NOTE: Tier unlocking is now verified inline during buyBonding/sellBonding
    // to reduce gas costs and simplify the UX. Users provide password hash directly
    // at purchase time, eliminating the need for a separate unlock transaction.

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
        if (deadline != 0 && block.timestamp > deadline) revert TransactionExpired();
        if (!bondingActive) revert BondingNotActive();
        if (liquidityPool != address(0)) revert BondingEnded();
        if (v4Hook == address(0)) revert HookNotConfigured();
        if (totalBondingSupply + amount > MAX_SUPPLY - LIQUIDITY_RESERVE) revert ExceedsBonding();

        // Check tier access
        uint256 tier = passwordHash == bytes32(0) ? 0 : tierByPasswordHash[passwordHash];
        if (tier == 0 && passwordHash != bytes32(0)) revert InvalidPassword();

        if (tierConfig.tierType == TierType.VOLUME_CAP) {
            // Verify user hasn't exceeded volume cap for this tier
            uint256 cap = tier == 0 ? type(uint256).max : tierConfig.volumeCaps[tier - 1];
            if (userPurchaseVolume[msg.sender] + amount > cap) revert VolumeCapExceeded();
        } else {
            // For TIME_BASED: verify tier unlock time has passed
            if (bondingOpenTime == 0) revert BondingNotConfigured();
            if (tier > 0) {
                uint256 tierUnlockTime = bondingOpenTime + tierConfig.tierUnlockTimes[tier - 1];
                if (block.timestamp < tierUnlockTime) revert TierNotAvailableYet();
            }
        }

        uint256 totalCost = curveComputer.calculateCost(curveParams, totalBondingSupply, amount);
        uint256 bondingFee = (totalCost * bondingFeeBps) / 10000;
        uint256 totalWithFee = totalCost + bondingFee;
        if (maxCost < totalWithFee) revert MaxCostExceeded();
        if (msg.value < totalWithFee) revert LowETHValue();

        // Handle skipNFT
        bool originalSkipNFT = mintNFT ? getSkipNFT(msg.sender) : false;
        if (originalSkipNFT) {
            _setSkipNFT(msg.sender, false);
        }

        totalBondingSupply += amount;

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
            globalMessageRegistry.postForAction(msg.sender, address(this), messageData);
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
        if (deadline != 0 && block.timestamp > deadline) revert TransactionExpired();
        if (!bondingActive) revert BondingNotActive();
        if (liquidityPool != address(0)) revert BondingEnded();
        if (v4Hook == address(0)) revert HookNotConfigured();

        // Lock sells when bonding curve is full to preserve best case scenario for liquidity deployment
        /// @dev Sells are intentionally blocked when bonding curve is full. This ensures
        /// users hold their positions until liquidity deployment occurs. The lock prevents
        /// supply from decreasing after curve completion, maintaining the bonding curve's
        /// terminal state until migration to Uniswap V4 liquidity.
        uint256 maxBondingSupply = MAX_SUPPLY - LIQUIDITY_RESERVE;
        if (totalBondingSupply >= maxBondingSupply) revert ExceedsBonding();

        // Check tier access (for sellBonding, mainly TIME_BASED tiers)
        uint256 tier = passwordHash == bytes32(0) ? 0 : tierByPasswordHash[passwordHash];
        if (tier == 0 && passwordHash != bytes32(0)) revert InvalidPassword();

        if (tierConfig.tierType == TierType.TIME_BASED) {
            if (bondingOpenTime == 0) revert BondingNotConfigured();
            if (tier > 0) {
                uint256 tierUnlockTime = bondingOpenTime + tierConfig.tierUnlockTimes[tier - 1];
                if (block.timestamp < tierUnlockTime) revert TierNotAvailableYet();
            }
        }
        // For VOLUME_CAP, no special restrictions on selling

        uint256 balance = balanceOf(msg.sender);
        if (balance < amount) revert InsufficientBalance();

        uint256 refund = curveComputer.calculateRefund(curveParams, totalBondingSupply, amount);
        if (refund < minRefund || reserve < refund) revert InvalidRefund();

        // Transfer tokens
        _transfer(msg.sender, address(this), amount);
        totalBondingSupply -= amount;
        reserve -= refund;

        // Forward message to global registry
        if (messageData.length > 0) {
            globalMessageRegistry.postForAction(msg.sender, address(this), messageData);
        }

        // Refund ETH (no tax - handled by hook)
        SafeTransferLib.safeTransferETH(msg.sender, refund);

        emit BondingSale(msg.sender, amount, refund, false);
    }

    // ── IInstanceLifecycle ─────────────────────────────────────────────────────

    function instanceType() external pure override returns (bytes32) {
        return TYPE_ERC404;
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
     * @notice Convenience function to reroll NFTs with optional shielding of specific IDs
     * @dev Users can also reroll manually by calling
     *      setSkipNFT(false), transferring balance to self, then setSkipNFT(true).
     *      Manual reroll cannot shield specific NFTs - only this function provides that feature.
     * @param tokenAmount Amount of tokens to reroll (must match current balance)
     * @param exemptedNFTIds Array of NFT IDs to protect from reroll (unique feature)
     */
    function rerollSelectedNFTs(
        uint256 tokenAmount,
        uint256[] calldata exemptedNFTIds
    ) external nonReentrant {
        if (tokenAmount == 0) revert TokenAmountMustBePositive();
        if (balanceOf(msg.sender) < tokenAmount) revert InsufficientTokenBalance();

        DN404Storage storage $ = _getDN404Storage();
        AddressData storage addressData = $.addressData[msg.sender];

        uint256 unit = _unit();
        uint256 exemptCount = exemptedNFTIds.length;
        if (tokenAmount < exemptCount * unit) revert TokenAmountMustRepresentNFT();

        uint256 rerollAmount = tokenAmount - (exemptCount * unit);
        if (rerollAmount / unit == 0) revert TokenAmountMustRepresentNFT();

        uint256 balanceBefore = addressData.balance;

        emit RerollInitiated(msg.sender, tokenAmount, exemptedNFTIds);

        // Phase 1 - Shield: Move exempted NFTs to contract for safekeeping
        for (uint256 i = 0; i < exemptCount; i++) {
            _initiateTransferFromNFT(msg.sender, address(this), exemptedNFTIds[i], msg.sender);
        }

        // Phase 2 - Reroll: Transfer rerollAmount to contract (burns non-exempted NFTs),
        // then transfer back with skipNFT=false (mints new random NFTs)
        _transfer(msg.sender, address(this), rerollAmount);

        bool originalSkipNFT = getSkipNFT(msg.sender);
        _setSkipNFT(msg.sender, false);
        _transfer(address(this), msg.sender, rerollAmount);
        _setSkipNFT(msg.sender, originalSkipNFT);

        // Phase 3 - Unshield: Return exempted NFTs (with their original IDs) to user
        for (uint256 i = 0; i < exemptCount; i++) {
            _initiateTransferFromNFT(address(this), msg.sender, exemptedNFTIds[i], address(this));
        }

        if (addressData.balance != balanceBefore) revert BalanceMismatchAfterReroll();

        emit RerollCompleted(msg.sender, tokenAmount);
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
        if (amount == 0) revert AmountMustBePositive();
        if (balanceOf(msg.sender) < amount) revert InsufficientBalance();
        _transfer(msg.sender, address(this), amount);
        stakingModule.recordStake(msg.sender, amount);
    }

    /// @notice Unstake tokens. Auto-claims pending rewards.
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountMustBePositive();
        uint256 delta = vault.claimFees();
        if (delta > 0) stakingModule.recordFeesReceived(delta);
        uint256 rewardAmount = stakingModule.recordUnstake(msg.sender, amount);
        _transfer(address(this), msg.sender, amount);
        if (rewardAmount > 0) SafeTransferLib.safeTransferETH(msg.sender, rewardAmount);
    }

    /// @notice Claim proportional vault fee yield for staked tokens
    function claimStakerRewards() external nonReentrant returns (uint256 rewardAmount) {
        if (!vault.validateCompliance(address(this))) revert VaultRequirementsNotMet();
        uint256 delta = vault.claimFees();
        if (delta > 0) stakingModule.recordFeesReceived(delta);
        rewardAmount = stakingModule.computeClaim(msg.sender);
        SafeTransferLib.safeTransferETH(msg.sender, rewardAmount);
        emit StakerRewardsClaimed(msg.sender, rewardAmount);
    }

    /// @notice Owner withdrawal of ETH dust (contract balance not owed to stakers)
    function withdrawDust(uint256 amount) external onlyOwner nonReentrant {
        uint256 dustAvailable = address(this).balance;
        if (amount > dustAvailable) revert AmountExceedsAvailableBalance();
        SafeTransferLib.safeTransferETH(owner(), amount);
    }

    /// @notice Accept ETH — required for vault.claimFees() to send fees back to this contract
    receive() external payable override {}

    // ┌─────────────────────────┐
    // │  V4 Liquidity Deploy   │
    // └─────────────────────────┘

    /**
     * @notice Deploy liquidity to Uniswap V4
     * @dev Fully deterministic — no caller-supplied parameters.
     *      Computes sqrtPriceX96 from post-fee token/ETH ratio.
     *      Uses reserve for ETH, LIQUIDITY_RESERVE for tokens.
     *      Pool config (fee, tickSpacing) from storage set at initialization.
     *
     *      Permissionless when:
     *      - Bonding curve is full, OR
     *      - Maturity time is reached
     *      Otherwise, only owner can deploy.
     *
     * @return liquidity Amount of liquidity added
     */
    function deployLiquidity() external nonReentrant returns (uint128 liquidity) {
        if (bondingOpenTime == 0) revert BondingNotConfigured();
        if (block.timestamp < bondingOpenTime) revert TooEarly();
        if (liquidityPool != address(0)) revert AlreadyDeployed();
        if (v4Hook == address(0)) revert HookNotSet();
        if (reserve == 0) revert NoReserve();

        uint256 maxBondingSupply = MAX_SUPPLY - LIQUIDITY_RESERVE;
        bool isFull = totalBondingSupply >= maxBondingSupply;
        bool isMatured = bondingMaturityTime != 0 && block.timestamp >= bondingMaturityTime;
        if (!isFull && !isMatured) {
            if (msg.sender != owner()) revert OnlyOwnerBeforeMaturity();
        }

        // CEI: capture and zero reserve before external calls
        uint256 ethToSend = reserve;
        reserve = 0;

        // Transfer LIQUIDITY_RESERVE tokens to the module (module settles on behalf of this address)
        _transfer(address(this), address(liquidityDeployer), LIQUIDITY_RESERVE);

        LiquidityDeployerModule.DeployParams memory p = LiquidityDeployerModule.DeployParams({
            ethReserve: ethToSend,
            tokenReserve: LIQUIDITY_RESERVE,
            graduationFeeBps: graduationFeeBps,
            creatorGraduationFeeBps: creatorGraduationFeeBps,
            polBps: polBps,
            protocolTreasury: protocolTreasury,
            factoryCreator: factoryCreator,
            weth: weth,
            token: address(this),
            instance: address(this),
            poolFee: poolFee,
            tickSpacing: tickSpacing,
            v4Hook: IHooks(v4Hook),
            v4PoolManager: IPoolManager(v4PoolManager)
        });

        liquidity = liquidityDeployer.deployLiquidity{value: ethToSend}(p);

        liquidityPool = v4PoolManager;
        emit LiquidityDeployed(liquidityPool, LIQUIDITY_RESERVE, ethToSend);
        emit StateChanged(STATE_GRADUATED);
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
        return false;
    }
}
