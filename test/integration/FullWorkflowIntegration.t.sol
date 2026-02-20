// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {MasterRegistryV1} from "../../src/master/MasterRegistryV1.sol";
import {MasterRegistry} from "../../src/master/MasterRegistry.sol";
import {FeaturedQueueManager} from "../../src/master/FeaturedQueueManager.sol";
import {MockEXECToken} from "../mocks/MockEXECToken.sol";
import {MockFactory} from "../mocks/MockFactory.sol";
import {MockInstance} from "../mocks/MockInstance.sol";
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
    address public mockVault;

    uint256 constant APPLICATION_FEE = 0.1 ether;
    uint256 constant INITIAL_EXEC_SUPPLY = 100000e18;

    function setUp() public {
        owner = address(this);
        applicant = address(0x111);
        voter1 = address(0x222);
        voter2 = address(0x333);
        creator = address(0x444);
        purchaser = address(0x555);

        implementation = new MasterRegistryV1();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address)",
            owner
        );
        proxyWrapper = new MasterRegistry(address(implementation), initData);
        proxy = TestHelpers.getProxyAddress(proxyWrapper);

        // Deploy and setup FeaturedQueueManager
        queueManager = new FeaturedQueueManager();
        queueManager.initialize(proxy, owner);

        // Deploy a contract to serve as the mock vault (just needs code at address)
        mockVault = address(new MockInstance(address(0)));

        erc404Factory = new MockFactory(owner, owner);
        erc404Factory.setMasterRegistry(proxy);
    }

    /// @dev Deploy a MockInstance pointing to mockVault
    function _newInstance() internal returns (address) {
        return address(new MockInstance(mockVault));
    }

    function test_FullWorkflow_ApplicationToFeaturedPromotion() public {
        // Step 1: Register factory directly (owner permission)
        MasterRegistryV1(proxy).registerFactory(
            address(erc404Factory),
            "ERC404",
            "my-erc404-factory",
            "My ERC404 Factory",
            "https://example.com/factory.json",
            new bytes32[](0)
        );

        // Verify factory registered
        IMasterRegistry.FactoryInfo memory factoryInfo =
            IMasterRegistry(proxy).getFactoryInfoByAddress(address(erc404Factory));
        assertEq(factoryInfo.factoryId, 1);
        assertTrue(factoryInfo.active);
        assertEq(IMasterRegistry(proxy).getTotalFactories(), 1);

        // Step 2: Register instance
        address instance = _newInstance();
        vm.prank(address(erc404Factory));
        IMasterRegistry(proxy).registerInstance(
            instance,
            address(erc404Factory),
            creator,
            "my-token",
            "https://example.com/token.json",
            mockVault
        );

        // Step 3: Rent featured slot
        uint256 duration  = 7 days;
        uint256 rankBoost = 0.005 ether;
        uint256 cost      = queueManager.quoteDurationCost(duration) + rankBoost;

        vm.deal(purchaser, cost);
        vm.prank(purchaser);
        queueManager.rentFeatured{value: cost}(instance, duration, rankBoost);

        // Verify slot active
        (address renter, uint256 effectiveRank, uint256 expiresAt, bool isActive) =
            queueManager.getRentalInfo(instance);

        assertEq(renter, purchaser);
        assertEq(effectiveRank, rankBoost);
        assertGt(expiresAt, block.timestamp);
        assertTrue(isActive);
    }

    function test_FullWorkflow_MultipleFactoriesAndInstances() public {
        // Register first factory directly
        MasterRegistryV1(proxy).registerFactory(
            address(erc404Factory),
            "ERC404",
            "factory-1",
            "Factory 1",
            "https://example.com/factory1.json",
            new bytes32[](0)
        );

        // Register second factory
        MockFactory factory2 = new MockFactory(owner, owner);
        factory2.setMasterRegistry(address(proxy));
        MasterRegistryV1(proxy).registerFactory(
            address(factory2),
            "ERC1155",
            "factory-2",
            "Factory 2",
            "https://example.com/factory2.json",
            new bytes32[](0)
        );

        // Verify both factories registered
        assertEq(IMasterRegistry(proxy).getTotalFactories(), 2);

        // Create instances from both factories
        address instance1 = _newInstance();
        address instance2 = _newInstance();

        vm.prank(address(erc404Factory));
        IMasterRegistry(proxy).registerInstance(
            instance1,
            address(erc404Factory),
            creator,
            "token-1",
            "https://example.com/token1.json",
            mockVault
        );

        vm.prank(address(factory2));
        IMasterRegistry(proxy).registerInstance(
            instance2,
            address(factory2),
            creator,
            "token-2",
            "https://example.com/token2.json",
            mockVault
        );

        // Verify instances registered (by checking name uniqueness)
        address duplicateInstance = _newInstance();
        vm.prank(address(erc404Factory));
        vm.expectRevert("Name already taken");
        IMasterRegistry(proxy).registerInstance(
            duplicateInstance,
            address(erc404Factory),
            creator,
            "token-1", // Duplicate name
            "https://example.com/duplicate.json",
            mockVault
        );
    }

    // Note: Test removed - governance workflow (application/voting/rejection)
    // has been moved to FactoryApprovalGovernance module.
    // See test/governance/FactoryApprovalGovernance.t.sol for governance tests.

    function test_FullWorkflow_RankCompetition() public {
        // Setup: Register factory and three instances
        MasterRegistryV1(proxy).registerFactory(
            address(erc404Factory),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/factory.json",
            new bytes32[](0)
        );

        address inst1 = _newInstance();
        address inst2 = _newInstance();
        address inst3 = _newInstance();

        address[] memory instances = new address[](3);
        instances[0] = inst1; instances[1] = inst2; instances[2] = inst3;

        vm.startPrank(address(erc404Factory));
        IMasterRegistry(proxy).registerInstance(inst1, address(erc404Factory), creator, "token-1", "https://example.com/t1.json", mockVault);
        IMasterRegistry(proxy).registerInstance(inst2, address(erc404Factory), creator, "token-2", "https://example.com/t2.json", mockVault);
        IMasterRegistry(proxy).registerInstance(inst3, address(erc404Factory), creator, "token-3", "https://example.com/t3.json", mockVault);
        vm.stopPrank();

        // Rent all three with different rank boosts — higher boost = higher rank
        uint256 duration     = queueManager.minDuration();
        uint256 durationCost = queueManager.quoteDurationCost(duration);

        vm.deal(purchaser, (durationCost + 0.05 ether) * 3);
        vm.startPrank(purchaser);
        queueManager.rentFeatured{value: durationCost + 0.01 ether}(inst1, duration, 0.01 ether);
        queueManager.rentFeatured{value: durationCost + 0.05 ether}(inst2, duration, 0.05 ether);
        queueManager.rentFeatured{value: durationCost + 0.03 ether}(inst3, duration, 0.03 ether);
        vm.stopPrank();

        // Verify rank ordering: inst2 (0.05e) > inst3 (0.03e) > inst1 (0.01e)
        (address[] memory ranked, uint256 total) = queueManager.getFeaturedInstances(0, 10);
        assertEq(total, 3);
        assertEq(ranked[0], inst2);
        assertEq(ranked[1], inst3);
        assertEq(ranked[2], inst1);
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
            MockFactory newFactory = new MockFactory(owner, owner);
            newFactory.setMasterRegistry(address(proxy));

            MasterRegistryV1(proxy).registerFactory(
                address(newFactory),
                "ERC404",
                string(abi.encodePacked("factory-", vm.toString(i))),
                "Test Factory",
                validURIs[i],
                new bytes32[](0)
            );
        }

        assertEq(IMasterRegistry(proxy).getTotalFactories(), 4);
    }
}

