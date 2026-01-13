// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {MasterRegistryV1} from "../../src/master/MasterRegistryV1.sol";
import {MasterRegistry} from "../../src/master/MasterRegistry.sol";
import {FeaturedQueueManager} from "../../src/master/FeaturedQueueManager.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";
import {MockFactory} from "../mocks/MockFactory.sol";
import {IMasterRegistry} from "../../src/master/interfaces/IMasterRegistry.sol";
import {TestHelpers} from "../helpers/TestHelpers.sol";

/**
 * @title FullWorkflowIntegrationTest
 * @notice End-to-end integration tests covering complete workflows:
 * - Factory application → Voting → Approval → Instance creation → Featured promotion
 */
contract FullWorkflowIntegrationTest is Test {
    MasterRegistryV1 public implementation;
    MasterRegistry public proxyWrapper;
    address public proxy;
    FeaturedQueueManager public queueManager;
    MockEXECToken public execToken;
    MockFactory public erc404Factory;

    address public owner;
    address public applicant;
    address public voter1;
    address public voter2;
    address public creator;
    address public purchaser;

    uint256 constant APPLICATION_FEE = 0.1 ether;
    uint256 constant INITIAL_EXEC_SUPPLY = 100000e18;

    function setUp() public {
        owner = address(this);
        applicant = address(0x111);
        voter1 = address(0x222);
        voter2 = address(0x333);
        creator = address(0x444);
        purchaser = address(0x555);

        execToken = new MockEXECToken(INITIAL_EXEC_SUPPLY);
        execToken.transfer(voter1, 2000e18);
        execToken.transfer(voter2, 1500e18);

        implementation = new MasterRegistryV1();
        bytes memory initData = abi.encodeWithSelector(
            MasterRegistryV1.initialize.selector,
            address(execToken),
            owner
        );
        proxyWrapper = new MasterRegistry(address(implementation), initData);
        proxy = TestHelpers.getProxyAddress(proxyWrapper);

        // Deploy and setup FeaturedQueueManager
        queueManager = new FeaturedQueueManager();
        queueManager.initialize(proxy, owner);
        MasterRegistryV1(proxy).setFeaturedQueueManager(address(queueManager));

        erc404Factory = new MockFactory(proxy);
    }

    function test_FullWorkflow_ApplicationToFeaturedPromotion() public {
        // Step 1: Register factory directly (owner permission)
        MasterRegistryV1(proxy).registerFactory(
            address(erc404Factory),
            "ERC404",
            "my-erc404-factory",
            "My ERC404 Factory",
            "https://example.com/factory.json"
        );

        // Verify factory registered
        IMasterRegistry.FactoryInfo memory factoryInfo =
            IMasterRegistry(proxy).getFactoryInfoByAddress(address(erc404Factory));
        assertEq(factoryInfo.factoryId, 1);
        assertTrue(factoryInfo.active);
        assertEq(IMasterRegistry(proxy).getTotalFactories(), 1);

        // Step 2: Register instance
        address instance = address(0xAAA);
        vm.prank(address(erc404Factory));
        IMasterRegistry(proxy).registerInstance(
            instance,
            address(erc404Factory),
            creator,
            "my-token",
            "https://example.com/token.json",
            address(0) // vault
        );

        // Step 3: Rent featured position (queue-based)
        uint256 desiredPosition = 1; // Position 1 (front of queue)
        uint256 duration = 7 days;
        uint256 currentPrice = queueManager.calculateRentalCost(desiredPosition, duration);

        vm.deal(purchaser, currentPrice);
        vm.prank(purchaser);
        queueManager.rentFeaturedPosition{value: currentPrice}(
            instance,
            desiredPosition,
            duration
        );

        // Verify promotion purchased
        (
            IMasterRegistry.RentalSlot memory promo,
            uint256 position,
            ,
            bool isExpired
        ) = queueManager.getRentalInfo(instance);

        assertEq(promo.instance, instance);
        assertEq(promo.renter, purchaser);
        assertEq(position, 1); // First in queue
        assertFalse(isExpired);
        assertTrue(promo.active);
    }

    function test_FullWorkflow_MultipleFactoriesAndInstances() public {
        // Register first factory directly
        MasterRegistryV1(proxy).registerFactory(
            address(erc404Factory),
            "ERC404",
            "factory-1",
            "Factory 1",
            "https://example.com/factory1.json"
        );

        // Register second factory
        MockFactory factory2 = new MockFactory(address(proxy));
        MasterRegistryV1(proxy).registerFactory(
            address(factory2),
            "ERC1155",
            "factory-2",
            "Factory 2",
            "https://example.com/factory2.json"
        );

        // Verify both factories registered
        assertEq(IMasterRegistry(proxy).getTotalFactories(), 2);

        // Create instances from both factories
        address instance1 = address(0xAAA);
        address instance2 = address(0xBBB);

        vm.prank(address(erc404Factory));
        IMasterRegistry(proxy).registerInstance(
            instance1,
            address(erc404Factory),
            creator,
            "token-1",
            "https://example.com/token1.json",
            address(0) // vault
        );

        vm.prank(address(factory2));
        IMasterRegistry(proxy).registerInstance(
            instance2,
            address(factory2),
            creator,
            "token-2",
            "https://example.com/token2.json",
            address(0) // vault
        );

        // Verify instances registered (by checking name uniqueness)
        address duplicateInstance = address(0xCCC);
        vm.prank(address(erc404Factory));
        vm.expectRevert("Name already taken");
        IMasterRegistry(proxy).registerInstance(
            duplicateInstance,
            address(erc404Factory),
            creator,
            "token-1", // Duplicate name
            "https://example.com/duplicate.json",
            address(0) // vault
        );
    }

    // Note: Test removed - governance workflow (application/voting/rejection)
    // has been moved to FactoryApprovalGovernance module.
    // See test/governance/FactoryApprovalGovernance.t.sol for governance tests.

    function test_FullWorkflow_DynamicPricing() public {
        // Setup: Register factory directly
        MasterRegistryV1(proxy).registerFactory(
            address(erc404Factory),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/factory.json"
        );

        address instance = address(0xAAA);
        vm.prank(address(erc404Factory));
        IMasterRegistry(proxy).registerInstance(
            instance,
            address(erc404Factory),
            creator,
            "test-token",
            "https://example.com/token.json",
            address(0) // vault
        );

        // Rent multiple positions and verify price changes
        uint256 duration = 7 days;
        uint256[] memory prices = new uint256[](3);

        for (uint256 i = 0; i < 3; i++) {
            // Each subsequent rental will be for the next position (1, 2, 3)
            uint256 position = i + 1;
            prices[i] = queueManager.calculateRentalCost(position, duration);

            address instanceAddr = address(uint160(0xAAA + i));
            if (i > 0) {
                // Register additional instances for different promotions
                vm.prank(address(erc404Factory));
                IMasterRegistry(proxy).registerInstance(
                    instanceAddr,
                    address(erc404Factory),
                    creator,
                    string(abi.encodePacked("token-", vm.toString(i))),
                    string(abi.encodePacked("https://example.com/token", vm.toString(i), ".json")),
                    address(0) // vault
                );
            }

            vm.deal(purchaser, prices[i] * 2);
            vm.prank(purchaser);
            queueManager.rentFeaturedPosition{value: prices[i]}(
                instanceAddr,
                position,
                duration
            );
        }

        // Verify prices increased (or at least changed)
        // Note: Prices may increase due to utilization or demand factors
        assertGe(prices[2], prices[0]);
    }

    function test_FullWorkflow_MetadataValidation() public {
        // Test with various valid metadata URIs
        string[4] memory validURIs = [
            "https://example.com/metadata.json",
            "http://example.com/metadata.json",
            "ipfs://QmHash/metadata.json",
            "ar://arweave-hash/metadata.json"
        ];

        for (uint256 i = 0; i < validURIs.length; i++) {
            MockFactory newFactory = new MockFactory(address(proxy));

            MasterRegistryV1(proxy).registerFactory(
                address(newFactory),
                "ERC404",
                string(abi.encodePacked("factory-", vm.toString(i))),
                "Test Factory",
                validURIs[i]
            );
        }

        assertEq(IMasterRegistry(proxy).getTotalFactories(), 4);
    }
}

