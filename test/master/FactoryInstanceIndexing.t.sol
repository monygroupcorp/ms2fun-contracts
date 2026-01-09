// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {MasterRegistryV1} from "../../src/master/MasterRegistryV1.sol";
import {MasterRegistry} from "../../src/master/MasterRegistry.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";
import {MockFactory} from "../mocks/MockFactory.sol";
import {IMasterRegistry} from "../../src/master/interfaces/IMasterRegistry.sol";
import {TestHelpers} from "../helpers/TestHelpers.sol";

/**
 * @title FactoryInstanceIndexingTest
 * @notice Tests for factory and instance indexing, retrieval, and metadata handling
 */
contract FactoryInstanceIndexingTest is Test {
    MasterRegistryV1 public implementation;
    MasterRegistry public proxyWrapper;
    address public proxy;
    MockEXECToken public execToken;
    MockFactory public erc404Factory;
    MockFactory public erc1155Factory;

    address public owner;
    address public applicant1;
    address public applicant2;
    address public voter1;
    address public creator1;
    address public creator2;

    uint256 constant APPLICATION_FEE = 0.1 ether;
    uint256 constant INITIAL_EXEC_SUPPLY = 100000e18;

    function setUp() public {
        owner = address(this);
        applicant1 = address(0x111);
        applicant2 = address(0x222);
        voter1 = address(0x333);
        creator1 = address(0x666);
        creator2 = address(0x777);

        execToken = new MockEXECToken(INITIAL_EXEC_SUPPLY);
        execToken.transfer(voter1, 2000e18);

        implementation = new MasterRegistryV1();
        bytes memory initData = abi.encodeWithSelector(
            MasterRegistryV1.initialize.selector,
            address(execToken),
            owner
        );
        proxyWrapper = new MasterRegistry(address(implementation), initData);
        proxy = TestHelpers.getProxyAddress(proxyWrapper);

        erc404Factory = new MockFactory(proxy);
        erc1155Factory = new MockFactory(proxy);
    }

    function test_FactoryIndexing_MultipleFactories() public {
        // Register ERC404 factory directly
        MasterRegistryV1(proxy).registerFactory(
            address(erc404Factory),
            "ERC404",
            "erc404-factory",
            "ERC404 Factory",
            "https://example.com/erc404.json"
        );

        // Register ERC1155 factory directly
        MasterRegistryV1(proxy).registerFactory(
            address(erc1155Factory),
            "ERC1155",
            "erc1155-factory",
            "ERC1155 Factory",
            "https://example.com/erc1155.json"
        );

        // Verify indexing
        assertEq(IMasterRegistry(proxy).getTotalFactories(), 2);
        
        IMasterRegistry.FactoryInfo memory factory1 = 
            IMasterRegistry(proxy).getFactoryInfo(1);
        assertEq(factory1.factoryId, 1);
        assertEq(factory1.factoryAddress, address(erc404Factory));
        assertEq(factory1.contractType, "ERC404");
        
        IMasterRegistry.FactoryInfo memory factory2 = 
            IMasterRegistry(proxy).getFactoryInfo(2);
        assertEq(factory2.factoryId, 2);
        assertEq(factory2.factoryAddress, address(erc1155Factory));
        assertEq(factory2.contractType, "ERC1155");
    }

    function test_FactoryMetadata_Retrieval() public {
        // Register factory with features
        bytes32[] memory features = new bytes32[](3);
        features[0] = keccak256("BONDING_CURVE");
        features[1] = keccak256("LIQUIDITY_POOL");
        features[2] = keccak256("CHAT");

        MasterRegistryV1(proxy).registerFactoryWithFeatures(
            address(erc404Factory),
            "ERC404",
            "featured-factory",
            "Featured Factory",
            "https://example.com/featured.json",
            features
        );

        // Retrieve and verify metadata
        IMasterRegistry.FactoryInfo memory info = 
            IMasterRegistry(proxy).getFactoryInfoByAddress(address(erc404Factory));
        
        assertEq(info.title, "featured-factory");
        assertEq(info.displayTitle, "Featured Factory");
        assertEq(info.metadataURI, "https://example.com/featured.json");
        assertEq(info.features.length, 3);
        assertEq(info.creator, applicant1);
        assertTrue(info.active);
        assertGt(info.registeredAt, 0);
    }

    function test_InstanceRegistration_MultipleInstances() public {
        // Setup: Register factory
        MasterRegistryV1(proxy).registerFactory(
            address(erc404Factory),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/metadata.json"
        );

        // Register multiple instances
        address[] memory instances = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            instances[i] = address(uint160(0x1000 + i));
            vm.prank(address(erc404Factory));
            IMasterRegistry(proxy).registerInstance(
                instances[i],
                address(erc404Factory),
                i % 2 == 0 ? creator1 : creator2,
                string(abi.encodePacked("instance-", vm.toString(i))),
                string(abi.encodePacked("https://example.com/instance", vm.toString(i), ".json")),
                address(0) // vault
            );
        }

        // Verify all instances registered (checking name uniqueness)
        for (uint256 i = 0; i < 5; i++) {
            // Try to register duplicate name - should fail
            address duplicateInstance = address(uint160(0x2000 + i));
            vm.prank(address(erc404Factory));
            vm.expectRevert("Name already taken");
            IMasterRegistry(proxy).registerInstance(
                duplicateInstance,
                address(erc404Factory),
                creator1,
                string(abi.encodePacked("instance-", vm.toString(i))), // Same name
                "https://example.com/duplicate.json",
                address(0) // vault
            );
        }
    }

    function test_InstanceMetadata_Retrieval() public {
        // Setup: Register factory
        MasterRegistryV1(proxy).registerFactory(
            address(erc404Factory),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/metadata.json"
        );

        // Register instance with metadata
        address instance = address(0xAAA);
        string memory instanceName = "my-token";
        string memory metadataURI = "https://example.com/my-token.json";

        vm.prank(address(erc404Factory));
        IMasterRegistry(proxy).registerInstance(
            instance,
            address(erc404Factory),
            creator1,
            instanceName,
            metadataURI,
            address(0) // vault
        );

        // Note: We would need a getter function in MasterRegistryV1 to retrieve instance info
        // For now, we verify registration succeeded by checking name uniqueness
        address duplicateInstance = address(0xBBB);
        vm.prank(address(erc404Factory));
        vm.expectRevert("Name already taken");
        IMasterRegistry(proxy).registerInstance(
            duplicateInstance,
            address(erc404Factory),
            creator2,
            instanceName, // Same name should fail
            "https://example.com/duplicate.json",
            address(0) // vault
        );
    }

    function test_FactoryInstance_Relationship() public {
        // Setup: Register two factories directly
        MasterRegistryV1(proxy).registerFactory(
            address(erc404Factory),
            "ERC404",
            "erc404-factory",
            "ERC404 Factory",
            "https://example.com/erc404.json"
        );

        MasterRegistryV1(proxy).registerFactory(
            address(erc1155Factory),
            "ERC1155",
            "erc1155-factory",
            "ERC1155 Factory",
            "https://example.com/erc1155.json"
        );

        // Register instances from different factories
        address erc404Instance = address(0xAAA);
        address erc1155Instance = address(0xBBB);

        vm.prank(address(erc404Factory));
        IMasterRegistry(proxy).registerInstance(
            erc404Instance,
            address(erc404Factory),
            creator1,
            "erc404-token",
            "https://example.com/erc404-token.json",
            address(0) // vault
        );

        vm.prank(address(erc1155Factory));
        IMasterRegistry(proxy).registerInstance(
            erc1155Instance,
            address(erc1155Factory),
            creator2,
            "erc1155-token",
            "https://example.com/erc1155-token.json",
            address(0) // vault
        );

        // Verify factories are separate
        IMasterRegistry.FactoryInfo memory factory1 = 
            IMasterRegistry(proxy).getFactoryInfoByAddress(address(erc404Factory));
        IMasterRegistry.FactoryInfo memory factory2 = 
            IMasterRegistry(proxy).getFactoryInfoByAddress(address(erc1155Factory));
        
        assertEq(factory1.contractType, "ERC404");
        assertEq(factory2.contractType, "ERC1155");
    }

    function test_InstanceName_CaseInsensitive() public {
        // Setup: Register factory
        MasterRegistryV1(proxy).registerFactory(
            address(erc404Factory),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/metadata.json"
        );

        // Register instance with lowercase name
        address instance1 = address(0xAAA);
        vm.prank(address(erc404Factory));
        IMasterRegistry(proxy).registerInstance(
            instance1,
            address(erc404Factory),
            creator1,
            "test-token",
            "https://example.com/token.json",
            address(0) // vault
        );

        // Try to register with uppercase name (should fail - case insensitive)
        address instance2 = address(0xBBB);
        vm.prank(address(erc404Factory));
        vm.expectRevert("Name already taken");
        IMasterRegistry(proxy).registerInstance(
            instance2,
            address(erc404Factory),
            creator2,
            "TEST-TOKEN", // Uppercase version
            "https://example.com/token2.json",
            address(0) // vault
        );
    }

    function test_FactoryFeatures_Indexing() public {
        // Register factory with specific features
        bytes32[] memory features = new bytes32[](2);
        features[0] = keccak256("FEATURE_A");
        features[1] = keccak256("FEATURE_B");

        MasterRegistryV1(proxy).registerFactoryWithFeatures(
            address(erc404Factory),
            "ERC404",
            "featured-factory",
            "Featured Factory",
            "https://example.com/featured.json",
            features
        );

        // Retrieve and verify features
        IMasterRegistry.FactoryInfo memory info = 
            IMasterRegistry(proxy).getFactoryInfoByAddress(address(erc404Factory));
        
        assertEq(info.features.length, 2);
        assertEq(info.features[0], keccak256("FEATURE_A"));
        assertEq(info.features[1], keccak256("FEATURE_B"));
    }
}

