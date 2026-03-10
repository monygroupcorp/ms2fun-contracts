// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IAlignmentVault} from "../../interfaces/IAlignmentVault.sol";

/// @notice Minimal ZAMM interface (mirrors ZAMM.sol ABI without requiring its compiler version)
interface IZAMM {
    struct PoolKey {
        uint256 id0;
        uint256 id1;
        address token0;
        address token1;
        uint256 feeOrHook;
    }

    struct Pool {
        uint112 reserve0;
        uint112 reserve1;
        uint32 blockTimestampLast;
        uint256 price0CumulativeLast;
        uint256 price1CumulativeLast;
        uint256 kLast;
        uint256 supply;
    }

    function pools(uint256 poolId) external view returns (Pool memory);
    function balanceOf(address owner, uint256 id) external view returns (uint256);
    function addLiquidity(
        PoolKey calldata poolKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amount0, uint256 amount1, uint256 liquidity);
    function removeLiquidity(
        PoolKey calldata poolKey,
        uint256 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        address to,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);
}

/// @notice Minimal zRouter interface
interface IzRouterV2 {
    function swapVZ(
        address to,
        bool exactOut,
        uint256 feeOrHook,
        address tokenIn,
        address tokenOut,
        uint256 idIn,
        uint256 idOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);
}

