// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { DN404 } from "dn404/src/DN404.sol";
import { DN404Mirror } from "dn404/src/DN404Mirror.sol";
import { Ownable } from "solady/auth/Ownable.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { BondingCurveMath } from "./libraries/BondingCurveMath.sol";
import { ILiquidityDeployerModule } from "../../interfaces/ILiquidityDeployerModule.sol";
import { IAlignmentVault } from "../../interfaces/IAlignmentVault.sol";
import { IMasterRegistry } from "../../master/interfaces/IMasterRegistry.sol";
import { IGlobalMessageRegistry } from "../../registry/interfaces/IGlobalMessageRegistry.sol";
import { IInstanceLifecycle, TYPE_ERC404, STATE_BONDING, STATE_PAUSED, STATE_GRADUATED } from "../../interfaces/IInstanceLifecycle.sol";
import { IGatingModule, GatingScope } from "../../gating/IGatingModule.sol";

// ── Errors ────────────────────────────────────────────────────────────────────
error AlreadyInitialized();
error AlreadyDeployed();
error BondingEnded();
error BondingNotActive();
error BondingNotConfigured();
error CannotActivateAfterLiquidityDeployed();
error ExceedsBonding();
error GatingNotAllowed();
error InsufficientBalance();
error InsufficientTokenBalance();
error InvalidGlobalMessageRegistry();
error InvalidLiquidityDeployer();
error InvalidMaxSupply();
error InvalidOwner();
error InvalidRefund();
error InvalidVault();
error LowETHValue();
error MaturityMustBeAfterOpenTime();
error MaxCostExceeded();
error NoReserve();
error OnlyOwnerBeforeMaturity();
error OpenTimeMustBeSetFirst();
error OpenTimeNotSet();
error TimeMustBeInFuture();
error TokenAmountMustBePositive();
error TokenAmountMustRepresentNFT();
error TooEarly();
error TransactionExpired();
error BalanceMismatchAfterReroll();
error AmountMustBePositive();
error FreeMintDisabled();
error FreeMintAlreadyClaimed();
error FreeMintExhausted();
error FreeMintNotInitialized();

/**
 * @title ERC404BondingInstance
 * @notice AMM-agnostic ERC404 bonding token. Graduation delegates to an ILiquidityDeployerModule.
 */
