// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {IGrandCentral} from "../interfaces/IGrandCentral.sol";

contract ShareOffering is ReentrancyGuard {
    // ============ Custom Errors ============

    error Unauthorized();
    error InvalidAddress();
    error ZeroPrice();
    error ZeroShares();
    error ZeroDuration();
    error MinExceedsTotal();
    error CapBelowMin();
    error ActiveTrancheExists();
    error NotActive();
    error WindowNotClosed();
    error PastDeadline();
    error ArrayLengthMismatch();
    error CommitmentMismatch();
    error ZeroAmount();
    error IncompleteBuyers();
    error TransferFailed();
    error MintFailed();
    error OutsideWindow();
    error NotWhitelisted();
    error ExceedsSupply();
    error ExceedsCap();
    error BelowMinimum();
    error WrongETHAmount();
    error NotRefundable();
    error NoCommitment();

    // ============ Enums ============

    enum TrancheStatus { Inactive, Active, Finalized, Cancelled }

    // ============ Structs ============

    struct Tranche {
        uint256 pricePerShare;
        uint256 totalShares;
        uint256 committedShares;
        uint256 totalETHCommitted;
        uint40  startTime;
        uint40  endTime;
        uint40  finalizeDeadline;
        uint256 minShares;
        uint256 maxSharesPerAddress;
        TrancheStatus status;
        bytes32 whitelistRoot;
    }

    // ============ Immutables ============

    address public immutable dao;
    address public immutable safe;

    // ============ Constants ============

    uint256 public constant FINALIZE_GRACE = 7 days;

    // ============ State ============

    uint256 public currentTrancheId;
    mapping(uint256 => Tranche) public tranches;
    mapping(uint256 => mapping(address => uint256)) public commitments;

    // ============ Events ============

    event TrancheCreated(
        uint256 indexed trancheId,
        uint256 pricePerShare,
        uint256 totalShares,
        uint40 startTime,
        uint40 endTime,
        uint256 minShares,
        uint256 maxSharesPerAddress,
        bytes32 whitelistRoot
    );
    event Committed(uint256 indexed trancheId, address indexed buyer, uint256 shares, uint256 ethAmount);
    event TrancheFinalized(uint256 indexed trancheId, uint256 totalShares, uint256 totalETH);
    event TrancheCancelled(uint256 indexed trancheId);
    event Refunded(uint256 indexed trancheId, address indexed buyer, uint256 shares, uint256 ethAmount);

    // ============ Modifiers ============

    modifier onlyDAO() {
        if (msg.sender != dao && msg.sender != safe) revert Unauthorized();
        _;
    }

    // ============ Constructor ============

    constructor(address _dao) {
        if (_dao == address(0)) revert InvalidAddress();
        dao = _dao;
        safe = IGrandCentral(_dao).safe();
    }

    // ============ DAO Functions ============

    function createTranche(
        uint256 pricePerShare,
        uint256 totalShares,
        uint256 duration,
        uint256 minShares,
        uint256 maxSharesPerAddress,
        bytes32 whitelistRoot
    ) external onlyDAO returns (uint256 trancheId) {
        if (pricePerShare == 0) revert ZeroPrice();
        if (totalShares == 0) revert ZeroShares();
        if (duration == 0) revert ZeroDuration();
        if (minShares > 0) {
            if (minShares > totalShares) revert MinExceedsTotal();
        }
        if (maxSharesPerAddress > 0 && minShares > 0) {
            if (maxSharesPerAddress < minShares) revert CapBelowMin();
        }

        // Ensure no active tranche
        if (currentTrancheId > 0) {
            TrancheStatus s = _effectiveStatus(currentTrancheId);
            if (s != TrancheStatus.Finalized && s != TrancheStatus.Cancelled && s != TrancheStatus.Inactive) {
                revert ActiveTrancheExists();
            }
        }

        trancheId = ++currentTrancheId;
        uint40 startTime = uint40(block.timestamp);
        uint40 endTime = uint40(block.timestamp + duration);

        tranches[trancheId] = Tranche({
            pricePerShare: pricePerShare,
            totalShares: totalShares,
            committedShares: 0,
            totalETHCommitted: 0,
            startTime: startTime,
            endTime: endTime,
            finalizeDeadline: uint40(endTime + FINALIZE_GRACE),
            minShares: minShares,
            maxSharesPerAddress: maxSharesPerAddress,
            status: TrancheStatus.Active,
            whitelistRoot: whitelistRoot
        });

        emit TrancheCreated(
            trancheId, pricePerShare, totalShares,
            startTime, endTime, minShares, maxSharesPerAddress, whitelistRoot
        );
    }

    // slither-disable-next-line timestamp
    function finalize(
        uint256 trancheId,
        address[] calldata buyers,
        uint256[] calldata amounts
    ) external onlyDAO nonReentrant {
        Tranche storage t = tranches[trancheId];
        if (t.status != TrancheStatus.Active) revert NotActive();
        if (block.timestamp <= t.endTime) revert WindowNotClosed();
        if (block.timestamp > t.finalizeDeadline) revert PastDeadline();
        if (buyers.length != amounts.length) revert ArrayLengthMismatch();

        // Verify buyer arrays match commitments
        // slither-disable-next-line uninitialized-local
        uint256 totalShares;
        for (uint256 i = 0; i < buyers.length; i++) {
            if (commitments[trancheId][buyers[i]] != amounts[i]) revert CommitmentMismatch();
            if (amounts[i] == 0) revert ZeroAmount();
            totalShares += amounts[i];
        }
        if (totalShares != t.committedShares) revert IncompleteBuyers();

        t.status = TrancheStatus.Finalized;

        // Forward ETH to Safe
        (bool sent,) = safe.call{value: t.totalETHCommitted}("");
        if (!sent) revert TransferFailed();

        // Mint shares to buyers via DAO
        (bool success,) = dao.call(
            abi.encodeWithSignature("mintShares(address[],uint256[])", buyers, amounts)
        );
        if (!success) revert MintFailed();

        emit TrancheFinalized(trancheId, t.committedShares, t.totalETHCommitted);
    }

    function cancel(uint256 trancheId) external onlyDAO {
        Tranche storage t = tranches[trancheId];
        if (t.status != TrancheStatus.Active) revert NotActive();
        t.status = TrancheStatus.Cancelled;
        emit TrancheCancelled(trancheId);
    }

    // ============ Buyer Functions ============

    // slither-disable-next-line timestamp
    function commit(
        uint256 trancheId,
        uint256 sharesToBuy,
        bytes32[] calldata proof
    ) external payable nonReentrant {
        Tranche storage t = tranches[trancheId];
        if (t.status != TrancheStatus.Active) revert NotActive();
        if (block.timestamp < t.startTime || block.timestamp > t.endTime) revert OutsideWindow();
        if (sharesToBuy == 0) revert ZeroShares();

        // Whitelist check
        if (t.whitelistRoot != bytes32(0)) {
            bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
            if (!MerkleProofLib.verify(proof, t.whitelistRoot, leaf)) revert NotWhitelisted();
        }

        // Supply check
        if (t.committedShares + sharesToBuy > t.totalShares) revert ExceedsSupply();

        // Per-address cap
        uint256 existing = commitments[trancheId][msg.sender];
        if (t.maxSharesPerAddress > 0) {
            if (existing + sharesToBuy > t.maxSharesPerAddress) revert ExceedsCap();
        }

        // Minimum on first commitment
        if (existing == 0 && t.minShares > 0) {
            if (sharesToBuy < t.minShares) revert BelowMinimum();
        }

        // Exact payment
        uint256 cost = sharesToBuy * t.pricePerShare;
        if (msg.value != cost) revert WrongETHAmount();

        commitments[trancheId][msg.sender] = existing + sharesToBuy;
        t.committedShares += sharesToBuy;
        t.totalETHCommitted += msg.value;

        emit Committed(trancheId, msg.sender, sharesToBuy, msg.value);
    }

    // slither-disable-next-line timestamp
    function refund(uint256 trancheId) external nonReentrant {
        Tranche storage t = tranches[trancheId];
        TrancheStatus s = _effectiveStatus(trancheId);
        if (s != TrancheStatus.Cancelled && !(s == TrancheStatus.Active && block.timestamp > t.finalizeDeadline)) revert NotRefundable();

        uint256 shares = commitments[trancheId][msg.sender];
        if (shares == 0) revert NoCommitment();

        uint256 ethAmount = shares * t.pricePerShare;
        commitments[trancheId][msg.sender] = 0;
        t.committedShares -= shares;
        t.totalETHCommitted -= ethAmount;

        (bool sent,) = msg.sender.call{value: ethAmount}("");
        if (!sent) revert TransferFailed();

        emit Refunded(trancheId, msg.sender, shares, ethAmount);
    }

    // ============ View Functions ============

    function status(uint256 trancheId) external view returns (TrancheStatus) {
        return _effectiveStatus(trancheId);
    }

    function getTranche(uint256 trancheId) external view returns (Tranche memory) {
        return tranches[trancheId];
    }

    function getCommitment(uint256 trancheId, address buyer) external view returns (uint256 shares, uint256 ethValue) {
        shares = commitments[trancheId][buyer];
        ethValue = shares * tranches[trancheId].pricePerShare;
    }

    // ============ Internal ============

    // slither-disable-next-line timestamp
    function _effectiveStatus(uint256 trancheId) internal view returns (TrancheStatus) {
        Tranche storage t = tranches[trancheId];
        if (t.status == TrancheStatus.Active && block.timestamp > t.finalizeDeadline) {
            return TrancheStatus.Active; // still Active but refundable (expired)
        }
        return t.status;
    }
}
