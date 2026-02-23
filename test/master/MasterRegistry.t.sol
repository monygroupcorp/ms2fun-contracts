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

contract MockInstance {
    address public vault;
    address public protocolTreasury;
    address private _globalMessageRegistry;
    address private _masterRegistry;

    function initialize(address _vault, address _treasury, address _gmr, address _mr) external {
        vault = _vault;
        protocolTreasury = _treasury;
        _globalMessageRegistry = _gmr;
        _masterRegistry = _mr;
    }

    function getGlobalMessageRegistry() external view returns (address) {
        return _globalMessageRegistry;
    }

    function instanceType() external pure returns (bytes32) {
        return keccak256("erc404");
    }

    function migrateVault(address newVault) external {
        vault = newVault;
        IMasterRegistry(_masterRegistry).migrateVault(address(this), newVault);
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

    // ============ Migration Helpers ============

    function _setupTargetAndVault(address token) internal returns (uint256 targetId, address vault) {
        IAlignmentRegistry.AlignmentAsset[] memory assets = new IAlignmentRegistry.AlignmentAsset[](1);
        assets[0] = IAlignmentRegistry.AlignmentAsset({
            token: token,
            symbol: "TKN",
            info: "",
            metadataURI: ""
        });
        vm.prank(daoOwner);
        targetId = alignmentRegistry.registerAlignmentTarget("Target", "", "", assets);
        vault = address(new MockVaultSimple(token));
        vm.prank(daoOwner);
        registry.registerVault(vault, alice, "Vault One", "ipfs://v1", targetId);
    }

    function _registerFactory() internal returns (address factory) {
        factory = address(new MockFactory(alice, daoOwner));
        vm.prank(daoOwner);
        registry.registerFactory(factory, "ERC404", "Test", "Test Factory", "ipfs://factory", new bytes32[](0));
    }

    function _registerInstance(address factory, address vault) internal returns (address instance) {
        MockInstance inst = new MockInstance();
        inst.initialize(vault, alice, address(0x999), address(registry));
        vm.prank(factory);
        registry.registerInstance(address(inst), factory, alice, "MyProject", "ipfs://proj", vault);
        return address(inst);
    }

    // ============ Vault Array Tests ============

    function test_RegisterInstance_StoresVaultArray() public {
        (, address vault) = _setupTargetAndVault(dummyToken);
        address factory = _registerFactory();
        address instance = _registerInstance(factory, vault);

        address[] memory vaults = registry.getInstanceVaults(instance);
        assertEq(vaults.length, 1);
        assertEq(vaults[0], vault);
        assertEq(registry.getActiveVault(instance), vault);
    }

    function test_MigrateVault_AppendsToArray() public {
        (uint256 targetId, address vault1) = _setupTargetAndVault(dummyToken);
        address factory = _registerFactory();
        address instance = _registerInstance(factory, vault1);

        address vault2 = address(new MockVaultSimple(dummyToken));
        vm.prank(daoOwner);
        registry.registerVault(vault2, alice, "Vault Two", "ipfs://v2", targetId);

        vm.prank(instance);
        registry.migrateVault(instance, vault2);

        address[] memory vaults = registry.getInstanceVaults(instance);
        assertEq(vaults.length, 2);
        assertEq(vaults[0], vault1);
        assertEq(vaults[1], vault2);
        assertEq(registry.getActiveVault(instance), vault2);
    }

    function test_MigrateVault_RevertIfNotCalledByInstance() public {
        (, address vault1) = _setupTargetAndVault(dummyToken);
        address factory = _registerFactory();
        address instance = _registerInstance(factory, vault1);

        address vault2 = address(new MockVaultSimple(dummyToken));

        vm.prank(alice);
        vm.expectRevert("Only instance can migrate");
        registry.migrateVault(instance, vault2);
    }

    function test_MigrateVault_RevertIfDifferentTarget() public {
        (uint256 targetId, address vault1) = _setupTargetAndVault(dummyToken);
        address factory = _registerFactory();
        address instance = _registerInstance(factory, vault1);

        address otherToken = address(0x5678);
        IAlignmentRegistry.AlignmentAsset[] memory assets2 = new IAlignmentRegistry.AlignmentAsset[](1);
        assets2[0] = IAlignmentRegistry.AlignmentAsset({ token: otherToken, symbol: "OTH", info: "", metadataURI: "" });
        vm.prank(daoOwner);
        uint256 otherId = alignmentRegistry.registerAlignmentTarget("Other", "", "", assets2);
        address vault2 = address(new MockVaultSimple(otherToken));
        vm.prank(daoOwner);
        registry.registerVault(vault2, alice, "Other Vault", "ipfs://v2", otherId);

        vm.prank(instance);
        vm.expectRevert("Vault target mismatch");
        registry.migrateVault(instance, vault2);
    }

    function test_MigrateVault_RevertIfDuplicate() public {
        (, address vault1) = _setupTargetAndVault(dummyToken);
        address factory = _registerFactory();
        address instance = _registerInstance(factory, vault1);

        vm.prank(instance);
        vm.expectRevert("Vault already in array");
        registry.migrateVault(instance, vault1);
    }

    function test_MigrateVault_RevertIfVaultInactive() public {
        (, address vault1) = _setupTargetAndVault(dummyToken);
        address factory = _registerFactory();
        address instance = _registerInstance(factory, vault1);

        address vault2 = address(new MockVaultSimple(dummyToken));
        // vault2 is NOT registered

        vm.prank(instance);
        vm.expectRevert("New vault not active");
        registry.migrateVault(instance, vault2);
    }
}
