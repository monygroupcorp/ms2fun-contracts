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
import {ZAMMLiquidityDeployerModule} from "./ZAMMLiquidityDeployerModule.sol";
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
error ZeroAccumulatedTax();

interface IZAMM_Swap {
    struct PoolKey {
        uint256 id0;
        uint256 id1;
        address token0;
        address token1;
        uint256 feeOrHook;
    }

    function swapExactIn(
        PoolKey calldata poolKey,
        uint256 amountIn,
        uint256 amountOutMin,
        bool zeroForOne,
        address to,
        uint256 deadline
    ) external returns (uint256 amountOut);
}

/**
 * @title ERC404ZAMMBondingInstance
 * @notice ERC404 bonding token that graduates into a ZAMM pool.
 *         Post-graduation, transfer taxes on ZAMM swaps accumulate in this contract
 *         and are swept to the vault via sweepTax().
 */
contract ERC404ZAMMBondingInstance is DN404, Ownable, ReentrancyGuard, IInstanceLifecycle {

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
        uint256 bondingFeeBps;
        uint256 graduationFeeBps;
        uint256 creatorGraduationFeeBps;
        address factoryCreator;
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
    uint256 public graduationFeeBps;
    uint256 public creatorGraduationFeeBps;
    address public factoryCreator;

    string public styleUri;

    uint256 public bondingOpenTime;
    uint256 public bondingMaturityTime;
    bool public bondingActive;
    uint256 public totalBondingSupply;
    uint256 public reserve;

    ZAMMLiquidityDeployerModule public liquidityDeployer;
    CurveParamsComputer public curveComputer;

    // ── Graduation / Tax state ─────────────────────────────────────────────────
    bool public graduated;
    address public zamm;                     // ZAMM singleton address (set at graduation)
    ZAMMLiquidityDeployerModule.ZAMMPoolKey public zammPoolKey; // pool key (set at graduation)
    uint256 public zammPoolId;              // keccak256(abi.encode(zammPoolKey))
    bool public tokenIsZero;               // whether this token is token0 in the ZAMM pool
    uint256 public taxBps;                 // transfer tax bps (set at graduation from factory)
    uint256 public accumulatedTax;         // tax tokens sitting in this contract

    mapping(address => bool) public transferExempt;

    // ── Events ────────────────────────────────────────────────────────────────
    event BondingSale(address indexed user, uint256 amount, uint256 cost, bool isBuy);
    event BondingOpenTimeSet(uint256 openTime);
    event BondingMaturityTimeSet(uint256 maturityTime);
    event BondingActiveChanged(bool active);
    event LiquidityDeployed(address indexed zamm, uint256 amountToken, uint256 amountETH);
    event TaxSwept(uint256 tokenAmount, uint256 ethReceived);
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
        graduationFeeBps = protocol.graduationFeeBps;
        creatorGraduationFeeBps = protocol.creatorGraduationFeeBps;
        factoryCreator = protocol.factoryCreator;

        liquidityDeployer = ZAMMLiquidityDeployerModule(payable(protocol.liquidityDeployer));
        curveComputer = CurveParamsComputer(protocol.curveComputer);
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
            require(gatingModule.canMint(msg.sender, amount, gatingData), "Gating check failed");
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

    // ── Graduation ────────────────────────────────────────────────────────────────

    /**
     * @notice Deploy ZAMM liquidity. Permissionless when curve is full or matured;
     *         owner-only otherwise.
     * @param _zamm   ZAMM singleton address
     * @param _feeOrHook  ZAMM pool feeOrHook config (e.g. 30 = 0.3%)
     * @param _taxBps Post-graduation transfer tax in bps (e.g. 100 = 1%)
     */
    function deployLiquidity(
        address _zamm,
        uint256 _feeOrHook,
        uint256 _taxBps
    ) external nonReentrant returns (uint256 lpMinted) {
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

        // CEI: capture and zero reserve before external calls
        uint256 ethToSend = reserve;
        reserve = 0;
        bondingActive = false;

        // Transfer LIQUIDITY_RESERVE tokens to deployer
        _transfer(address(this), address(liquidityDeployer), LIQUIDITY_RESERVE);

        ZAMMLiquidityDeployerModule.DeployParams memory p = ZAMMLiquidityDeployerModule.DeployParams({
            ethReserve: ethToSend,
            tokenReserve: LIQUIDITY_RESERVE,
            graduationFeeBps: graduationFeeBps,
            creatorGraduationFeeBps: creatorGraduationFeeBps,
            polBps: 0,
            protocolTreasury: protocolTreasury,
            factoryCreator: factoryCreator,
            token: address(this),
            instance: address(this),
            zamm: _zamm,
            feeOrHook: _feeOrHook
        });

        ZAMMLiquidityDeployerModule.ZAMMPoolKey memory poolKey;
        (poolKey, lpMinted) = liquidityDeployer.deployLiquidity{value: ethToSend}(p);

        // Store graduation state
        graduated = true;
        zamm = _zamm;
        zammPoolKey = poolKey;
        zammPoolId = uint256(keccak256(abi.encode(poolKey)));
        tokenIsZero = poolKey.token0 == address(this);
        taxBps = _taxBps;

        // Set transfer exemptions
        transferExempt[address(this)] = true;
        transferExempt[address(liquidityDeployer)] = true;
        transferExempt[address(vault)] = true;

        emit LiquidityDeployed(_zamm, LIQUIDITY_RESERVE, ethToSend);
        emit StateChanged(STATE_GRADUATED);
    }

    // ── Transfer tax ──────────────────────────────────────────────────────────────

    /**
     * @dev Override DN404 _transfer to apply ZAMM swap tax post-graduation.
     *      Tax fires when from == zamm (buy) or to == zamm (sell),
     *      unless either party is in transferExempt.
     */
    function _transfer(address from, address to, uint256 amount) internal override {
        if (
            graduated &&
            (from == zamm || to == zamm) &&
            !transferExempt[from] &&
            !transferExempt[to] &&
            amount > 0
        ) {
            uint256 taxAmount = (amount * taxBps) / 10000;
            if (taxAmount > 0) {
                accumulatedTax += taxAmount;
                super._transfer(from, address(this), taxAmount);
                super._transfer(from, to, amount - taxAmount);
                return;
            }
        }
        super._transfer(from, to, amount);
    }

    /**
     * @notice Swap accumulated tax tokens → ETH → vault.receiveContribution().
     *         Public, no reward. Frontend surfaces this as "sweep for better price".
     */
    function sweepTax() external nonReentrant {
        uint256 toSwap = accumulatedTax;
        if (toSwap == 0) return;
        accumulatedTax = 0;

        // Approve ZAMM to pull our tax tokens
        _approve(address(this), zamm, toSwap);

        // zeroForOne: selling our token → ETH
        // If tokenIsZero, selling token0 → token1(ETH): zeroForOne = true
        // If !tokenIsZero, selling token1(this) → token0(ETH): zeroForOne = false
        bool zeroForOne = tokenIsZero;

        IZAMM_Swap.PoolKey memory pk = IZAMM_Swap.PoolKey({
            id0: zammPoolKey.id0,
            id1: zammPoolKey.id1,
            token0: zammPoolKey.token0,
            token1: zammPoolKey.token1,
            feeOrHook: zammPoolKey.feeOrHook
        });

        uint256 ethReceived = IZAMM_Swap(zamm).swapExactIn(
            pk,
            toSwap,
            0,              // no slippage protection (tax sweep, small amounts)
            zeroForOne,
            address(this),  // ETH lands here
            type(uint256).max
        );

        if (ethReceived > 0) {
            vault.receiveContribution{value: ethReceived}(Currency.wrap(address(0)), ethReceived, address(this));
        }

        emit TaxSwept(toSwap, ethReceived);
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