/// @title ZAMMAlignmentVault
/// @notice ZAMM-backed alignment vault. ETH in, ETH out. No peripherals.
contract ZAMMAlignmentVault is IAlignmentVault, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    // ── Solady ReentrancyGuard slot ─────────────────────────────────────
    // Mirrors Solady's `_REENTRANCY_GUARD_SLOT` (private constant).
    // Derived as: uint72(bytes9(keccak256("_REENTRANCY_GUARD_SLOT")))
    uint256 private constant _RG_SLOT = 0x929eee149b4bd21268;
    // Compile-time assert: if the derivation changes, the denominator is 0 → compilation fails.
    uint256 private constant _RG_SLOT_ASSERT =
        1 / (_RG_SLOT == uint256(uint72(bytes9(keccak256("_REENTRANCY_GUARD_SLOT")))) ? 1 : 0);

    // ── Errors ────────────────────────────────────────────────────────────
    error VaultAlreadyInitialized();
    error ETHOnly();
    error NoPendingETH();
    error NotDelegate();
    error ZeroContributions();
    error InsufficientOutput();
    error TransferFailed();
    error ExceedsMaxBps();
    error TreasuryNotSet();

    // ── Events ────────────────────────────────────────────────────────────
    event LiquidityAdded(uint256 ethSwapped, uint256 tokenReceived, uint256 lpMinted, uint256 callerReward);
    event Harvested(uint256 totalFees, uint256 benefactorFees, uint256 callerReward);
    event DelegateSet(address indexed benefactor, address indexed delegate);
    event ConversionRewardUpdated(uint256 newReward);
    event HarvestRewardUpdated(uint256 newReward);
    event ProtocolYieldCutUpdated(uint256 newBps);
    event ProtocolTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ProtocolFeesWithdrawn(uint256 amount);

    // ── Core config (locked post-init) ───────────────────────────────────
    address public zamm;
    address public zRouter;
    address public alignmentToken;
    IZAMM.PoolKey internal _poolKey;
    uint256 public poolId;

    // ── Protocol economics ────────────────────────────────────────────────
    address public protocolTreasury;
    uint256 public protocolYieldCutBps;  // default 100 (1%)

    // ── Principal tracking ────────────────────────────────────────────────
    uint256 public principalETH;
    uint256 public principalToken;

    // ── Pending (between conversions) ─────────────────────────────────────
    uint256 public pendingETH;
    mapping(address => uint256) public pendingContribution;
    address[] internal _pendingBenefactors;

    // ── MasterChef accumulator ────────────────────────────────────────────
    uint256 public totalContributions;
    uint256 public accRewardPerContribution;  // 1e18 scaled
    mapping(address => uint256) public benefactorContribution;
    mapping(address => uint256) public rewardDebt;

    // ── Delegation ────────────────────────────────────────────────────────
    mapping(address => address) public _benefactorDelegate;

    // ── Protocol fee bucket ───────────────────────────────────────────────
    uint256 public accumulatedProtocolFees;

    // ── Caller incentives ─────────────────────────────────────────────────
    uint256 public conversionReward;
    uint256 public harvestReward;

    // ── Clone guard ───────────────────────────────────────────────────────
    bool private _initialized;

    // ── Init ──────────────────────────────────────────────────────────────

    function initialize(
        address _zamm,
        address _zRouter,
        address _alignmentToken,
        IZAMM.PoolKey calldata key,
        address _protocolTreasury
    ) external {
        if (_initialized) revert VaultAlreadyInitialized();
        if (_protocolTreasury == address(0)) revert TreasuryNotSet();
        _initialized = true;

        zamm = _zamm;
        zRouter = _zRouter;
        alignmentToken = _alignmentToken;
        _poolKey = key;
        poolId = uint256(keccak256(abi.encode(key)));

        protocolTreasury = _protocolTreasury;
        protocolYieldCutBps = 100;

        _initializeOwner(msg.sender);
    }

    // ── Receive ───────────────────────────────────────────────────────────

    /// @dev Silently accept ETH when inside a nonReentrant call (e.g. ZAMM removeLiquidity
    ///      returning ETH, zRouter returning swap proceeds). Only track contributions when
    ///      ETH arrives outside of an active vault operation.
    receive() external payable {
        if (!_isLocked()) _trackPending(msg.sender, msg.value);
    }

    function _isLocked() internal view returns (bool locked) {
        assembly { locked := eq(sload(_RG_SLOT), address()) }
    }

    function receiveContribution(Currency currency, uint256 /*amount*/, address benefactor)
        external
        payable
        override
    {
        if (Currency.unwrap(currency) != address(0)) revert ETHOnly();
        _trackPending(benefactor, msg.value);
    }

    function _trackPending(address benefactor, uint256 amount) internal {
        if (benefactor == address(0) || amount == 0) return;
        if (pendingContribution[benefactor] == 0) {
            _pendingBenefactors.push(benefactor);
        }
        pendingContribution[benefactor] += amount;
        pendingETH += amount;
        emit ContributionReceived(benefactor, amount);
    }

    // ── View: pool key ────────────────────────────────────────────────────
    function getPoolKey() external view returns (IZAMM.PoolKey memory) {
        return _poolKey;
    }

    // ── convertAndAddLiquidity ────────────────────────────────────────────

    struct SwapLPResult {
        uint256 tokenBought;
        uint256 ethUsed;
        uint256 tokenUsed;
        uint256 lp;
    }

    /// @notice Buy alignment token and add ETH+token to ZAMM. Anyone can call (incentivized).
    function convertAndAddLiquidity(
        uint256 minTokenOut,
        uint256 minEth,
        uint256 minToken
    ) external nonReentrant returns (uint256 lpMinted) {
        uint256 totalEth = pendingETH;
        if (totalEth == 0) revert NoPendingETH();

        address[] memory benefactors = _pendingBenefactors;
        pendingETH = 0;
        delete _pendingBenefactors;

        uint256 reward = conversionReward;
        if (reward > totalEth) reward = totalEth;
        uint256 deployETH = totalEth - reward;

        IZAMM.Pool memory pool = IZAMM(zamm).pools(poolId);
        uint256 ethToSwap;
        if (pool.reserve0 == 0) {
            ethToSwap = deployETH / 2; // round down: extra wei goes to LP side
        } else {
            uint256 r0 = pool.reserve0;
            ethToSwap = FixedPointMathLib.sqrt(r0 * r0 + deployETH * r0) - r0;
        }
        uint256 ethForLP = deployETH - ethToSwap;

        SwapLPResult memory r = _swapAndAddLiquidity(ethToSwap, ethForLP, minTokenOut, minEth, minToken);

        lpMinted = r.lp;
        principalETH += r.ethUsed;
        principalToken += r.tokenUsed;

        for (uint256 i = 0; i < benefactors.length; i++) {
            address b = benefactors[i];
            uint256 contrib = pendingContribution[b];
            delete pendingContribution[b];
            if (contrib == 0) continue;

            uint256 settled = contrib * deployETH / totalEth; // round down: dust stays unallocated
            rewardDebt[b] += settled * accRewardPerContribution / 1e18; // round down: benefactor cannot over-claim
            benefactorContribution[b] += settled;
            totalContributions += settled;
        }

        if (reward > 0) {
            (bool ok,) = msg.sender.call{value: reward}("");
            if (!ok) revert TransferFailed();
        }

        emit LiquidityAdded(ethToSwap, r.tokenBought, lpMinted, reward);
    }

    function _swapAndAddLiquidity(
        uint256 ethToSwap,
        uint256 ethForLP,
        uint256 minTokenOut,
        uint256 minEth,
        uint256 minToken
    ) private returns (SwapLPResult memory r) {
        (, r.tokenBought) = IzRouterV2(zRouter).swapVZ{value: ethToSwap}(
            address(this), false, _poolKey.feeOrHook,
            address(0), alignmentToken, 0, 0,
            ethToSwap, minTokenOut, type(uint256).max
        );

        IERC20(alignmentToken).forceApprove(zamm, r.tokenBought);
        (r.ethUsed, r.tokenUsed, r.lp) = IZAMM(zamm).addLiquidity{value: ethForLP}(
            _poolKey, ethForLP, r.tokenBought, minEth, minToken, address(this), type(uint256).max
        );
    }

    function setConversionReward(uint256 amount) external onlyOwner {
        conversionReward = amount;
        emit ConversionRewardUpdated(amount);
    }

    function setHarvestReward(uint256 amount) external onlyOwner {
        harvestReward = amount;
        emit HarvestRewardUpdated(amount);
    }

    // ── harvest ───────────────────────────────────────────────────────────

    /// @notice Harvest fee growth from ZAMM pool. Anyone can call (incentivized).
    /// @param minEthOut Minimum ETH to receive from token→ETH fee swap
    function harvest(uint256 minEthOut) external nonReentrant returns (uint256 feesCollected) {
        if (totalContributions == 0) revert ZeroContributions();

        uint256 lpHeld = IZAMM(zamm).balanceOf(address(this), poolId);
        if (lpHeld == 0) return 0;

        IZAMM.Pool memory pool = IZAMM(zamm).pools(poolId);
        uint256 totalSupply = pool.supply;
        if (totalSupply == 0) return 0;

        uint256 currentETH = uint256(pool.reserve0) * lpHeld / totalSupply; // round down: conservative ETH valuation
        uint256 ethFees = currentETH > principalETH ? currentETH - principalETH : 0;
        if (ethFees == 0) return 0;

        uint256 feeLP = lpHeld * ethFees / currentETH; // round down: slightly fewer LP tokens burned
        if (feeLP == 0) return 0;

        feesCollected = _removeFeeLP(feeLP, minEthOut);

        uint256 reward = harvestReward;
        if (reward > feesCollected) reward = feesCollected;
        uint256 afterReward = feesCollected - reward;

        uint256 protocolCut = afterReward * protocolYieldCutBps / 10000; // round down: favors benefactors
        uint256 benefactorFees = afterReward - protocolCut;

        accumulatedProtocolFees += protocolCut;

        if (benefactorFees > 0 && totalContributions > 0) {
            accRewardPerContribution += benefactorFees * 1e18 / totalContributions; // round down: dust stays in vault
        }

        principalETH -= (principalETH * feeLP / lpHeld); // round down: slightly over-estimates remaining principal
        principalToken -= (principalToken * feeLP / lpHeld); // round down: slightly over-estimates remaining principal

        if (reward > 0) {
            (bool ok,) = msg.sender.call{value: reward}("");
            if (!ok) revert TransferFailed();
        }

        emit Harvested(feesCollected, benefactorFees, reward);
        emit FeesAccumulated(benefactorFees);
    }

    function _removeFeeLP(uint256 feeLP, uint256 minEthOut) private returns (uint256 feesCollected) {
        (uint256 ethRemoved, uint256 tokRemoved) = IZAMM(zamm).removeLiquidity(
            _poolKey, feeLP, 0, 0, address(this), type(uint256).max
        );
        uint256 swappedEth;
        if (tokRemoved > 0) {
            IERC20(alignmentToken).forceApprove(zRouter, tokRemoved);
            (, swappedEth) = IzRouterV2(zRouter).swapVZ(
                address(this), false, _poolKey.feeOrHook,
                alignmentToken, address(0), 0, 0,
                tokRemoved, minEthOut, type(uint256).max
            );
        }
        feesCollected = ethRemoved + swappedEth;
    }

    // ── claimFees + delegation ────────────────────────────────────────────

    function claimFees() external override nonReentrant returns (uint256 ethClaimed) {
        ethClaimed = _claim(msg.sender);
    }

    function claimFeesAsDelegate(address[] calldata benefactors)
        external
        override
        nonReentrant
        returns (uint256 totalClaimed)
    {
        for (uint256 i = 0; i < benefactors.length; i++) {
            address b = benefactors[i];
            address delegate = _benefactorDelegate[b] == address(0) ? b : _benefactorDelegate[b];
            if (delegate != msg.sender) revert NotDelegate();
            totalClaimed += _claimTo(b, msg.sender);
        }
    }

    function delegateBenefactor(address delegate) external override {
        _benefactorDelegate[msg.sender] = delegate;
        emit DelegateSet(msg.sender, delegate);
    }

    function calculateClaimableAmount(address benefactor) external view override returns (uint256) {
        uint256 contrib = benefactorContribution[benefactor];
        if (contrib == 0) return 0;
        return contrib * accRewardPerContribution / 1e18 - rewardDebt[benefactor]; // round down: favors vault
    }

    function _claim(address benefactor) internal returns (uint256 ethClaimed) {
        address recipient = _benefactorDelegate[benefactor] == address(0)
            ? benefactor
            : _benefactorDelegate[benefactor];
        return _claimTo(benefactor, recipient);
    }

    function _claimTo(address benefactor, address recipient) internal returns (uint256 ethClaimed) {
        uint256 contrib = benefactorContribution[benefactor];
        if (contrib == 0) return 0;
        uint256 pending = contrib * accRewardPerContribution / 1e18 - rewardDebt[benefactor]; // round down: favors vault
        if (pending == 0) return 0;
        rewardDebt[benefactor] = contrib * accRewardPerContribution / 1e18; // round down: benefactor cannot over-claim
        (bool ok,) = recipient.call{value: pending}("");
        if (!ok) revert TransferFailed();
        ethClaimed = pending;
        emit FeesClaimed(benefactor, pending);
    }

    // ── Governance (owner only) ───────────────────────────────────────────

    function setProtocolYieldCutBps(uint256 bps) external onlyOwner {
        if (bps > 10000) revert ExceedsMaxBps();
        protocolYieldCutBps = bps;
        emit ProtocolYieldCutUpdated(bps);
    }

    function setProtocolTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert TreasuryNotSet();
        address old = protocolTreasury;
        protocolTreasury = treasury_;
        emit ProtocolTreasuryUpdated(old, treasury_);
    }

    function withdrawProtocolFees() external {
        if (protocolTreasury == address(0)) revert TreasuryNotSet();
        uint256 amount = accumulatedProtocolFees;
        accumulatedProtocolFees = 0;
        (bool ok,) = protocolTreasury.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit ProtocolFeesWithdrawn(amount);
    }

    // ── View helpers ──────────────────────────────────────────────────────

    function lpBalance() external view returns (uint256) {
        return IZAMM(zamm).balanceOf(address(this), poolId);
    }

    // ── IAlignmentVault stubs ─────────────────────────────────────────────

    function getBenefactorContribution(address b) external view override returns (uint256) {
        return benefactorContribution[b];
    }

    function getBenefactorShares(address b) external view override returns (uint256) {
        return benefactorContribution[b];
    }

    function getBenefactorDelegate(address b) external view override returns (address) {
        return _benefactorDelegate[b] == address(0) ? b : _benefactorDelegate[b];
    }

    function vaultType() external pure override returns (string memory) {
        return "ZAMMLP";
    }

    function description() external pure override returns (string memory) {
        return "Full-range constant-product liquidity on ZAMM with proportional yield distribution";
    }

    function accumulatedFees() external view override returns (uint256) {
        return address(this).balance - pendingETH;
    }

    function totalShares() external view override returns (uint256) {
        return totalContributions;
    }

    function supportsCapability(bytes32 cap) external pure override returns (bool) {
        return cap == keccak256("YIELD_GENERATION") || cap == keccak256("BENEFACTOR_DELEGATION");
    }

    function currentPolicy() external pure override returns (bytes memory) {
        return "";
    }

    function validateCompliance(address) external pure override returns (bool) {
        return true;
    }
}
