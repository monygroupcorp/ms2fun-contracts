// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {IGrandCentral} from "../interfaces/IGrandCentral.sol";

contract ShareOffering is ReentrancyGuard {
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
        require(msg.sender == dao || msg.sender == safe, "!dao");
        _;
    }

    // ============ Constructor ============

    constructor(address _dao) {
        require(_dao != address(0), "invalid dao");
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
        require(pricePerShare > 0, "zero price");
        require(totalShares > 0, "zero shares");
        require(duration > 0, "zero duration");
        if (minShares > 0) {
            require(minShares <= totalShares, "min > total");
        }
        if (maxSharesPerAddress > 0 && minShares > 0) {
            require(maxSharesPerAddress >= minShares, "cap < min");
        }

        // Ensure no active tranche
        if (currentTrancheId > 0) {
            TrancheStatus s = _effectiveStatus(currentTrancheId);
            require(
                s == TrancheStatus.Finalized || s == TrancheStatus.Cancelled || s == TrancheStatus.Inactive,
                "active tranche exists"
            );
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

    function finalize(
        uint256 trancheId,
        address[] calldata buyers,
        uint256[] calldata amounts
    ) external onlyDAO nonReentrant {
        Tranche storage t = tranches[trancheId];
        require(t.status == TrancheStatus.Active, "not active");
        require(block.timestamp > t.endTime, "window not closed");
        require(block.timestamp <= t.finalizeDeadline, "past deadline");
        require(buyers.length == amounts.length, "!array parity");

        // Verify buyer arrays match commitments
        uint256 totalShares;
        for (uint256 i = 0; i < buyers.length; i++) {
            require(commitments[trancheId][buyers[i]] == amounts[i], "commitment mismatch");
            require(amounts[i] > 0, "zero amount");
            totalShares += amounts[i];
        }
        require(totalShares == t.committedShares, "incomplete buyers");

        t.status = TrancheStatus.Finalized;

        // Forward ETH to Safe
        (bool sent,) = safe.call{value: t.totalETHCommitted}("");
        require(sent, "ETH transfer failed");

        // Mint shares to buyers via DAO
        (bool success,) = dao.call(
            abi.encodeWithSignature("mintShares(address[],uint256[])", buyers, amounts)
        );
        require(success, "mint failed");

        emit TrancheFinalized(trancheId, t.committedShares, t.totalETHCommitted);
    }

    function cancel(uint256 trancheId) external onlyDAO {
        Tranche storage t = tranches[trancheId];
        require(t.status == TrancheStatus.Active, "not active");
        t.status = TrancheStatus.Cancelled;
        emit TrancheCancelled(trancheId);
    }

    // ============ Buyer Functions ============

    function commit(
        uint256 trancheId,
        uint256 sharesToBuy,
        bytes32[] calldata proof
    ) external payable nonReentrant {
        Tranche storage t = tranches[trancheId];
        require(t.status == TrancheStatus.Active, "not active");
        require(block.timestamp >= t.startTime && block.timestamp <= t.endTime, "outside window");
        require(sharesToBuy > 0, "zero shares");

        // Whitelist check
        if (t.whitelistRoot != bytes32(0)) {
            bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
            require(MerkleProofLib.verify(proof, t.whitelistRoot, leaf), "not whitelisted");
        }

        // Supply check
        require(t.committedShares + sharesToBuy <= t.totalShares, "exceeds supply");

        // Per-address cap
        uint256 existing = commitments[trancheId][msg.sender];
        if (t.maxSharesPerAddress > 0) {
            require(existing + sharesToBuy <= t.maxSharesPerAddress, "exceeds cap");
        }

        // Minimum on first commitment
        if (existing == 0 && t.minShares > 0) {
            require(sharesToBuy >= t.minShares, "below minimum");
        }

        // Exact payment
        uint256 cost = sharesToBuy * t.pricePerShare;
        require(msg.value == cost, "wrong ETH amount");

        commitments[trancheId][msg.sender] = existing + sharesToBuy;
        t.committedShares += sharesToBuy;
        t.totalETHCommitted += msg.value;

        emit Committed(trancheId, msg.sender, sharesToBuy, msg.value);
    }

    function refund(uint256 trancheId) external nonReentrant {
        Tranche storage t = tranches[trancheId];
        TrancheStatus s = _effectiveStatus(trancheId);
        require(s == TrancheStatus.Cancelled || (s == TrancheStatus.Active && block.timestamp > t.finalizeDeadline), "not refundable");

        uint256 shares = commitments[trancheId][msg.sender];
        require(shares > 0, "no commitment");

        uint256 ethAmount = shares * t.pricePerShare;
        commitments[trancheId][msg.sender] = 0;
        t.committedShares -= shares;
        t.totalETHCommitted -= ethAmount;

        (bool sent,) = msg.sender.call{value: ethAmount}("");
        require(sent, "ETH transfer failed");

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

    function _effectiveStatus(uint256 trancheId) internal view returns (TrancheStatus) {
        Tranche storage t = tranches[trancheId];
        if (t.status == TrancheStatus.Active && block.timestamp > t.finalizeDeadline) {
            return TrancheStatus.Active; // still Active but refundable (expired)
        }
        return t.status;
    }
}
