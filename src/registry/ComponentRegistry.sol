// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeOwnableUUPS} from "../shared/SafeOwnableUUPS.sol";
import {IComponentRegistry} from "./interfaces/IComponentRegistry.sol";

/**
 * @title ComponentRegistry
 * @notice Protocol-level registry for DAO-approved, user-selectable singleton contracts.
 * @dev Factories consult isApprovedComponent() at instance creation to validate user selections.
 *      First component type: gating modules (tag = keccak256("gating")).
 *      UUPS upgradeable. Owner is the DAO via Timelock.
 *      Revocation blocks new instance creation only — existing instances are unaffected.
 */
contract ComponentRegistry is SafeOwnableUUPS, IComponentRegistry {

    // ┌─────────────────────────┐
    // │      Custom Errors      │
    // └─────────────────────────┘

    error InvalidAddress();
    error AlreadyApproved();
    error NotApproved();

    // ┌─────────────────────────┐
    // │      State Variables    │
    // └─────────────────────────┘

    bool private _initialized;

    /// @notice Whether a component is currently approved.
    mapping(address => bool)    public isApproved;

    /// @notice Off-chain category tag per component (e.g. keccak256("gating")).
    mapping(address => bytes32) public componentTag;

    /// @notice Human-readable label per component for frontend display.
    mapping(address => string)  public componentName;

    /// @notice All component addresses ever approved (includes revoked). Used for enumeration.
    address[] public allComponents;

    // ┌─────────────────────────┐
    // │      Constructor        │
    // └─────────────────────────┘

    constructor() {
        _initializeOwner(msg.sender);
    }

    function initialize(address _owner) public {
        if (_initialized) revert AlreadyInitialized();
        if (_owner == address(0)) revert InvalidAddress();
        _initialized = true;
        _setOwner(_owner);
    }

    // ┌─────────────────────────┐
    // │   DAO Mutations         │
    // └─────────────────────────┘

    /// @inheritdoc IComponentRegistry
    function approveComponent(address component, bytes32 tag, string calldata name) external onlyOwner {
        if (component == address(0)) revert InvalidAddress();
        if (isApproved[component]) revert AlreadyApproved();
        isApproved[component] = true;
        componentTag[component] = tag;
        componentName[component] = name;
        allComponents.push(component);
        emit ComponentApproved(component, tag, name);
    }

    /// @inheritdoc IComponentRegistry
    function revokeComponent(address component) external onlyOwner {
        if (!isApproved[component]) revert NotApproved();
        isApproved[component] = false;
        emit ComponentRevoked(component);
    }

    // ┌─────────────────────────┐
    // │   View Functions        │
    // └─────────────────────────┘

    /// @inheritdoc IComponentRegistry
    function isApprovedComponent(address component) external view returns (bool) {
        return isApproved[component];
    }

    /// @inheritdoc IComponentRegistry
    function getApprovedComponents() external view returns (address[] memory) {
        uint256 len = allComponents.length;
        uint256 count = 0;
        for (uint256 i = 0; i < len; ++i) {
            if (isApproved[allComponents[i]]) ++count;
        }
        address[] memory result = new address[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < len; ++i) {
            if (isApproved[allComponents[i]]) result[j++] = allComponents[i];
        }
        return result;
    }

    /// @inheritdoc IComponentRegistry
    function getApprovedComponentsByTag(bytes32 tag) external view returns (address[] memory) {
        uint256 len = allComponents.length;
        uint256 count = 0;
        for (uint256 i = 0; i < len; ++i) {
            if (isApproved[allComponents[i]] && componentTag[allComponents[i]] == tag) ++count;
        }
        address[] memory result = new address[](count);
        uint256 j = 0;
        for (uint256 i = 0; i < len; ++i) {
            if (isApproved[allComponents[i]] && componentTag[allComponents[i]] == tag) result[j++] = allComponents[i];
        }
        return result;
    }
}
