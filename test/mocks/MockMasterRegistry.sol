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

    function applyForFactory(
        address,
        string memory,
        string memory,
        string memory,
        string memory,
        bytes32[] memory
    ) external payable override {}

    function registerInstance(
        address,
        address,
        address,
        string memory,
        string memory,
        address
    ) external override {}

    function getFactoryApplication(address)
        external
        view
        override
        returns (FactoryApplication memory)
    {
        return FactoryApplication({
            factoryAddress: address(0),
            applicant: address(0),
            contractType: "",
            title: "",
            displayTitle: "",
            metadataURI: "",
            features: new bytes32[](0),
            status: ApplicationStatus.Pending,
            applicationFee: 0,
            createdAt: 0,
            totalVotes: 0,
            approvalVotes: 0,
            rejectionVotes: 0,
            rejectionReason: "",
            verified: false,
            verificationURI: ""
        });
    }

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

    // Competitive rental queue functions
    function getPositionRentalPrice(uint256) external view override returns (uint256) {
        return 0.001 ether;
    }

    function calculateRentalCost(uint256, uint256) external view override returns (uint256) {
        return 0.001 ether;
    }

    function rentFeaturedPosition(address, uint256, uint256) external payable override {}

    function renewPosition(address, uint256) external payable override {}

    function bumpPosition(address, uint256, uint256) external payable override {}

    function getFeaturedInstances(uint256, uint256)
        external
        view
        override
        returns (address[] memory instances, uint256 total)
    {
        return (new address[](0), 0);
    }

    function getRentalInfo(address)
        external
        view
        override
        returns (
            RentalSlot memory rental,
            uint256 position,
            uint256 renewalDeposit,
            bool isExpired
        )
    {
        return (
            RentalSlot({
                instance: address(0),
                renter: address(0),
                rentPaid: 0,
                rentedAt: 0,
                expiresAt: 0,
                originalPosition: 0,
                active: false
            }),
            0,
            0,
            false
        );
    }

    function depositForAutoRenewal(address) external payable override {}

    function withdrawRenewalDeposit(address) external override {}

    function cleanupExpiredRentals(uint256) external override {}

    function registerVault(
        address,
        string memory,
        string memory
    ) external payable override {}

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
            instanceCount: 0
        });
    }

    function getVaultList() external view override returns (address[] memory) {
        return new address[](0);
    }

    function isVaultRegistered(address) external view override returns (bool) {
        return true; // Always return true in mock for testing
    }

    function deactivateVault(address) external override {}

    function vaultRegistrationFee() external view override returns (uint256) {
        return 0;
    }

    function getGlobalMessageRegistry() external view override returns (address) {
        return address(0); // No global registry in mock
    }
}
