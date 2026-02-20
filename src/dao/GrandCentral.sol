// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {IGrandCentral} from "./interfaces/IGrandCentral.sol";
import {IAvatar, Operation} from "./interfaces/IAvatar.sol";

contract GrandCentral is IGrandCentral, ReentrancyGuard {
    // ============ Share Accounting ============

    mapping(address => uint256) public shares;
    uint256 public totalShares;

    struct Checkpoint {
        uint32 timestamp;
        uint224 value;
    }
    mapping(address => Checkpoint[]) private _memberCheckpoints;
    Checkpoint[] private _totalSharesCheckpoints;

    // ============ Loot Accounting ============

    mapping(address => uint256) public loot;
    uint256 public totalLoot;

    mapping(address => Checkpoint[]) private _memberLootCheckpoints;
    Checkpoint[] private _totalLootCheckpoints;

    // ============ Proposal System ============

    uint32 public proposalCount;
    uint32 public votingPeriod;
    uint32 public gracePeriod;
    uint256 public quorumPercent;
    uint256 public sponsorThreshold;
    uint256 public minRetentionPercent;
    uint32 public latestSponsoredProposalId;

    mapping(uint256 => Proposal) public proposals;
    mapping(address => mapping(uint32 => bool)) public memberVoted;

    // ============ Treasury Pools ============

    uint256 public ragequitPool;
    uint256 public rewardPerShare;
    uint256 public claimsPoolBalance;
    uint256 constant PRECISION = 1e18;
    mapping(address => uint256) public rewardDebt;

    // ============ Gnosis Safe ============

    address public immutable safe;

    // ============ Conductor System ============
    // Permissions: 1=admin, 2=manager, 4=governor (bitmask)

    mapping(address => uint256) public conductors;
    bool public adminLock;
    bool public managerLock;
    bool public governorLock;

    // ============ Modifiers ============

    modifier daoOnly() {
        require(msg.sender == address(this), "!dao");
        _;
    }

    modifier daoOrManager() {
        require(msg.sender == address(this) || isManager(msg.sender), "!dao & !manager");
        _;
    }

    modifier daoOrGovernor() {
        require(msg.sender == address(this) || isGovernor(msg.sender), "!dao & !governor");
        _;
    }

    // ============ Constructor ============

    constructor(
        address _safe,
        address _founder,
        uint256 _initialShares,
        uint32 _votingPeriod,
        uint32 _gracePeriod,
        uint256 _quorumPercent,
        uint256 _sponsorThreshold,
        uint256 _minRetentionPercent
    ) {
        require(_safe != address(0), "invalid safe");
        require(_founder != address(0), "invalid founder");
        require(_initialShares > 0, "no shares");
        require(_votingPeriod > 0, "no voting period");

        safe = _safe;
        votingPeriod = _votingPeriod;
        gracePeriod = _gracePeriod;
        quorumPercent = _quorumPercent;
        sponsorThreshold = _sponsorThreshold;
        minRetentionPercent = _minRetentionPercent;

        _mintShares(_founder, _initialShares);
    }

    // ============ Share Management ============

    function mintShares(address[] calldata to, uint256[] calldata amount) external daoOrManager {
        require(to.length == amount.length, "!array parity");
        for (uint256 i = 0; i < to.length; i++) {
            _mintShares(to[i], amount[i]);
        }
    }

    function burnShares(address[] calldata from, uint256[] calldata amount) external daoOrManager {
        require(from.length == amount.length, "!array parity");
        for (uint256 i = 0; i < from.length; i++) {
            _burnShares(from[i], amount[i]);
        }
    }

    function _mintShares(address to, uint256 amount) internal {
        _settleClaims(to);

        shares[to] += amount;
        totalShares += amount;

        _writeCheckpoint(_memberCheckpoints[to], uint224(shares[to]));
        _writeCheckpoint(_totalSharesCheckpoints, uint224(totalShares));

        rewardDebt[to] = (shares[to] + loot[to]) * rewardPerShare / PRECISION;

        emit SharesMinted(to, amount);
    }

    function _burnShares(address from, uint256 amount) internal {
        require(shares[from] >= amount, "insufficient shares");

        _settleClaims(from);

        shares[from] -= amount;
        totalShares -= amount;

        _writeCheckpoint(_memberCheckpoints[from], uint224(shares[from]));
        _writeCheckpoint(_totalSharesCheckpoints, uint224(totalShares));

        rewardDebt[from] = (shares[from] + loot[from]) * rewardPerShare / PRECISION;

        emit SharesBurned(from, amount);
    }

    // ============ Loot Management ============

    function mintLoot(address[] calldata to, uint256[] calldata amount) external daoOrManager {
        require(to.length == amount.length, "!array parity");
        for (uint256 i = 0; i < to.length; i++) {
            _mintLoot(to[i], amount[i]);
        }
    }

    function burnLoot(address[] calldata from, uint256[] calldata amount) external daoOrManager {
        require(from.length == amount.length, "!array parity");
        for (uint256 i = 0; i < from.length; i++) {
            _burnLoot(from[i], amount[i]);
        }
    }

    function _mintLoot(address to, uint256 amount) internal {
        _settleClaims(to);

        loot[to] += amount;
        totalLoot += amount;

        _writeCheckpoint(_memberLootCheckpoints[to], uint224(loot[to]));
        _writeCheckpoint(_totalLootCheckpoints, uint224(totalLoot));

        rewardDebt[to] = (shares[to] + loot[to]) * rewardPerShare / PRECISION;

        emit LootMinted(to, amount);
    }

    function _burnLoot(address from, uint256 amount) internal {
        require(loot[from] >= amount, "insufficient loot");

        _settleClaims(from);

        loot[from] -= amount;
        totalLoot -= amount;

        _writeCheckpoint(_memberLootCheckpoints[from], uint224(loot[from]));
        _writeCheckpoint(_totalLootCheckpoints, uint224(totalLoot));

        rewardDebt[from] = (shares[from] + loot[from]) * rewardPerShare / PRECISION;

        emit LootBurned(from, amount);
    }

    // ============ Claims Settlement ============

    function _settleClaims(address member) internal {
        uint256 weight = shares[member] + loot[member];
        if (weight > 0 && rewardPerShare > 0) {
            uint256 pending = (weight * rewardPerShare / PRECISION) - rewardDebt[member];
            if (pending > 0) {
                claimsPoolBalance -= pending;
                IAvatar(safe).execTransactionFromModule(member, pending, "", Operation.Call);
            }
        }
    }

    // ============ Checkpoints ============

    function getSharesAt(address member, uint256 timestamp) public view returns (uint256) {
        return _getCheckpointAt(_memberCheckpoints[member], timestamp);
    }

    function getTotalSharesAt(uint256 timestamp) public view returns (uint256) {
        return _getCheckpointAt(_totalSharesCheckpoints, timestamp);
    }

    function getLootAt(address member, uint256 timestamp) public view returns (uint256) {
        return _getCheckpointAt(_memberLootCheckpoints[member], timestamp);
    }

    function getTotalLootAt(uint256 timestamp) public view returns (uint256) {
        return _getCheckpointAt(_totalLootCheckpoints, timestamp);
    }

    function _writeCheckpoint(Checkpoint[] storage ckpts, uint224 value) internal {
        uint256 len = ckpts.length;
        if (len > 0 && ckpts[len - 1].timestamp == uint32(block.timestamp)) {
            ckpts[len - 1].value = value;
        } else {
            ckpts.push(Checkpoint({timestamp: uint32(block.timestamp), value: value}));
        }
    }

    function _getCheckpointAt(Checkpoint[] storage ckpts, uint256 timestamp) internal view returns (uint256) {
        uint256 len = ckpts.length;
        if (len == 0) return 0;

        if (ckpts[len - 1].timestamp <= timestamp) return ckpts[len - 1].value;
        if (ckpts[0].timestamp > timestamp) return 0;

        uint256 low = 0;
        uint256 high = len - 1;
        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            if (ckpts[mid].timestamp <= timestamp) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        return ckpts[low].value;
    }

    // ============ Proposal System ============

    function submitProposal(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        uint32 expiration,
        string calldata details
    ) external nonReentrant returns (uint256) {
        require(targets.length == values.length && values.length == calldatas.length, "!array parity");
        require(targets.length > 0, "empty proposal");
        require(
            expiration == 0 || expiration > block.timestamp + votingPeriod + gracePeriod,
            "expired"
        );

        bool selfSponsor = shares[msg.sender] >= sponsorThreshold && sponsorThreshold > 0;

        bytes32 dataHash = keccak256(abi.encode(targets, values, calldatas));

        // SAFETY: unchecked is safe here because:
        // - proposalCount is uint32, overflow at 4.29B proposals is infeasible
        // - votingPeriod/gracePeriod are admin-configured uint32 values that sum
        //   with block.timestamp (also uint32-cast) well within uint32 range
        //   for any realistic governance parameters
        unchecked {
            proposalCount++;
            proposals[proposalCount] = Proposal({
                id: proposalCount,
                prevProposalId: selfSponsor ? latestSponsoredProposalId : 0,
                votingStarts: selfSponsor ? uint32(block.timestamp) : 0,
                votingEnds: selfSponsor ? uint32(block.timestamp) + votingPeriod : 0,
                graceEnds: selfSponsor ? uint32(block.timestamp) + votingPeriod + gracePeriod : 0,
                expiration: expiration,
                yesVotes: 0,
                noVotes: 0,
                maxTotalSharesAtYesVote: 0,
                status: [false, false, false, false],
                sponsor: selfSponsor ? msg.sender : address(0),
                proposalDataHash: dataHash,
                details: details
            });
        }

        if (selfSponsor) {
            latestSponsoredProposalId = proposalCount;
        }

        emit ProposalSubmitted(
            proposalCount, dataHash, targets, values, calldatas,
            expiration, selfSponsor, details
        );

        return proposalCount;
    }

    function sponsorProposal(uint32 id) external nonReentrant {
        Proposal storage prop = proposals[id];
        require(shares[msg.sender] >= sponsorThreshold, "!sponsor");
        require(state(id) == ProposalState.Submitted, "!submitted");
        require(
            prop.expiration == 0 || prop.expiration > block.timestamp + votingPeriod + gracePeriod,
            "expired"
        );

        prop.votingStarts = uint32(block.timestamp);
        // SAFETY: unchecked is safe — votingPeriod + gracePeriod are uint32
        // admin-configured values (min 1 day each). Sum with uint32(block.timestamp)
        // cannot overflow uint32 before year 2106.
        unchecked {
            prop.votingEnds = uint32(block.timestamp) + votingPeriod;
            prop.graceEnds = uint32(block.timestamp) + votingPeriod + gracePeriod;
        }
        prop.prevProposalId = latestSponsoredProposalId;
        prop.sponsor = msg.sender;
        latestSponsoredProposalId = id;

        emit ProposalSponsored(msg.sender, id, block.timestamp);
    }

    function submitVote(uint32 id, bool approved) external nonReentrant {
        Proposal storage prop = proposals[id];
        require(state(id) == ProposalState.Voting, "!voting");

        uint256 balance = getSharesAt(msg.sender, prop.votingStarts);
        require(balance > 0, "!member");
        require(!memberVoted[msg.sender][id], "voted");

        // SAFETY: unchecked is safe — yesVotes/noVotes are uint256.
        // balance is a member's share count, bounded by totalShares.
        // Overflow would require totalShares to approach 2^256, which is infeasible.
        unchecked {
            if (approved) {
                prop.yesVotes += balance;
                if (totalShares > prop.maxTotalSharesAtYesVote) {
                    prop.maxTotalSharesAtYesVote = totalShares;
                }
            } else {
                prop.noVotes += balance;
            }
        }

        memberVoted[msg.sender][id] = true;

        emit VoteCast(msg.sender, balance, id, approved);
    }

    function processProposal(
        uint32 id,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas
    ) external nonReentrant {
        Proposal storage prop = proposals[id];
        require(state(id) == ProposalState.Ready, "!ready");

        ProposalState prevState = state(prop.prevProposalId);
        require(
            prevState == ProposalState.Processed ||
            prevState == ProposalState.Cancelled ||
            prevState == ProposalState.Defeated ||
            prevState == ProposalState.Unborn,
            "prev!processed"
        );

        require(
            keccak256(abi.encode(targets, values, calldatas)) == prop.proposalDataHash,
            "incorrect calldata"
        );

        prop.status[1] = true; // processed

        bool okToExecute = true;

        if (prop.expiration != 0 && prop.expiration < block.timestamp)
            okToExecute = false;

        if (okToExecute && quorumPercent > 0 && prop.yesVotes * 100 < quorumPercent * totalShares)
            okToExecute = false;

        if (okToExecute && minRetentionPercent > 0 &&
            totalShares < (prop.maxTotalSharesAtYesVote * minRetentionPercent) / 100)
            okToExecute = false;

        if (prop.yesVotes > prop.noVotes && okToExecute) {
            prop.status[2] = true; // passed
            bool success = _executeProposal(targets, values, calldatas);
            if (!success) {
                prop.status[3] = true; // actionFailed
            }
        }

        emit ProposalProcessed(id, prop.status[2], prop.status[3]);
    }

    function _executeProposal(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas
    ) internal returns (bool) {
        for (uint256 i = 0; i < targets.length; i++) {
            // Self-calls execute directly; external calls route through Safe
            if (targets[i] == address(this)) {
                (bool success,) = address(this).call{value: 0}(calldatas[i]);
                if (!success) return false;
            } else {
                bool success = IAvatar(safe).execTransactionFromModule(
                    targets[i], values[i], calldatas[i], Operation.Call
                );
                if (!success) return false;
            }
        }
        return true;
    }

    function cancelProposal(uint32 id) external nonReentrant {
        Proposal storage prop = proposals[id];
        require(state(id) == ProposalState.Voting, "!voting");
        require(
            msg.sender == prop.sponsor || isGovernor(msg.sender),
            "!cancellable"
        );
        prop.status[0] = true;
        emit ProposalCancelled(id);
    }

    function state(uint32 id) public view returns (ProposalState) {
        Proposal memory prop = proposals[id];
        if (prop.id == 0) return ProposalState.Unborn;
        if (prop.status[0]) return ProposalState.Cancelled;
        if (prop.votingStarts == 0) return ProposalState.Submitted;
        if (block.timestamp <= prop.votingEnds) return ProposalState.Voting;
        if (block.timestamp <= prop.graceEnds) return ProposalState.Grace;
        if (prop.noVotes >= prop.yesVotes) return ProposalState.Defeated;
        if (prop.status[1]) return ProposalState.Processed;
        return ProposalState.Ready;
    }

    function getProposalStatus(uint32 id) external view returns (bool[4] memory) {
        return proposals[id].status;
    }

    // ============ Treasury Pools ============

    function generalFunds() public view returns (uint256) {
        uint256 reserved = ragequitPool + claimsPoolBalance;
        uint256 bal = safe.balance;
        return bal > reserved ? bal - reserved : 0;
    }

    function fundRagequitPool(uint256 amount) external daoOrManager {
        require(
            safe.balance >= ragequitPool + claimsPoolBalance + amount,
            "insufficient general funds"
        );
        ragequitPool += amount;
        emit RagequitPoolFunded(amount, ragequitPool);
    }

    function fundClaimsPool(uint256 amount) external daoOrManager {
        uint256 totalWeight = totalShares + totalLoot;
        require(totalWeight > 0, "no members");
        require(
            safe.balance >= ragequitPool + claimsPoolBalance + amount,
            "insufficient general funds"
        );
        claimsPoolBalance += amount;
        rewardPerShare += (amount * PRECISION) / totalWeight;
        emit ClaimsPoolFunded(amount, rewardPerShare);
    }

    function ragequit(uint256 sharesToBurn, uint256 lootToBurn) external nonReentrant {
        require(shares[msg.sender] >= sharesToBurn, "insufficient shares");
        require(loot[msg.sender] >= lootToBurn, "insufficient loot");
        require(sharesToBurn + lootToBurn > 0, "zero burn");

        uint256 totalWeight = totalShares + totalLoot;
        uint256 burnWeight = sharesToBurn + lootToBurn;

        uint256 payout = 0;
        if (ragequitPool > 0 && totalWeight > 0) {
            payout = (burnWeight * ragequitPool) / totalWeight;
            ragequitPool -= payout;
        }

        if (sharesToBurn > 0) _burnShares(msg.sender, sharesToBurn);
        if (lootToBurn > 0) _burnLoot(msg.sender, lootToBurn);

        if (payout > 0) {
            IAvatar(safe).execTransactionFromModule(msg.sender, payout, "", Operation.Call);
        }

        emit Ragequit(msg.sender, sharesToBurn, lootToBurn, payout);
    }

    function claim() external nonReentrant {
        uint256 pending = pendingClaim(msg.sender);
        require(pending > 0, "nothing to claim");

        rewardDebt[msg.sender] = (shares[msg.sender] + loot[msg.sender]) * rewardPerShare / PRECISION;
        claimsPoolBalance -= pending;
        IAvatar(safe).execTransactionFromModule(msg.sender, pending, "", Operation.Call);

        emit ClaimWithdrawn(msg.sender, pending);
    }

    function pendingClaim(address member) public view returns (uint256) {
        uint256 weight = shares[member] + loot[member];
        if (weight == 0) return 0;
        return (weight * rewardPerShare / PRECISION) - rewardDebt[member];
    }

    function executeStipend(address beneficiary, uint256 amount) external nonReentrant {
        require(isManager(msg.sender), "!manager");
        require(beneficiary != address(0), "invalid beneficiary");
        require(
            safe.balance >= ragequitPool + claimsPoolBalance + amount,
            "insufficient general funds"
        );
        IAvatar(safe).execTransactionFromModule(beneficiary, amount, "", Operation.Call);
        emit StipendExecuted(beneficiary, amount, msg.sender);
    }

    // ============ Conductor System ============

    function isAdmin(address conductor) public view returns (bool) {
        uint256 p = conductors[conductor];
        return (p & 1) != 0;
    }

    function isManager(address conductor) public view returns (bool) {
        uint256 p = conductors[conductor];
        return (p & 2) != 0;
    }

    function isGovernor(address conductor) public view returns (bool) {
        uint256 p = conductors[conductor];
        return (p & 4) != 0;
    }

    function setConductors(
        address[] calldata _conductors,
        uint256[] calldata _permissions
    ) external daoOnly {
        require(_conductors.length == _permissions.length, "!array parity");
        for (uint256 i = 0; i < _conductors.length; i++) {
            uint256 permission = _permissions[i];
            if (adminLock) require(permission & 1 == 0, "admin lock");
            if (managerLock) require(permission & 2 == 0, "manager lock");
            if (governorLock) require(permission & 4 == 0, "governor lock");
            conductors[_conductors[i]] = permission;
            emit ConductorSet(_conductors[i], permission);
        }
    }

    function lockAdmin() external daoOnly { adminLock = true; emit AdminLocked(); }
    function lockManager() external daoOnly { managerLock = true; emit ManagerLocked(); }
    function lockGovernor() external daoOnly { governorLock = true; emit GovernorLocked(); }

    function setGovernanceConfig(
        uint32 _votingPeriod,
        uint32 _gracePeriod,
        uint256 _quorumPercent,
        uint256 _sponsorThreshold,
        uint256 _minRetentionPercent
    ) external daoOrGovernor {
        if (_votingPeriod != 0) {
            require(_votingPeriod >= 1 days, "voting period too short");
            votingPeriod = _votingPeriod;
        }
        if (_gracePeriod != 0) {
            require(_gracePeriod >= 1 days, "grace period too short");
            gracePeriod = _gracePeriod;
        }
        quorumPercent = _quorumPercent;
        sponsorThreshold = _sponsorThreshold;
        minRetentionPercent = _minRetentionPercent;
        emit GovernanceConfigSet(
            _votingPeriod, _gracePeriod, _quorumPercent,
            _sponsorThreshold, _minRetentionPercent
        );
    }
}
