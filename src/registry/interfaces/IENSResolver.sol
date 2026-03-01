// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interface for the ENS Public Resolver content hash functions
interface IENSResolver {
    function setContenthash(bytes32 node, bytes calldata hash) external;
    function contenthash(bytes32 node) external view returns (bytes memory);
}
