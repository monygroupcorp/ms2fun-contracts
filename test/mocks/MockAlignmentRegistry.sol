// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAlignmentRegistry} from "../../src/master/interfaces/IAlignmentRegistry.sol";

/// @notice Minimal mock for vault tests — only implements token-in-target and active checks.
contract MockAlignmentRegistry is IAlignmentRegistry {
    mapping(uint256 => bool) public activeTargets;
    mapping(uint256 => mapping(address => bool)) public tokenInTarget;

    function setTargetActive(uint256 targetId, bool active) external {
        activeTargets[targetId] = active;
    }

    function setTokenInTarget(uint256 targetId, address token, bool inTarget) external {
        tokenInTarget[targetId][token] = inTarget;
    }

    // ── IAlignmentRegistry implementation ──

    function isAlignmentTargetActive(uint256 targetId) external view override returns (bool) {
        return activeTargets[targetId];
    }

    function isTokenInTarget(uint256 targetId, address token) external view override returns (bool) {
        return tokenInTarget[targetId][token];
    }

    // ── Stubs (not used by vault) ──

    function registerAlignmentTarget(string memory, string memory, string memory, AlignmentAsset[] memory) external pure override returns (uint256) { return 0; }
    function getAlignmentTarget(uint256) external pure override returns (AlignmentTarget memory) { return AlignmentTarget(0, "", "", "", 0, false); }
    function getAlignmentTargetAssets(uint256) external pure override returns (AlignmentAsset[] memory) { return new AlignmentAsset[](0); }
    function deactivateAlignmentTarget(uint256) external pure override {}
    function updateAlignmentTarget(uint256, string memory, string memory) external pure override {}
    function addAmbassador(uint256, address) external pure override {}
    function removeAmbassador(uint256, address) external pure override {}
    function getAmbassadors(uint256) external pure override returns (address[] memory) { return new address[](0); }
    function isAmbassador(uint256, address) external pure override returns (bool) { return false; }
}