contract ERC404BondingInstance is DN404, Ownable, ReentrancyGuard, IInstanceLifecycle {

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
        uint256 bondingFeeBps;
    }

    // ┌─────────────────────────┐
    // │      State Variables    │
    // └─────────────────────────┘

    bool private _initialized;

    string private _name;
    string private _symbol;

    uint256 public MAX_SUPPLY;
    uint256 public LIQUIDITY_RESERVE;
    BondingCurveMath.Params public curveParams;
    uint256 public UNIT;

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

    // Gating module (address(0) = open gating)
    IGatingModule public gatingModule;
    bool public gatingActive;

    // Liquidity deployer — set once in initialize(), AMM-agnostic
    ILiquidityDeployerModule public liquidityDeployer;

    // Graduation flag
    bool public graduated;

    // Free mint tranche
    uint256 public freeMintAllocation;   // NFT count reserved (0 = disabled)
    uint256 public freeMintsClaimed;     // running counter (in NFTs, not tokens)
    mapping(address => bool) public freeMintClaimed;
    GatingScope public gatingScope;
    bool private _freeMintInitialized;

    // ── Events ────────────────────────────────────────────────────────────────
    event BondingSale(address indexed user, uint256 amount, uint256 cost, bool isBuy);
    event BondingOpenTimeSet(uint256 openTime);
    event BondingMaturityTimeSet(uint256 maturityTime);
    event BondingActiveChanged(bool active);
    event LiquidityDeployed(address indexed deployer, uint256 amountToken, uint256 amountETH);
    event RerollInitiated(address indexed user, uint256 tokenAmount, uint256[] exemptedNFTIds);
    event RerollCompleted(address indexed user, uint256 tokensReturned);
    event BondingFeePaid(address indexed buyer, uint256 feeAmount);
    event FreeMintClaimed(address indexed user);

    // ┌─────────────────────────┐
    // │      Constructor        │
    // └─────────────────────────┘

    constructor() {
        _initialized = true;
    }

    // ┌─────────────────────────┐
    // │      Initialize         │
    // └─────────────────────────┘

    /**
     * @notice Initialize a clone instance. Called by factory immediately after cloning.
     */
    function initialize(
        address owner,
        address vault_,
        BondingParams calldata bonding,
        address _liquidityDeployer,
        address _gatingModule
    ) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        if (bonding.maxSupply == 0) revert InvalidMaxSupply();
        if (owner == address(0)) revert InvalidOwner();
        if (vault_ == address(0)) revert InvalidVault();
        if (_liquidityDeployer == address(0)) revert InvalidLiquidityDeployer();

        _initializeOwner(owner);

        factory = msg.sender;
        vault = IAlignmentVault(payable(vault_));

        MAX_SUPPLY = bonding.maxSupply;
        LIQUIDITY_RESERVE = (bonding.maxSupply * bonding.liquidityReservePercent) / 100;
        curveParams = bonding.curve;
        UNIT = bonding.unit;

        liquidityDeployer = ILiquidityDeployerModule(_liquidityDeployer);
        gatingModule = IGatingModule(_gatingModule);
        gatingActive = _gatingModule != address(0);

        address mirror = address(new DN404Mirror(msg.sender));
        _initializeDN404(bonding.maxSupply, address(this), mirror);
    }

    /**
     * @notice Set protocol params. Called by factory immediately after initialize().
     */
    function initializeProtocol(ProtocolParams calldata protocol) external {
        require(msg.sender == factory, "Only factory");
        require(_initialized, "Not initialized");

        if (protocol.globalMessageRegistry == address(0)) revert InvalidGlobalMessageRegistry();

        masterRegistry = IMasterRegistry(protocol.masterRegistry);
        globalMessageRegistry = IGlobalMessageRegistry(protocol.globalMessageRegistry);
        protocolTreasury = protocol.protocolTreasury;
        bondingFeeBps = protocol.bondingFeeBps;
    }

    /**
     * @notice Set token name, symbol, and styleUri. Called by factory once after initialize().
     */
    function initializeMetadata(
        string calldata name_,
        string calldata symbol_,
        string calldata styleUri_
    ) external {
        require(msg.sender == factory, "Only factory");
        require(bytes(_name).length == 0, "Already set");
        _name = name_;
        _symbol = symbol_;
        styleUri = styleUri_;
    }

    /// @notice Set free mint params. Called by factory once after initialize().
    /// @param allocation NFT count reserved for free claims (0 = disabled).
    /// @param scope      Controls which entry points the gating module guards.
    function initializeFreeMint(uint256 allocation, GatingScope scope) external {
        require(msg.sender == factory, "Only factory");
        require(!_freeMintInitialized, "Already set");
        _freeMintInitialized = true;
        freeMintAllocation = allocation;
        gatingScope = scope;
    }

    /// @notice Claim one free mint (= 1 NFT worth of tokens) at zero ETH cost.
    /// @param gatingData Passed to gatingModule.canMint if scope requires it.
    function claimFreeMint(bytes calldata gatingData) external nonReentrant {
        if (freeMintAllocation == 0) revert FreeMintDisabled();
        if (freeMintClaimed[msg.sender]) revert FreeMintAlreadyClaimed();
        if (freeMintsClaimed >= freeMintAllocation) revert FreeMintExhausted();

        if (address(gatingModule) != address(0) && gatingActive
            && gatingScope != GatingScope.PAID_ONLY) {
            (bool allowed, bool permanent) = gatingModule.canMint(msg.sender, UNIT, gatingData);
            if (!allowed) revert GatingNotAllowed();
            if (permanent) gatingActive = false;
            gatingModule.onMint(msg.sender, UNIT);
        }

        freeMintClaimed[msg.sender] = true;
        freeMintsClaimed++;
        _transfer(address(this), msg.sender, UNIT);
        emit FreeMintClaimed(msg.sender);
    }

    // ┌─────────────────────────┐
    // │    Owner Functions      │
    // └─────────────────────────┘

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

    // ┌─────────────────────────┐
    // │    Buy/Sell Functions   │
    // └─────────────────────────┘

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
        if (totalBondingSupply + amount > MAX_SUPPLY - LIQUIDITY_RESERVE - (freeMintAllocation * UNIT)) revert ExceedsBonding();

        // Gating check (address(0) or gatingActive==false = open)
        if (address(gatingModule) != address(0) && gatingActive
            && gatingScope != GatingScope.FREE_MINT_ONLY) {
            bytes memory gatingData = abi.encode(passwordHash, bondingOpenTime);
            (bool allowed, bool permanent) = gatingModule.canMint(msg.sender, amount, gatingData);
            if (!allowed) revert GatingNotAllowed();
            if (permanent) gatingActive = false;
            gatingModule.onMint(msg.sender, amount);
        }

        uint256 totalCost = BondingCurveMath.calculateCost(curveParams, totalBondingSupply, amount);
        uint256 bondingFee = (totalCost * bondingFeeBps) / 10000;
        uint256 totalWithFee = totalCost + bondingFee;
        if (maxCost < totalWithFee) revert MaxCostExceeded();
        if (msg.value < totalWithFee) revert LowETHValue();

        bool originalSkipNFT = mintNFT ? getSkipNFT(msg.sender) : false;
        if (originalSkipNFT) {
            _setSkipNFT(msg.sender, false);
        }

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

        if (originalSkipNFT) {
            _setSkipNFT(msg.sender, true);
        }

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

        uint256 maxBondingSupply = MAX_SUPPLY - LIQUIDITY_RESERVE - (freeMintAllocation * UNIT);
        if (totalBondingSupply >= maxBondingSupply) revert ExceedsBonding();

        uint256 balance = balanceOf(msg.sender);
        if (balance < amount) revert InsufficientBalance();

        uint256 refund = BondingCurveMath.calculateRefund(curveParams, totalBondingSupply, amount);
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

    // ┌─────────────────────────┐
    // │   Reroll Functionality  │
    // └─────────────────────────┘

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

        for (uint256 i = 0; i < exemptCount; i++) {
            _initiateTransferFromNFT(msg.sender, address(this), exemptedNFTIds[i], msg.sender);
        }

        _transfer(msg.sender, address(this), rerollAmount);

        bool originalSkipNFT = getSkipNFT(msg.sender);
        _setSkipNFT(msg.sender, false);
        _transfer(address(this), msg.sender, rerollAmount);
        _setSkipNFT(msg.sender, originalSkipNFT);

        for (uint256 i = 0; i < exemptCount; i++) {
            _initiateTransferFromNFT(address(this), msg.sender, exemptedNFTIds[i], address(this));
        }

        if (addressData.balance != balanceBefore) revert BalanceMismatchAfterReroll();

        emit RerollCompleted(msg.sender, tokenAmount);
    }

    // ┌─────────────────────────┐
    // │  Liquidity Deployment   │
    // └─────────────────────────┘

    /**
     * @notice Deploy liquidity via the pluggable ILiquidityDeployerModule.
     * @dev Permissionless when curve is full or matured; owner-only otherwise.
     */
    function deployLiquidity() external nonReentrant {
        if (bondingOpenTime == 0) revert BondingNotConfigured();
        if (block.timestamp < bondingOpenTime) revert TooEarly();
        if (graduated) revert AlreadyDeployed();
        if (reserve == 0) revert NoReserve();

        uint256 maxBondingSupply = MAX_SUPPLY - LIQUIDITY_RESERVE - (freeMintAllocation * UNIT);
        bool isFull = totalBondingSupply >= maxBondingSupply;
        bool isMatured = bondingMaturityTime != 0 && block.timestamp >= bondingMaturityTime;
        if (!isFull && !isMatured) {
            if (msg.sender != owner()) revert OnlyOwnerBeforeMaturity();
        }

        // CEI: capture and zero reserve before external calls
        uint256 ethToSend = reserve;
        reserve = 0;
        bondingActive = false;

        _transfer(address(this), address(liquidityDeployer), LIQUIDITY_RESERVE);

        liquidityDeployer.deployLiquidity{value: ethToSend}(
            ILiquidityDeployerModule.DeployParams({
                ethReserve: ethToSend,
                tokenReserve: LIQUIDITY_RESERVE,
                protocolTreasury: protocolTreasury,
                vault: address(vault),
                token: address(this),
                instance: address(this)
            })
        );

        graduated = true;
        emit LiquidityDeployed(address(liquidityDeployer), LIQUIDITY_RESERVE, ethToSend);
        emit StateChanged(STATE_GRADUATED);
    }

    // ── IInstanceLifecycle ─────────────────────────────────────────────────────

    function instanceType() external pure override returns (bytes32) {
        return TYPE_ERC404;
    }

    // ┌─────────────────────────┐
    // │   DN404 Overrides        │
    // └─────────────────────────┘

    function name() public view override returns (string memory) { return _name; }
    function symbol() public view override returns (string memory) { return _symbol; }
    function _unit() internal view override returns (uint256) { return UNIT; }
    function _tokenURI(uint256) internal pure override returns (string memory) { return ""; }
    function _skipNFTDefault(address) internal pure override returns (bool) { return false; }

    receive() external payable override {}
}
