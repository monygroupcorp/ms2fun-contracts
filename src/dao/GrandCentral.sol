// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {IGrandCentral} from "./interfaces/IGrandCentral.sol";
import {IAvatar, Operation} from "./interfaces/IAvatar.sol";

contract GrandCentral is IGrandCentral, ReentrancyGuard {
    // ============ Custom Errors ============

    error InvalidAddress();
    error AmountMustBePositive();
    error Unauthorized();
    error ArrayLengthMismatch();
    error InsufficientShares();
    error InsufficientLoot();
    error ProposalExpired();
    error EmptyProposal();
    error NotSubmitted();
    error NotVoting();
    error NotReady();
    error NotMember();
    error AlreadyVoted();
    error PreviousProposalNotProcessed();
    error IncorrectCalldata();
    error NotCancellable();
    error InsufficientGeneralFunds();
    error NoMembers();
    error ZeroBurn();
    error NothingToClaim();
    error AdminLockActive();
    error ManagerLockActive();
    error GovernorLockActive();
    error VotingPeriodTooShort();
    error GracePeriodTooShort();
    error InsufficientSponsorShares();

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
    // Permissions: 1=admin, 2=manager, 4=governor, 8=agentConductor (bitmask)

    mapping(address => uint256) public conductors;
    bool public adminLock;
    bool public managerLock;
    bool public governorLock;

    // ============ Modifiers ============

    modifier daoOnly() {
        if (msg.sender != address(this)) revert Unauthorized();
        _;
    }

    modifier daoOrManager() {
        if (msg.sender != address(this) && !isManager(msg.sender)) revert Unauthorized();
        _;
    }

    modifier daoOrGovernor() {
        if (msg.sender != address(this) && !isGovernor(msg.sender)) revert Unauthorized();
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
        if (_safe == address(0)) revert InvalidAddress();
        if (_founder == address(0)) revert InvalidAddress();
        if (_initialShares == 0) revert AmountMustBePositive();
        if (_votingPeriod == 0) revert VotingPeriodTooShort();

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
        if (to.length != amount.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < to.length; i++) {
            _mintShares(to[i], amount[i]);
        }
    }

    function burnShares(address[] calldata from, uint256[] calldata amount) external daoOrManager {
        if (from.length != amount.length) revert ArrayLengthMismatch();
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

        rewardDebt[to] = (shares[to] + loot[to]) * rewardPerShare / PRECISION; // round down: member cannot over-claim

        emit SharesMinted(to, amount);
    }

    function _burnShares(address from, uint256 amount) internal {
        if (shares[from] < amount) revert InsufficientShares();

        _settleClaims(from);

        shares[from] -= amount;
        totalShares -= amount;

        _writeCheckpoint(_memberCheckpoints[from], uint224(shares[from]));
        _writeCheckpoint(_totalSharesCheckpoints, uint224(totalShares));

        rewardDebt[from] = (shares[from] + loot[from]) * rewardPerShare / PRECISION; // round down: member cannot over-claim

        emit SharesBurned(from, amount);
    }

    // ============ Loot Management ============

    function mintLoot(address[] calldata to, uint256[] calldata amount) external daoOrManager {
        if (to.length != amount.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < to.length; i++) {
            _mintLoot(to[i], amount[i]);
        }
    }

    function burnLoot(address[] calldata from, uint256[] calldata amount) external daoOrManager {
        if (from.length != amount.length) revert ArrayLengthMismatch();
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

        rewardDebt[to] = (shares[to] + loot[to]) * rewardPerShare / PRECISION; // round down: member cannot over-claim

        emit LootMinted(to, amount);
    }

    function _burnLoot(address from, uint256 amount) internal {
        if (loot[from] < amount) revert InsufficientLoot();

        _settleClaims(from);

        loot[from] -= amount;
        totalLoot -= amount;

        _writeCheckpoint(_memberLootCheckpoints[from], uint224(loot[from]));
        _writeCheckpoint(_totalLootCheckpoints, uint224(totalLoot));

        rewardDebt[from] = (shares[from] + loot[from]) * rewardPerShare / PRECISION; // round down: member cannot over-claim

        emit LootBurned(from, amount);
    }

    // ============ Claims Settlement ============

    function _settleClaims(address member) internal {
        uint256 weight = shares[member] + loot[member];
        if (weight > 0 && rewardPerShare > 0) {
            uint256 pending = (weight * rewardPerShare / PRECISION) - rewardDebt[member]; // round down: favors pool
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
            uint256 mid = (low + high + 1) / 2; // round up: standard upper-bound binary search
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
        if (targets.length != values.length || values.length != calldatas.length) revert ArrayLengthMismatch();
        if (targets.length == 0) revert EmptyProposal();
        if (expiration != 0 && expiration <= block.timestamp + votingPeriod + gracePeriod) revert ProposalExpired();

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
            proposalCount, dataHash,
            expiration, selfSponsor, details
        );

        return proposalCount;
    }

    function sponsorProposal(uint32 id) external nonReentrant {
        Proposal storage prop = proposals[id];
        if (shares[msg.sender] < sponsorThreshold) revert InsufficientSponsorShares();
        if (state(id) != ProposalState.Submitted) revert NotSubmitted();
        if (prop.expiration != 0 && prop.expiration <= block.timestamp + votingPeriod + gracePeriod) revert ProposalExpired();

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
        if (state(id) != ProposalState.Voting) revert NotVoting();

        uint256 balance = getSharesAt(msg.sender, prop.votingStarts);
        if (balance == 0) revert NotMember();
        if (memberVoted[msg.sender][id]) revert AlreadyVoted();

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
        if (state(id) != ProposalState.Ready) revert NotReady();

        ProposalState prevState = state(prop.prevProposalId);
        if (
            prevState != ProposalState.Processed &&
            prevState != ProposalState.Cancelled &&
            prevState != ProposalState.Defeated &&
            prevState != ProposalState.Unborn
        ) revert PreviousProposalNotProcessed();

        if (keccak256(abi.encode(targets, values, calldatas)) != prop.proposalDataHash) revert IncorrectCalldata();

        prop.status[1] = true; // processed

        bool okToExecute = true;

        if (prop.expiration != 0 && prop.expiration < block.timestamp)
            okToExecute = false;

        if (okToExecute && quorumPercent > 0 && prop.yesVotes * 100 < quorumPercent * totalShares)
            okToExecute = false;

        if (okToExecute && minRetentionPercent > 0 &&
            totalShares < (prop.maxTotalSharesAtYesVote * minRetentionPercent) / 100) // round down: harder to fail retention check (conservative)
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
        if (state(id) != ProposalState.Voting) revert NotVoting();
        if (msg.sender != prop.sponsor && !isGovernor(msg.sender)) revert NotCancellable();
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
        if (safe.balance < ragequitPool + claimsPoolBalance + amount) revert InsufficientGeneralFunds();
        ragequitPool += amount;
        emit RagequitPoolFunded(amount, ragequitPool);
    }

    function fundClaimsPool(uint256 amount) external daoOrManager {
        uint256 totalWeight = totalShares + totalLoot;
        if (totalWeight == 0) revert NoMembers();
        if (safe.balance < ragequitPool + claimsPoolBalance + amount) revert InsufficientGeneralFunds();
        claimsPoolBalance += amount;
        rewardPerShare += (amount * PRECISION) / totalWeight; // round down: dust stays in pool
        emit ClaimsPoolFunded(amount, rewardPerShare);
    }

    function ragequit(uint256 sharesToBurn, uint256 lootToBurn) external nonReentrant {
        if (shares[msg.sender] < sharesToBurn) revert InsufficientShares();
        if (loot[msg.sender] < lootToBurn) revert InsufficientLoot();
        if (sharesToBurn + lootToBurn == 0) revert ZeroBurn();

        uint256 totalWeight = totalShares + totalLoot;
        uint256 burnWeight = sharesToBurn + lootToBurn;

        uint256 payout = 0;
        if (ragequitPool > 0 && totalWeight > 0) {
            payout = (burnWeight * ragequitPool) / totalWeight; // round down: dust stays in ragequit pool
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
        if (pending == 0) revert NothingToClaim();

        rewardDebt[msg.sender] = (shares[msg.sender] + loot[msg.sender]) * rewardPerShare / PRECISION; // round down: member cannot over-claim
        claimsPoolBalance -= pending;
        IAvatar(safe).execTransactionFromModule(msg.sender, pending, "", Operation.Call);

        emit ClaimWithdrawn(msg.sender, pending);
    }

    function pendingClaim(address member) public view returns (uint256) {
        uint256 weight = shares[member] + loot[member];
        if (weight == 0) return 0;
        return (weight * rewardPerShare / PRECISION) - rewardDebt[member]; // round down: favors pool
    }

    function executeStipend(address beneficiary, uint256 amount) external nonReentrant {
        if (!isManager(msg.sender)) revert Unauthorized();
        if (beneficiary == address(0)) revert InvalidAddress();
        if (safe.balance < ragequitPool + claimsPoolBalance + amount) revert InsufficientGeneralFunds();
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

    function isAgentConductor(address conductor) public view returns (bool) {
        uint256 p = conductors[conductor];
        return (p & 8) != 0;
    }

    function setConductors(
        address[] calldata _conductors,
        uint256[] calldata _permissions
    ) external daoOnly {
        if (_conductors.length != _permissions.length) revert ArrayLengthMismatch();
        for (uint256 i = 0; i < _conductors.length; i++) {
            uint256 permission = _permissions[i];
            if (adminLock && (permission & 1 != 0)) revert AdminLockActive();
            if (managerLock && (permission & 2 != 0)) revert ManagerLockActive();
            if (governorLock && (permission & 4 != 0)) revert GovernorLockActive();
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
            if (_votingPeriod < 1 days) revert VotingPeriodTooShort();
            votingPeriod = _votingPeriod;
        }
        if (_gracePeriod != 0) {
            if (_gracePeriod < 1 days) revert GracePeriodTooShort();
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
