// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeOwnableUUPS} from "../shared/SafeOwnableUUPS.sol";
import {IFrontendRegistry} from "./interfaces/IFrontendRegistry.sol";
import {IENSResolver} from "./interfaces/IENSResolver.sol";

/**
 * @title FrontendRegistry
 * @notice ENS controller and versioning system for the ms2.fun decentralized frontend.
 * @dev Maintains a global append-only release log. Each managed ENS name independently
 *      steers to any release. All mutations require Timelock (onlyOwner).
 *      UUPS upgradeable. Owner is the DAO via Timelock.
 *
 *      ENS roles:
 *        - Gnosis Safe = registrant (owns name NFT, sets controller)
 *        - FrontendRegistry = controller (calls setContenthash on resolver)
 */
contract FrontendRegistry is SafeOwnableUUPS, IFrontendRegistry {

    // ┌─────────────────────────┐
    // │      Custom Errors      │
    // └─────────────────────────┘

    error InvalidAddress();
    error AlreadyManaged();
    error NotManaged();
    error NodeNotManaged();
    error InvalidReleaseId();

    // ┌─────────────────────────┐
    // │      State Variables    │
    // └─────────────────────────┘

    bool private _initialized;

    IENSResolver public ensResolver;

    /// @notice All published releases, append-only
    Release[] private _releases;

    /// @notice ENS node → active release ID (1-indexed; 0 = no release assigned)
    mapping(bytes32 => uint32) public nodeRelease;

    /// @notice All managed ENS nodes
    bytes32[] private _ensNodes;

    /// @notice Whether a node is currently managed
    mapping(bytes32 => bool) public isEnsNode;

    // ┌─────────────────────────┐
    // │      Constructor        │
    // └─────────────────────────┘

    constructor() {
        _initializeOwner(msg.sender);
    }

    function initialize(address _owner, address _ensResolver) public {
        if (_initialized) revert AlreadyInitialized();
        if (_owner == address(0)) revert InvalidAddress();
        if (_ensResolver == address(0)) revert InvalidAddress();
        _initialized = true;
        _setOwner(_owner);
        ensResolver = IENSResolver(_ensResolver);
    }

    // ┌─────────────────────────┐
    // │   ENS Name Management   │
    // └─────────────────────────┘

    function addEnsName(bytes32 node) external onlyOwner {
        if (isEnsNode[node]) revert AlreadyManaged();
        isEnsNode[node] = true;
        _ensNodes.push(node);
        emit EnsNameAdded(node);
    }

    function removeEnsName(bytes32 node) external onlyOwner {
        if (!isEnsNode[node]) revert NotManaged();
        isEnsNode[node] = false;

        // Swap-and-pop to remove from array
        uint256 len = _ensNodes.length;
        for (uint256 i; i < len; ++i) {
            if (_ensNodes[i] == node) {
                _ensNodes[i] = _ensNodes[len - 1];
                _ensNodes.pop();
                break;
            }
        }
        emit EnsNameRemoved(node);
    }

    // ┌─────────────────────────┐
    // │     Release Management  │
    // └─────────────────────────┘

    /**
     * @notice Publish a new frontend release and deploy it to specified ENS nodes.
     * @dev Creates a release record and updates ENS content hashes atomically.
     *      All nodes must be managed (added via addEnsName) before publishing.
     * @param releaseType SITE_ONLY for frontend-only changes; ECOSYSTEM when new contracts ship alongside
     * @param contentHash IPFS content hash encoded for ENS resolver (use ENS contenthash encoding)
     * @param version Semver string e.g. "1.4.0"
     * @param notes Short changelog or description
     * @param contracts Addresses of contracts that shipped with this release (metadata only, not validated)
     * @param nodes ENS nodes to update immediately; must all be managed
     */
    function publishRelease(
        ReleaseType releaseType,
        bytes calldata contentHash,
        string calldata version,
        string calldata notes,
        address[] calldata contracts,
        bytes32[] calldata nodes
    ) external onlyOwner {
        uint32 releaseId = _storeRelease(releaseType, contentHash, version, notes, contracts);
        emit ReleasePublished(releaseId, releaseType, version, contentHash);
        _applyToNodes(releaseId, contentHash, nodes);
    }

    function _storeRelease(
        ReleaseType releaseType,
        bytes calldata contentHash,
        string calldata version,
        string calldata notes,
        address[] calldata contracts
    ) internal returns (uint32 releaseId) {
        releaseId = uint32(_releases.length) + 1;
        Release storage r = _releases.push();
        r.id = releaseId;
        r.releaseType = releaseType;
        r.contentHash = contentHash;
        r.version = version;
        r.notes = notes;
        r.timestamp = uint64(block.timestamp);
        r.proposer = msg.sender;
        uint256 cLen = contracts.length;
        for (uint256 i; i < cLen; ++i) {
            r.contracts.push(contracts[i]);
        }
    }

    function _applyToNodes(uint32 releaseId, bytes calldata contentHash, bytes32[] calldata nodes) internal {
        uint256 len = nodes.length;
        for (uint256 i; i < len; ++i) {
            bytes32 node = nodes[i];
            if (!isEnsNode[node]) revert NodeNotManaged();
            nodeRelease[node] = releaseId;
            ensResolver.setContenthash(node, contentHash);
            emit NodeUpdated(node, releaseId);
        }
    }

    /**
     * @notice Steer an ENS node to any already-published release.
     * @dev Used for staged rollouts, beta/stable divergence, or rollbacks.
     *      A rollback is just pointing a node to an older release ID.
     * @param node The ENS namehash to update
     * @param releaseId Must be a valid published release ID (1-indexed)
     */
    function pointNodeToRelease(bytes32 node, uint32 releaseId) external onlyOwner {
        if (!isEnsNode[node]) revert NodeNotManaged();
        if (releaseId == 0 || releaseId > _releases.length) revert InvalidReleaseId();

        nodeRelease[node] = releaseId;
        bytes memory contentHash = _releases[releaseId - 1].contentHash;
        ensResolver.setContenthash(node, contentHash);

        emit NodeUpdated(node, releaseId);
    }

    // ┌─────────────────────────┐
    // │      View Functions     │
    // └─────────────────────────┘

    function releaseCount() external view returns (uint256) {
        return _releases.length;
    }

    function releases(uint256 index) external view returns (
        uint32 id,
        ReleaseType releaseType,
        bytes memory contentHash,
        string memory version,
        string memory notes,
        uint64 timestamp,
        address proposer
    ) {
        Release storage r = _releases[index];
        return (r.id, r.releaseType, r.contentHash, r.version, r.notes, r.timestamp, r.proposer);
    }

    function getReleaseContracts(uint32 id) external view returns (address[] memory) {
        if (id == 0 || id > _releases.length) revert InvalidReleaseId();
        return _releases[id - 1].contracts;
    }

    function getManagedNodes() external view returns (bytes32[] memory) {
        return _ensNodes;
    }
}
