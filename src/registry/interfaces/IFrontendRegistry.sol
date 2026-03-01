// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IFrontendRegistry {
    enum ReleaseType { SITE_ONLY, ECOSYSTEM }

    struct Release {
        uint32 id;
        ReleaseType releaseType;
        bytes contentHash;        // IPFS content hash encoded for ENS resolver (bytes, not bytes32)
        string version;           // semver e.g. "1.4.0"
        string notes;             // short changelog
        address[] contracts;      // ECOSYSTEM: addresses that shipped with this release (metadata only)
        uint64 timestamp;
        address proposer;         // informational: msg.sender at time of proposal execution
    }

    event ReleasePublished(
        uint32 indexed id,
        ReleaseType releaseType,
        string version,
        bytes contentHash
    );
    event NodeUpdated(bytes32 indexed node, uint32 indexed releaseId);
    event EnsNameAdded(bytes32 indexed node);
    event EnsNameRemoved(bytes32 indexed node);

    function publishRelease(
        ReleaseType releaseType,
        bytes calldata contentHash,
        string calldata version,
        string calldata notes,
        address[] calldata contracts,
        bytes32[] calldata nodes
    ) external;

    function pointNodeToRelease(bytes32 node, uint32 releaseId) external;

    function addEnsName(bytes32 node) external;
    function removeEnsName(bytes32 node) external;

    function releases(uint256 index) external view returns (
        uint32 id,
        ReleaseType releaseType,
        bytes memory contentHash,
        string memory version,
        string memory notes,
        uint64 timestamp,
        address proposer
    );

    function nodeRelease(bytes32 node) external view returns (uint32);
    function isEnsNode(bytes32 node) external view returns (bool);
    function releaseCount() external view returns (uint256);
}
