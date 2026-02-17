// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMasterRegistry} from "../../src/master/interfaces/IMasterRegistry.sol";

/**
 * @title MockMasterRegistry
 * @notice Mock implementation of IMasterRegistry for testing
 * @dev Provides no-op implementations of all registry functions
 */
contract MockMasterRegistry is IMasterRegistry {
    // Simple no-op implementations for testing

    // applyForFactory removed in owner-only rework

    function registerInstance(
        address,
        address,
        address,
        string memory,
        string memory,
        address
    ) external override {}

    // getFactoryApplication removed in owner-only rework

    function getFactoryInfo(uint256)
        external
        view
        override
        returns (FactoryInfo memory)
    {
        return FactoryInfo({
            factoryAddress: address(0),
            factoryId: 0,
            contractType: "",
            title: "",
            displayTitle: "",
            metadataURI: "",
            features: new bytes32[](0),
            creator: address(0),
            active: false,
            registeredAt: 0
        });
    }

    function getFactoryInfoByAddress(address)
        external
        view
        override
        returns (FactoryInfo memory)
    {
        return FactoryInfo({
            factoryAddress: address(0),
            factoryId: 0,
            contractType: "",
            title: "",
            displayTitle: "",
            metadataURI: "",
            features: new bytes32[](0),
            creator: address(0),
            active: false,
            registeredAt: 0
        });
    }

    function getTotalFactories() external view override returns (uint256) {
        return 0;
    }

    function getInstanceInfo(address) external view override returns (InstanceInfo memory) {
        return InstanceInfo({
            instance: address(0),
            factory: address(0),
            creator: address(0),
            vault: address(0),
            name: "",
            metadataURI: "",
            nameHash: bytes32(0),
            registeredAt: 0
        });
    }

    function registerVault(
        address,
        string memory,
        string memory,
        uint256
    ) external override {}

    function getVaultInfo(address)
        external
        view
        override
        returns (VaultInfo memory)
    {
        return VaultInfo({
            vault: address(0),
            creator: address(0),
            name: "",
            metadataURI: "",
            active: false,
            registeredAt: 0,
            targetId: 0
        });
    }

    function isVaultRegistered(address) external view override returns (bool) {
        return true; // Always return true in mock for testing
    }

    function deactivateVault(address) external override {}

    // Alignment Target stubs
    function registerAlignmentTarget(
        string memory,
        string memory,
        string memory,
        AlignmentAsset[] memory
    ) external override returns (uint256) {
        return 0;
    }

    function getAlignmentTarget(uint256) external view override returns (AlignmentTarget memory) {
        return AlignmentTarget({
            id: 0,
            title: "",
            description: "",
            metadataURI: "",
            approvedAt: 0,
            active: false
        });
    }

    function getAlignmentTargetAssets(uint256) external view override returns (AlignmentAsset[] memory) {
        return new AlignmentAsset[](0);
    }

    function isAlignmentTargetActive(uint256) external view override returns (bool) {
        return false;
    }

    function isApprovedAlignmentToken(uint256, address) external view override returns (bool) {
        return false;
    }

    function deactivateAlignmentTarget(uint256) external override {}

    function updateAlignmentTarget(
        uint256,
        string memory,
        string memory
    ) external override {}

    function addAmbassador(uint256, address) external override {}
    function removeAmbassador(uint256, address) external override {}

    function getAmbassadors(uint256) external view override returns (address[] memory) {
        return new address[](0);
    }

    function isAmbassador(uint256, address) external view override returns (bool) {
        return false;
    }

    function vaultRegistrationFee() external view override returns (uint256) {
        return 0;
    }

    address private _globalMessageRegistry;

    function getGlobalMessageRegistry() external view override returns (address) {
        return _globalMessageRegistry;
    }

    function setGlobalMessageRegistry(address registry) external {
        _globalMessageRegistry = registry;
    }

    function isInstanceFromApprovedFactory(address) external view override returns (bool) {
        return true; // Always return true in mock for testing
    }

    // Namespace tracking for name collision tests
    mapping(bytes32 => bool) private _nameHashes;

    function isNameTaken(string memory name) external view override returns (bool) {
        bytes32 nameHash = keccak256(abi.encodePacked(_toLowerCase(name)));
        return _nameHashes[nameHash];
    }

    // Helper to mark a name as taken (for testing)
    function markNameTaken(string memory name) external {
        bytes32 nameHash = keccak256(abi.encodePacked(_toLowerCase(name)));
        _nameHashes[nameHash] = true;
    }

    // Simple lowercase helper (matches MetadataUtils behavior)
    function _toLowerCase(string memory str) internal pure returns (string memory) {
        bytes memory bStr = bytes(str);
        bytes memory bLower = new bytes(bStr.length);
        for (uint256 i = 0; i < bStr.length; i++) {
            if ((uint8(bStr[i]) >= 65) && (uint8(bStr[i]) <= 90)) {
                bLower[i] = bytes1(uint8(bStr[i]) + 32);
            } else {
                bLower[i] = bStr[i];
            }
        }
        return string(bLower);
    }
}
