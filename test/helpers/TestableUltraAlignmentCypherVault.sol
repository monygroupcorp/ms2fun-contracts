// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "../../src/vaults/cypher/UltraAlignmentCypherVault.sol";

/// @dev Test-only subclass that exposes setters for direct LP position manipulation
contract TestableUltraAlignmentCypherVault is UltraAlignmentCypherVault {
    function setPositionForTest(uint256 tokenId, address pool, bool _tokenIsZero) external {
        lpTokenId = tokenId;
        lpPool = pool;
        tokenIsZero = _tokenIsZero;
    }
}
