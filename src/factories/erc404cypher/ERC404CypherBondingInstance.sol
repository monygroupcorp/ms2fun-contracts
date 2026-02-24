// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DN404} from "dn404/src/DN404.sol";
import {DN404Mirror} from "dn404/src/DN404Mirror.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {BondingCurveMath} from "../erc404/libraries/BondingCurveMath.sol";
import {CurveParamsComputer} from "../erc404/CurveParamsComputer.sol";
import {IAlignmentVault} from "../../interfaces/IAlignmentVault.sol";
import {IMasterRegistry} from "../../master/interfaces/IMasterRegistry.sol";
import {IGlobalMessageRegistry} from "../../registry/interfaces/IGlobalMessageRegistry.sol";
import {IInstanceLifecycle, TYPE_ERC404, STATE_BONDING, STATE_PAUSED, STATE_GRADUATED} from "../../interfaces/IInstanceLifecycle.sol";
import {CypherLiquidityDeployerModule} from "./CypherLiquidityDeployerModule.sol";
import {Currency} from "v4-core/types/Currency.sol";

// ── Errors ────────────────────────────────────────────────────────────────────
error AlreadyInitialized();
error AlreadyDeployed();
error BondingEnded();
error BondingNotActive();
error BondingNotConfigured();
error CannotActivateAfterLiquidityDeployed();
error ExceedsBonding();
error InsufficientBalance();
error InvalidCurveComputer();
error InvalidFactory();
error InvalidGlobalMessageRegistry();
error InvalidLiquidityDeployer();
error InvalidMaxSupply();
error InvalidOwner();
error InvalidPasswordHash();
error InvalidPassword();
error InvalidReservePercent();
error InvalidVault();
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
error TooEarly();
error TransactionExpired();
error VolumeCapExceeded();
error AmountMustBePositive();
error InvalidRefund();
error NotGraduated();
error DeadlineExpired();

/**
 * @title ERC404CypherBondingInstance
 * @notice ERC404 bonding token that graduates into an Algebra V2 (Cypher AMM) full-range LP position.
 *         No post-graduation transfer tax (unlike ZAMM version).
 */
