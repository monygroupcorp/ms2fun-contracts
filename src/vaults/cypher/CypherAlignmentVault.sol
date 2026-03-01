// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IAlignmentVault} from "../../interfaces/IAlignmentVault.sol";
import {IAlgebraNFTPositionManager, IAlgebraSwapRouter} from "../../interfaces/algebra/IAlgebra.sol";

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

/// @title CypherAlignmentVault
/// @notice Algebra V2 (Cypher AMM) backed alignment vault. Holds one LP position NFT.
///         Fees collected from LP, swapped to ETH, distributed via MasterChef accumulator.
contract CypherAlignmentVault is IAlignmentVault, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Errors ────────────────────────────────────────────────────────────
    error VaultAlreadyInitialized();
    error ETHOnly();
    error CreatorCutTooHigh();
    error OnlyLiquidityDeployer();
    error PositionAlreadyRegistered();
    error NoPosition();
    error ZeroContributions();

    // ── Events ────────────────────────────────────────────────────────────
    event PositionRegistered(uint256 indexed tokenId, address pool, bool tokenIsZero, address benefactor, uint256 contribution);
    event Harvested(uint256 totalFeesETH, uint256 benefactorFees, uint256 protocolFees, uint256 creatorFees);
    event DelegateSet(address indexed benefactor, address indexed delegate);

    // ── Config ────────────────────────────────────────────────────────────
    IAlgebraNFTPositionManager public positionManager;
    IAlgebraSwapRouter public swapRouter;
    address public weth;
    address public alignmentToken;
    address public factoryCreator;
    address public protocolTreasury;
    address public liquidityDeployer;

    // ── LP position ───────────────────────────────────────────────────────
    uint256 public lpTokenId;          // NFT position token ID (0 = not registered)
    address public lpPool;             // Algebra pool address
    bool public tokenIsZero;           // true if alignmentToken < weth (token0 in pool)

    // ── Economics ─────────────────────────────────────────────────────────
    uint256 public protocolYieldCutBps;  // default 500 (5%)
    uint256 public creatorYieldCutBps;   // max 500, sub-share of protocol cut

    // ── Fee buckets ───────────────────────────────────────────────────────
    uint256 public accumulatedProtocolFees;
    uint256 public accumulatedCreatorFees;
    uint256 public _totalAccumulatedFees;

    // ── MasterChef accumulator ────────────────────────────────────────────
    uint256 public totalContributions;
    uint256 public accRewardPerContribution;  // 1e18 scaled
    mapping(address => uint256) public benefactorContribution;
    mapping(address => uint256) public rewardDebt;

    // ── Delegation ────────────────────────────────────────────────────────
    mapping(address => address) public _benefactorDelegate;

    // ── Clone guard ───────────────────────────────────────────────────────
    bool private _initialized;

    // ── Init ──────────────────────────────────────────────────────────────

    function initialize(
        address _positionManager,
        address _swapRouter,
        address _weth,
        address _alignmentToken,
        address _factoryCreator,
        uint256 _creatorYieldCutBps,
        address _protocolTreasury,
        address _liquidityDeployer
    ) external {
        if (_initialized) revert VaultAlreadyInitialized();
        if (_creatorYieldCutBps > 500) revert CreatorCutTooHigh();
        _initialized = true;

        positionManager = IAlgebraNFTPositionManager(_positionManager);
        swapRouter = IAlgebraSwapRouter(_swapRouter);
        weth = _weth;
        alignmentToken = _alignmentToken;
        factoryCreator = _factoryCreator;
        creatorYieldCutBps = _creatorYieldCutBps;
        protocolTreasury = _protocolTreasury;
        liquidityDeployer = _liquidityDeployer;
        protocolYieldCutBps = 500;

        _initializeOwner(msg.sender);
    }

    // ── Receive ───────────────────────────────────────────────────────────

    receive() external payable {}

    function receiveContribution(Currency currency, uint256 amount, address benefactor)
        external payable override
    {
        if (Currency.unwrap(currency) != address(0)) revert ETHOnly();
        if (benefactor == address(0) || msg.value == 0) return;
        _addContribution(benefactor, msg.value);
        emit ContributionReceived(benefactor, msg.value);
    }

    function _addContribution(address benefactor, uint256 amount) internal {
        // Snapshot debt for new contribution amount (MasterChef pattern)
        rewardDebt[benefactor] += amount * accRewardPerContribution / 1e18;
        benefactorContribution[benefactor] += amount;
        totalContributions += amount;
    }

    // ── Position Registration (called by liquidityDeployer at graduation) ──

    function registerPosition(
        uint256 tokenId,
        address pool,
        bool _tokenIsZero,
        address benefactor,
        uint256 contributionAmount
    ) external {
        if (msg.sender != liquidityDeployer) revert OnlyLiquidityDeployer();
        if (lpTokenId != 0) revert PositionAlreadyRegistered();

        lpTokenId = tokenId;
        lpPool = pool;
        tokenIsZero = _tokenIsZero;

        _addContribution(benefactor, contributionAmount);
        emit PositionRegistered(tokenId, pool, _tokenIsZero, benefactor, contributionAmount);
    }

    // ── harvest ───────────────────────────────────────────────────────────

    /// @notice Collect LP fees, swap to ETH, distribute via accumulator.
    function harvest() external nonReentrant returns (uint256 feesETH) {
        if (totalContributions == 0) revert ZeroContributions();
        if (lpTokenId == 0) revert NoPosition();

        // Collect fees from LP position
        (uint256 amount0, uint256 amount1) = positionManager.collect(
            IAlgebraNFTPositionManager.CollectParams({
                tokenId: lpTokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        // Determine which amount is alignment token, which is WETH
        uint256 alignmentFees = tokenIsZero ? amount0 : amount1;
        uint256 wethFees = tokenIsZero ? amount1 : amount0;

        // Swap alignment token fees → WETH
        uint256 wethFromSwap;
        if (alignmentFees > 0) {
            IERC20(alignmentToken).forceApprove(address(swapRouter), alignmentFees);
            wethFromSwap = swapRouter.exactInputSingle(
                IAlgebraSwapRouter.ExactInputSingleParams({
                    tokenIn: alignmentToken,
                    tokenOut: weth,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: alignmentFees,
                    amountOutMinimum: 0,
                    limitSqrtPrice: 0
                })
            );
        }

        uint256 totalWETH = wethFees + wethFromSwap;
        if (totalWETH == 0) return 0;

        // Unwrap WETH → ETH
        IWETH9(weth).withdraw(totalWETH);
        feesETH = totalWETH;

        // Split: protocol cut, creator cut (sub-share of protocol), rest to benefactors
        uint256 protocolCut = feesETH * protocolYieldCutBps / 10000;
        uint256 creatorCut  = feesETH * creatorYieldCutBps / 10000;
        uint256 benefactorFees = feesETH - protocolCut - creatorCut;

        accumulatedProtocolFees += protocolCut;
        accumulatedCreatorFees += creatorCut;
        _totalAccumulatedFees += benefactorFees;

        // Update MasterChef accumulator
        if (benefactorFees > 0) {
            accRewardPerContribution += benefactorFees * 1e18 / totalContributions;
        }

        emit Harvested(feesETH, benefactorFees, protocolCut, creatorCut);
        emit FeesAccumulated(benefactorFees);
    }

    // ── Fee claiming ──────────────────────────────────────────────────────

    function claimFees() external override nonReentrant returns (uint256 ethClaimed) {
        ethClaimed = _claim(msg.sender);
    }

    function claimFeesAsDelegate(address[] calldata benefactors)
        external override nonReentrant
        returns (uint256 totalClaimed)
    {
        for (uint256 i = 0; i < benefactors.length; i++) {
            address b = benefactors[i];
            address delegate = _benefactorDelegate[b] == address(0) ? b : _benefactorDelegate[b];
            require(delegate == msg.sender, "NotDelegate");
            totalClaimed += _claimTo(b, msg.sender);
        }
    }

    function _claim(address benefactor) internal returns (uint256) {
        address recipient = _benefactorDelegate[benefactor] == address(0)
            ? benefactor : _benefactorDelegate[benefactor];
        return _claimTo(benefactor, recipient);
    }

    function _claimTo(address benefactor, address recipient) internal returns (uint256 ethClaimed) {
        uint256 contrib = benefactorContribution[benefactor];
        if (contrib == 0) return 0;
        uint256 pending = contrib * accRewardPerContribution / 1e18 - rewardDebt[benefactor];
        if (pending == 0) return 0;
        rewardDebt[benefactor] = contrib * accRewardPerContribution / 1e18;
        (bool ok,) = recipient.call{value: pending}("");
        require(ok, "ETH transfer failed");
        ethClaimed = pending;
        emit FeesClaimed(benefactor, pending);
    }

    // ── Governance ────────────────────────────────────────────────────────

    function withdrawProtocolFees() external {
        require(msg.sender == protocolTreasury, "Not treasury");
        uint256 amount = accumulatedProtocolFees;
        accumulatedProtocolFees = 0;
        (bool ok,) = protocolTreasury.call{value: amount}("");
        require(ok);
    }

    function withdrawCreatorFees() external {
        require(msg.sender == factoryCreator, "Not creator");
        uint256 amount = accumulatedCreatorFees;
        accumulatedCreatorFees = 0;
        (bool ok,) = factoryCreator.call{value: amount}("");
        require(ok);
    }

    function setProtocolYieldCutBps(uint256 bps) external onlyOwner {
        require(bps <= 1000, "Max 10%");
        protocolYieldCutBps = bps;
    }

    function setCreatorYieldCutBps(uint256 bps) external onlyOwner {
        require(bps <= 500, "Max 5%");
        creatorYieldCutBps = bps;
    }

    // ── IAlignmentVault compliance ────────────────────────────────────────

    function calculateClaimableAmount(address benefactor) external view override returns (uint256) {
        uint256 contrib = benefactorContribution[benefactor];
        if (contrib == 0) return 0;
        return contrib * accRewardPerContribution / 1e18 - rewardDebt[benefactor];
    }

    function getBenefactorContribution(address benefactor) external view override returns (uint256) {
        return benefactorContribution[benefactor];
    }

    function getBenefactorShares(address benefactor) external view override returns (uint256) {
        return benefactorContribution[benefactor];
    }

    function vaultType() external pure override returns (string memory) { return "CypherLP"; }
    function description() external pure override returns (string memory) {
        return "Full-range liquidity provision on Algebra V2 (Cypher AMM)";
    }
    function accumulatedFees() external view override returns (uint256) { return _totalAccumulatedFees; }
    function totalShares() external view override returns (uint256) { return totalContributions; }
    function supportsCapability(bytes32 capability) external pure override returns (bool) {
        return capability == keccak256("YIELD_GENERATION") || capability == keccak256("BENEFACTOR_DELEGATION");
    }
    function currentPolicy() external pure override returns (bytes memory) { return ""; }
    function validateCompliance(address) external pure override returns (bool) { return true; }

    function delegateBenefactor(address delegate) external override {
        _benefactorDelegate[msg.sender] = delegate;
        emit DelegateSet(msg.sender, delegate);
    }

    function getBenefactorDelegate(address benefactor) external view override returns (address) {
        address d = _benefactorDelegate[benefactor];
        return d == address(0) ? benefactor : d;
    }
}
