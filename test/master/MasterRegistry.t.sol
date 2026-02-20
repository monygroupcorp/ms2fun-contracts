// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {MasterRegistryV1} from "../../src/master/MasterRegistryV1.sol";
import {AlignmentRegistryV1} from "../../src/master/AlignmentRegistryV1.sol";
import {IMasterRegistry} from "../../src/master/interfaces/IMasterRegistry.sol";
import {IAlignmentRegistry} from "../../src/master/interfaces/IAlignmentRegistry.sol";

contract MockFactory {
    address public creator;
    address public protocol;
    constructor(address _creator, address _protocol) {
        creator = _creator;
        protocol = _protocol;
    }
}

contract MockVaultSimple {
    address public alignmentToken;
    constructor(address _token) {
        alignmentToken = _token;
    }
}

contract MasterRegistryReworkTest is Test {
    MasterRegistryV1 public registry;
    AlignmentRegistryV1 public alignmentRegistry;
    address public daoOwner = makeAddr("dao");
    address public alice = makeAddr("alice");
    address public dummyToken = address(0x1234);

    function setUp() public {
        registry = new MasterRegistryV1();
        registry.initialize(daoOwner);

        alignmentRegistry = new AlignmentRegistryV1();
        alignmentRegistry.initialize(daoOwner);

        // Wire alignment registry
        vm.prank(daoOwner);
        registry.setAlignmentRegistry(address(alignmentRegistry));
    }

    function test_Initialize_SetsOwner() public view {
        assertEq(registry.owner(), daoOwner);
    }

    function test_RegisterFactory_OwnerOnly() public {
        MockFactory factory = new MockFactory(alice, daoOwner);
        vm.prank(daoOwner);
        registry.registerFactory(address(factory), "ERC404", "Test", "Test Factory", "ipfs://test", new bytes32[](0));
        assertTrue(registry.isFactoryRegistered(address(factory)));
    }

    function test_RegisterFactory_RevertIfNotOwner() public {
        MockFactory factory = new MockFactory(alice, daoOwner);
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.registerFactory(address(factory), "ERC404", "Test", "Test Factory", "ipfs://test", new bytes32[](0));
    }

    function test_RegisterVault_OwnerOnly() public {
        // Create an alignment target with dummyToken
        IAlignmentRegistry.AlignmentAsset[] memory assets = new IAlignmentRegistry.AlignmentAsset[](1);
        assets[0] = IAlignmentRegistry.AlignmentAsset({
            token: dummyToken,
            symbol: "DUMMY",
            info: "",
            metadataURI: ""
        });

        vm.prank(daoOwner);
        uint256 targetId = alignmentRegistry.registerAlignmentTarget("Test Target", "", "", assets);

        // Deploy vault with matching alignment token
        MockVaultSimple vault = new MockVaultSimple(dummyToken);

        vm.prank(daoOwner);
        registry.registerVault(address(vault), daoOwner, "Test Vault", "ipfs://test", targetId);
        assertTrue(registry.isVaultRegistered(address(vault)));
    }

    function test_RegisterVault_RevertIfNotAuthorized() public {
        MockVaultSimple vault = new MockVaultSimple(dummyToken);
        vm.prank(alice);
        vm.expectRevert("Not authorized");
        registry.registerVault(address(vault), alice, "Test Vault", "ipfs://test", 0);
    }

    // ============ DeactivateFactory Tests ============

    function test_DeactivateFactory_OwnerOnly() public {
        MockFactory factory = new MockFactory(alice, daoOwner);
        vm.prank(daoOwner);
        registry.registerFactory(address(factory), "ERC404", "Test", "Test Factory", "ipfs://test", new bytes32[](0));

        vm.prank(daoOwner);
        registry.deactivateFactory(address(factory));

        IMasterRegistry.FactoryInfo memory info = registry.getFactoryInfoByAddress(address(factory));
        assertFalse(info.active);
    }

    function test_DeactivateFactory_RevertIfNotOwner() public {
        MockFactory factory = new MockFactory(alice, daoOwner);
        vm.prank(daoOwner);
        registry.registerFactory(address(factory), "ERC404", "Test", "Test Factory", "ipfs://test", new bytes32[](0));

        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        registry.deactivateFactory(address(factory));
    }

    function test_DeactivateFactory_RevertIfAlreadyInactive() public {
        MockFactory factory = new MockFactory(alice, daoOwner);
        vm.prank(daoOwner);
        registry.registerFactory(address(factory), "ERC404", "Test", "Test Factory", "ipfs://test", new bytes32[](0));

        vm.prank(daoOwner);
        registry.deactivateFactory(address(factory));

        vm.prank(daoOwner);
        vm.expectRevert("Factory already inactive");
        registry.deactivateFactory(address(factory));
    }

    function test_DeactivateFactory_RevertIfNotRegistered() public {
        vm.prank(daoOwner);
        vm.expectRevert("Factory not registered");
        registry.deactivateFactory(address(0x999));
    }
}