contract ERC404CypherBondingInstance is DN404, Ownable, ReentrancyGuard, IInstanceLifecycle {

    enum TierType { VOLUME_CAP, TIME_BASED }

    struct TierConfig {
        TierType tierType;
        bytes32[] passwordHashes;
        uint256[] volumeCaps;
        uint256[] tierUnlockTimes;
    }

    // ── State ─────────────────────────────────────────────────────────────────

    bool private _initialized;
    string private _name;
    string private _symbol;

    uint256 public MAX_SUPPLY;
    uint256 public LIQUIDITY_RESERVE;
    uint256 public UNIT;

    BondingCurveMath.Params public curveParams;
    TierConfig public tierConfig;
    uint256 public tierCount;

    address public factory;
    IAlignmentVault public vault;
    IMasterRegistry public masterRegistry;
    IGlobalMessageRegistry public globalMessageRegistry;

    address public protocolTreasury;
    uint256 public bondingFeeBps;
    uint256 public graduationFeeBps;
    uint256 public creatorGraduationFeeBps;
    address public factoryCreator;

    string public styleUri;

    uint256 public bondingOpenTime;
    uint256 public bondingMaturityTime;
    bool public bondingActive;
    uint256 public totalBondingSupply;
    uint256 public reserve;

    mapping(bytes32 => uint256) public tierByPasswordHash;
    mapping(address => uint256) public userTierUnlocked;
    mapping(address => uint256) public userPurchaseVolume;

    CypherLiquidityDeployerModule public liquidityDeployer;
    CurveParamsComputer public curveComputer;

    // ── Graduation state ───────────────────────────────────────────────────────
    bool public graduated;

    // ── Algebra V2 config (stored for graduation) ──────────────────────────────
    address public weth;
    address public algebraFactory;
    address public positionManager;

    // ── Events ────────────────────────────────────────────────────────────────
    event BondingSale(address indexed user, uint256 amount, uint256 cost, bool isBuy);
    event BondingOpenTimeSet(uint256 openTime);
    event BondingMaturityTimeSet(uint256 maturityTime);
    event BondingActiveChanged(bool active);
    event LiquidityDeployed(address indexed vault, uint256 amountToken, uint256 amountETH);
    event BondingFeePaid(address indexed buyer, uint256 feeAmount);

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor() { _initialized = true; }

    // ── Initialize ────────────────────────────────────────────────────────────

    function initialize(
        string memory name_,
        string memory symbol_,
        uint256 _maxSupply,
        uint256 _liquidityReservePercent,
        BondingCurveMath.Params memory _curveParams,
        TierConfig memory _tierConfig,
        address _factory,
        address _globalMessageRegistry,
        address _vault,
        address _owner,
        string memory _styleUri,
        address _protocolTreasury,
        uint256 _bondingFeeBps,
        uint256 _graduationFeeBps,
        uint256 _creatorGraduationFeeBps,
        address _factoryCreator,
        uint256 _tokenUnit,
        address _liquidityDeployer,
        address _curveComputer,
        address _masterRegistry,
        address _weth,
        address _algebraFactory,
        address _positionManager
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        if (_maxSupply == 0) revert InvalidMaxSupply();
        if (_liquidityReservePercent >= 100) revert InvalidReservePercent();
        if (_factory == address(0)) revert InvalidFactory();
        if (_globalMessageRegistry == address(0)) revert InvalidGlobalMessageRegistry();
        if (_owner == address(0)) revert InvalidOwner();
        if (_vault == address(0)) revert InvalidVault();
        if (_tierConfig.passwordHashes.length == 0) revert NoTiers();
        if (_tierConfig.tierType == TierType.VOLUME_CAP
            ? _tierConfig.volumeCaps.length != _tierConfig.passwordHashes.length
            : _tierConfig.tierUnlockTimes.length != _tierConfig.passwordHashes.length
        ) revert TierConfigMismatch();
        if (_liquidityDeployer == address(0)) revert InvalidLiquidityDeployer();
        if (_curveComputer == address(0)) revert InvalidCurveComputer();

        _initializeOwner(_owner);

        _name = name_;
        _symbol = symbol_;
        MAX_SUPPLY = _maxSupply;
        LIQUIDITY_RESERVE = (_maxSupply * _liquidityReservePercent) / 100;
        UNIT = _tokenUnit;
        curveParams = _curveParams;
        tierConfig = _tierConfig;
        tierCount = _tierConfig.passwordHashes.length;

        factory = _factory;
        globalMessageRegistry = IGlobalMessageRegistry(_globalMessageRegistry);
        vault = IAlignmentVault(payable(_vault));
        masterRegistry = IMasterRegistry(_masterRegistry);
        styleUri = _styleUri;
        protocolTreasury = _protocolTreasury;
        bondingFeeBps = _bondingFeeBps;
        graduationFeeBps = _graduationFeeBps;
        creatorGraduationFeeBps = _creatorGraduationFeeBps;
        factoryCreator = _factoryCreator;
        liquidityDeployer = CypherLiquidityDeployerModule(payable(_liquidityDeployer));
        curveComputer = CurveParamsComputer(_curveComputer);

        weth = _weth;
        algebraFactory = _algebraFactory;
        positionManager = _positionManager;

        for (uint256 i = 0; i < _tierConfig.passwordHashes.length; i++) {
            if (_tierConfig.passwordHashes[i] == bytes32(0)) revert InvalidPasswordHash();
            tierByPasswordHash[_tierConfig.passwordHashes[i]] = i + 1;
        }

        address mirror = address(new DN404Mirror(_factory));
        _initializeDN404(_maxSupply, address(this), mirror);
    }

    // ── Owner functions ───────────────────────────────────────────────────────

    function setBondingOpenTime(uint256 timestamp) external onlyOwner {
        if (timestamp <= block.timestamp) revert TimeMustBeInFuture();
        bondingOpenTime = timestamp;
        emit BondingOpenTimeSet(timestamp);
    }

    function setBondingMaturityTime(uint256 timestamp) external onlyOwner {
        if (timestamp <= block.timestamp) revert TimeMustBeInFuture();
        if (bondingOpenTime == 0) revert OpenTimeMustBeSetFirst();
        if (timestamp <= bondingOpenTime) revert MaturityMustBeAfterOpenTime();
        bondingMaturityTime = timestamp;
        emit BondingMaturityTimeSet(timestamp);
    }

    function setBondingActive(bool _active) external onlyOwner {
        if (bondingOpenTime == 0) revert OpenTimeNotSet();
        if (_active && graduated) revert CannotActivateAfterLiquidityDeployed();
        bondingActive = _active;
        emit BondingActiveChanged(_active);
        emit StateChanged(_active ? STATE_BONDING : STATE_PAUSED);
    }

    function setStyle(string memory uri) external onlyOwner {
        styleUri = uri;
    }

    function migrateVault(address newVault) external onlyOwner {
        vault = IAlignmentVault(payable(newVault));
        masterRegistry.migrateVault(address(this), newVault);
    }

    function claimAllFees() external onlyOwner {
        address[] memory allVaults = masterRegistry.getInstanceVaults(address(this));
        for (uint256 i = 0; i < allVaults.length; i++) {
            IAlignmentVault(payable(allVaults[i])).claimFees();
        }
    }

    // ── Bonding buy/sell ──────────────────────────────────────────────────────

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
        if (graduated) revert BondingEnded();
        if (totalBondingSupply + amount > MAX_SUPPLY - LIQUIDITY_RESERVE) revert ExceedsBonding();

        uint256 tier = passwordHash == bytes32(0) ? 0 : tierByPasswordHash[passwordHash];
        if (tier == 0 && passwordHash != bytes32(0)) revert InvalidPassword();

        if (tierConfig.tierType == TierType.VOLUME_CAP) {
            uint256 cap = tier == 0 ? type(uint256).max : tierConfig.volumeCaps[tier - 1];
            if (userPurchaseVolume[msg.sender] + amount > cap) revert VolumeCapExceeded();
        } else {
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

        bool originalSkipNFT = mintNFT ? getSkipNFT(msg.sender) : false;
        if (originalSkipNFT) _setSkipNFT(msg.sender, false);

        totalBondingSupply += amount;
        _transfer(address(this), msg.sender, amount);
        reserve += totalCost;

        if (bondingFee > 0 && protocolTreasury != address(0)) {
            SafeTransferLib.safeTransferETH(protocolTreasury, bondingFee);
            emit BondingFeePaid(msg.sender, bondingFee);
        }

        if (tierConfig.tierType == TierType.VOLUME_CAP) {
            userPurchaseVolume[msg.sender] += amount;
        }

        if (messageData.length > 0) {
            globalMessageRegistry.postForAction(msg.sender, address(this), messageData);
        }

        if (originalSkipNFT) _setSkipNFT(msg.sender, true);

        if (msg.value > totalWithFee) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - totalWithFee);
        }

        emit BondingSale(msg.sender, amount, totalWithFee, true);
    }

    function sellBonding(
        uint256 amount,
        uint256 minRefund,
        bytes32 passwordHash,
        bytes calldata messageData,
        uint256 deadline
    ) external nonReentrant {
        if (deadline != 0 && block.timestamp > deadline) revert TransactionExpired();
        if (!bondingActive) revert BondingNotActive();
        if (graduated) revert BondingEnded();

        uint256 tier = passwordHash == bytes32(0) ? 0 : tierByPasswordHash[passwordHash];
        if (tier == 0 && passwordHash != bytes32(0)) revert InvalidPassword();

        if (tierConfig.tierType == TierType.TIME_BASED) {
            if (bondingOpenTime == 0) revert BondingNotConfigured();
            if (tier > 0) {
                uint256 tierUnlockTime = bondingOpenTime + tierConfig.tierUnlockTimes[tier - 1];
                if (block.timestamp < tierUnlockTime) revert TierNotAvailableYet();
            }
        }

        if (balanceOf(msg.sender) < amount) revert InsufficientBalance();

        uint256 refund = curveComputer.calculateRefund(curveParams, totalBondingSupply, amount);
        if (refund < minRefund || reserve < refund) revert InvalidRefund();

        _transfer(msg.sender, address(this), amount);
        totalBondingSupply -= amount;
        reserve -= refund;

        if (messageData.length > 0) {
            globalMessageRegistry.postForAction(msg.sender, address(this), messageData);
        }

        SafeTransferLib.safeTransferETH(msg.sender, refund);
        emit BondingSale(msg.sender, amount, refund, false);
    }

    // ── Graduation ────────────────────────────────────────────────────────────

    /**
     * @notice Deploy Algebra V2 liquidity. Permissionless when curve is full or matured;
     *         owner-only otherwise.
     * @param sqrtPriceX96  Initial pool price as Q64.96 sqrt price
     * @param deadline      Optional tx deadline (0 = no deadline)
     */
    function deployLiquidity(uint160 sqrtPriceX96, uint256 deadline) external nonReentrant {
        if (deadline != 0 && block.timestamp > deadline) revert DeadlineExpired();
        if (bondingOpenTime == 0) revert BondingNotConfigured();
        if (block.timestamp < bondingOpenTime) revert TooEarly();
        if (graduated) revert AlreadyDeployed();
        if (reserve == 0) revert NoReserve();

        uint256 maxBondingSupply = MAX_SUPPLY - LIQUIDITY_RESERVE;
        bool isFull = totalBondingSupply >= maxBondingSupply;
        bool isMatured = bondingMaturityTime != 0 && block.timestamp >= bondingMaturityTime;
        if (!isFull && !isMatured) {
            if (msg.sender != owner()) revert OnlyOwnerBeforeMaturity();
        }

        // CEI: capture and zero state before external calls
        uint256 ethToSend = reserve;
        reserve = 0;
        bondingActive = false;
        graduated = true;

        // Transfer LIQUIDITY_RESERVE tokens to deployer module
        _transfer(address(this), address(liquidityDeployer), LIQUIDITY_RESERVE);

        CypherLiquidityDeployerModule.DeployParams memory p = CypherLiquidityDeployerModule.DeployParams({
            ethReserve: ethToSend,
            tokenReserve: LIQUIDITY_RESERVE,
            sqrtPriceX96: sqrtPriceX96,
            graduationFeeBps: graduationFeeBps,
            creatorGraduationFeeBps: creatorGraduationFeeBps,
            protocolTreasury: protocolTreasury,
            factoryCreator: factoryCreator,
            token: address(this),
            weth: weth,
            vault: address(vault),
            algebraFactory: algebraFactory,
            positionManager: positionManager,
            instance: address(this)
        });

        liquidityDeployer.deployLiquidity{value: ethToSend}(p);

        emit LiquidityDeployed(address(vault), LIQUIDITY_RESERVE, ethToSend);
        emit StateChanged(STATE_GRADUATED);
    }

    // ── IInstanceLifecycle ────────────────────────────────────────────────────

    function instanceType() external pure override returns (bytes32) { return TYPE_ERC404; }

    // ── DN404 overrides ───────────────────────────────────────────────────────

    function name() public view override returns (string memory) { return _name; }
    function symbol() public view override returns (string memory) { return _symbol; }
    function _unit() internal view override returns (uint256) { return UNIT; }
    function _tokenURI(uint256) internal pure override returns (string memory) { return ""; }
    function _skipNFTDefault(address) internal pure override returns (bool) { return false; }

    receive() external payable override {}
}
