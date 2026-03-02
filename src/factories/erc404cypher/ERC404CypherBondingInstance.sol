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
import {IGatingModule} from "../../gating/IGatingModule.sol";
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
error OnlyOwnerBeforeMaturity();
error OpenTimeMustBeSetFirst();
error OpenTimeNotSet();
error TimeMustBeInFuture();
error TooEarly();
error TransactionExpired();
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

    // ┌─────────────────────────┐
    // │         Types           │
    // └─────────────────────────┘

    /// @dev Factory-computed from profile + nftCount.
    struct BondingParams {
        uint256 maxSupply;
        uint256 unit;
        uint256 liquidityReservePercent;
        BondingCurveMath.Params curve;
    }

    /// @dev Factory's own config — protocol-controlled.
    struct ProtocolParams {
        address globalMessageRegistry;
        address protocolTreasury;
        address masterRegistry;
        address liquidityDeployer;
        address curveComputer;
        address weth;
        address algebraFactory;
        address positionManager;
        uint256 bondingFeeBps;
    }

    // ── State ─────────────────────────────────────────────────────────────────

    bool private _initialized;
    string private _name;
    string private _symbol;

    uint256 public MAX_SUPPLY;
    uint256 public LIQUIDITY_RESERVE;
    uint256 public UNIT;

    BondingCurveMath.Params public curveParams;
    IGatingModule public gatingModule;

    address public factory;
    IAlignmentVault public vault;
    IMasterRegistry public masterRegistry;
    IGlobalMessageRegistry public globalMessageRegistry;

    address public protocolTreasury;
    uint256 public bondingFeeBps;

    string public styleUri;

    uint256 public bondingOpenTime;
    uint256 public bondingMaturityTime;
    bool public bondingActive;
    uint256 public totalBondingSupply;
    uint256 public reserve;

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

    /**
     * @notice Initialize bonding params. Called by factory immediately after cloning.
     * @dev Strings set via initializeMetadata(); protocol config set via initializeProtocol().
     */
    function initialize(
        address owner,
        address vault_,
        BondingParams calldata bonding,
        address _gatingModule
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        if (bonding.maxSupply == 0) revert InvalidMaxSupply();
        if (owner == address(0)) revert InvalidOwner();
        if (vault_ == address(0)) revert InvalidVault();

        _initializeOwner(owner);

        factory = msg.sender;
        vault = IAlignmentVault(payable(vault_));

        MAX_SUPPLY = bonding.maxSupply;
        LIQUIDITY_RESERVE = (bonding.maxSupply * bonding.liquidityReservePercent) / 100;
        UNIT = bonding.unit;
        curveParams = bonding.curve;

        gatingModule = IGatingModule(_gatingModule);

        address mirror = address(new DN404Mirror(msg.sender));
        _initializeDN404(bonding.maxSupply, address(this), mirror);
    }

    /**
     * @notice Set protocol params. Called by factory immediately after initialize().
     * @dev Split from initialize() to avoid Yul headStart stack-too-deep on external call encoding.
     */
    function initializeProtocol(ProtocolParams calldata protocol) external {
        require(msg.sender == factory, "Only factory");
        require(_initialized, "Not initialized");

        if (protocol.globalMessageRegistry == address(0)) revert InvalidGlobalMessageRegistry();
        if (protocol.liquidityDeployer == address(0)) revert InvalidLiquidityDeployer();
        if (protocol.curveComputer == address(0)) revert InvalidCurveComputer();

        masterRegistry = IMasterRegistry(protocol.masterRegistry);
        globalMessageRegistry = IGlobalMessageRegistry(protocol.globalMessageRegistry);
        protocolTreasury = protocol.protocolTreasury;
        bondingFeeBps = protocol.bondingFeeBps;

        liquidityDeployer = CypherLiquidityDeployerModule(payable(protocol.liquidityDeployer));
        curveComputer = CurveParamsComputer(protocol.curveComputer);
        weth = protocol.weth;
        algebraFactory = protocol.algebraFactory;
        positionManager = protocol.positionManager;
    }

    /**
     * @notice Set token name, symbol, and styleUri. Called by factory once after initialize().
     * @dev Only callable by factory, only before owner has set bondingOpenTime (i.e. during deploy).
     */
    function initializeMetadata(
        string calldata name_,
        string calldata symbol_,
        string calldata styleUri_
    ) external {
        require(msg.sender == factory, "Only factory");
        require(bondingOpenTime == 0, "Already open");
        _name = name_;
        _symbol = symbol_;
        styleUri = styleUri_;
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

        // Gating check (delegated to module; address(0) = open)
        if (address(gatingModule) != address(0)) {
            bytes memory gatingData = abi.encode(passwordHash, bondingOpenTime);
            (bool allowed,) = gatingModule.canMint(msg.sender, amount, gatingData);
            require(allowed, "Gating check failed");
            gatingModule.onMint(msg.sender, amount);
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
        // passwordHash param retained for ABI compatibility; gating is buy-only

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
            protocolTreasury: protocolTreasury,
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
