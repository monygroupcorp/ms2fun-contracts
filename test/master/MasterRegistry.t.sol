// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MasterRegistryV1} from "../../src/master/MasterRegistryV1.sol";
import {IMasterRegistry} from "../../src/master/interfaces/IMasterRegistry.sol";

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
    address public daoOwner = makeAddr("dao");
    address public alice = makeAddr("alice");
    address public dummyToken = address(0x1234);

    function setUp() public {
        registry = new MasterRegistryV1();
        registry.initialize(daoOwner);
    }

    function test_Initialize_SetsOwner() public view {
        assertEq(registry.owner(), daoOwner);
    }

    function test_Initialize_NoDictator() public view {
        assertEq(registry.dictator(), address(0));
    }

    function test_RegisterFactory_OwnerOnly() public {
        MockFactory factory = new MockFactory(alice, daoOwner);
        vm.prank(daoOwner);
        registry.registerFactory(address(factory), "ERC404", "Test", "Test Factory", "ipfs://test");
        assertTrue(registry.isFactoryRegistered(address(factory)));
    }

    function test_RegisterFactory_RevertIfNotOwner() public {
        MockFactory factory = new MockFactory(alice, daoOwner);
        vm.prank(alice);
        vm.expectRevert("Only owner");
        registry.registerFactory(address(factory), "ERC404", "Test", "Test Factory", "ipfs://test");
    }

    function test_RegisterVault_OwnerOnly() public {
        // Create an alignment target with dummyToken
        IMasterRegistry.AlignmentAsset[] memory assets = new IMasterRegistry.AlignmentAsset[](1);
        assets[0] = IMasterRegistry.AlignmentAsset({
            token: dummyToken,
            symbol: "DUMMY",
            info: "",
            metadataURI: ""
        });

        vm.prank(daoOwner);
        uint256 targetId = registry.registerAlignmentTarget("Test Target", "", "", assets);

        // Deploy vault with matching alignment token
        MockVaultSimple vault = new MockVaultSimple(dummyToken);

        vm.prank(daoOwner);
        registry.registerVault(address(vault), "Test Vault", "ipfs://test", targetId);
        assertTrue(registry.isVaultRegistered(address(vault)));
    }

    function test_RegisterVault_RevertIfNotOwner() public {
        // Revert happens at "Only owner" check before target validation, so targetId 0 is fine
        MockVaultSimple vault = new MockVaultSimple(dummyToken);
        vm.prank(alice);
        vm.expectRevert("Only owner");
        registry.registerVault(address(vault), "Test Vault", "ipfs://test", 0);
    }
}
