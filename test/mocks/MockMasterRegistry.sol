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

    function voteOnApplication(address, bool) external override {}

    function finalizeApplication(address) external override {}

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

    function getCurrentPrice(uint256) external view override returns (uint256) {
        return 0;
    }

    function purchaseFeaturedPromotion(address, uint256) external payable override {}

    function getTierPricingInfo(uint256)
        external
        view
        override
        returns (TierPricingInfo memory)
    {
        return TierPricingInfo({
            currentPrice: 0,
            utilizationRate: 0,
            demandFactor: 0,
            lastPurchaseTime: 0,
            totalPurchases: 0
        });
    }

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
}
