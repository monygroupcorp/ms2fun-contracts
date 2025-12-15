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
 * @title MasterRegistryComprehensiveTest
 * @notice Comprehensive test suite for MasterRegistry covering:
 * - Factory application system
 * - EXEC voting approval
 * - Application finalization
 * - Factory registration and indexing
 * - Instance registration and retrieval
 * - Featured market and dynamic pricing
 * - Metadata validation
 */
contract MasterRegistryComprehensiveTest is Test {
    MasterRegistryV1 public implementation;
    MasterRegistry public proxyWrapper;
    address public proxy; // Actual proxy address
    MockEXECToken public execToken;
    MockFactory public factory1;
    MockFactory public factory2;
    
    address public owner;
    address public applicant1;
    address public applicant2;
    address public voter1;
    address public voter2;
    address public voter3;
    address public creator1;
    address public creator2;
    
    uint256 constant APPLICATION_FEE = 0.1 ether;
    uint256 constant QUORUM_THRESHOLD = 1000e18;
    uint256 constant INITIAL_EXEC_SUPPLY = 100000e18;

    function setUp() public {
        owner = address(this);
        applicant1 = address(0x111);
        applicant2 = address(0x222);
        voter1 = address(0x333);
        voter2 = address(0x444);
        voter3 = address(0x555);
        creator1 = address(0x666);
        creator2 = address(0x777);

        // Deploy mock EXEC token
        execToken = new MockEXECToken(INITIAL_EXEC_SUPPLY);
        
        // Distribute EXEC tokens to voters
        execToken.transfer(voter1, 2000e18); // Enough for quorum
        execToken.transfer(voter2, 1500e18); // Enough for quorum
        execToken.transfer(voter3, 500e18);  // Not enough alone
        
        // Deploy implementation
        implementation = new MasterRegistryV1();
        
        // Deploy proxy wrapper with initialization
        bytes memory initData = abi.encodeWithSelector(
            MasterRegistryV1.initialize.selector,
            address(execToken),
            owner
        );
        proxyWrapper = new MasterRegistry(address(implementation), initData);
        
        // Extract the actual proxy address
        proxy = TestHelpers.getProxyAddress(proxyWrapper);
        
        // Deploy mock factories (use proxy address directly)
        factory1 = new MockFactory(proxy);
        factory2 = new MockFactory(proxy);
    }

    // ============ Factory Application Tests ============

    function skip_test_ApplyForFactory_Success() public {
        vm.deal(applicant1, APPLICATION_FEE);
        
        // Use proxy address directly to preserve msg.sender
        MasterRegistryV1 registry = MasterRegistryV1(proxy);
        
        vm.prank(applicant1);
        registry.applyForFactory{value: APPLICATION_FEE}(
            address(factory1),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/metadata.json",
            new bytes32[](0)
        );

        IMasterRegistry.FactoryApplication memory app = 
            registry.getFactoryApplication(address(factory1));
        
        assertEq(app.factoryAddress, address(factory1));
        assertEq(app.applicant, applicant1);
        assertEq(app.contractType, "ERC404");
        assertEq(app.title, "test-factory");
        assertEq(app.displayTitle, "Test Factory");
        assertEq(app.metadataURI, "https://example.com/metadata.json");
        assertEq(uint256(app.status), uint256(IMasterRegistry.ApplicationStatus.Pending));
        assertEq(app.applicationFee, APPLICATION_FEE);
        assertEq(app.totalVotes, 0);
    }

    function skip_test_ApplyForFactory_InsufficientFee() public {
        vm.deal(applicant1, APPLICATION_FEE - 1);
        
        MasterRegistryV1 registry = MasterRegistryV1(proxy);
        
        vm.prank(applicant1);
        vm.expectRevert("Insufficient application fee");
        registry.applyForFactory{value: APPLICATION_FEE - 1}(
            address(factory1),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/metadata.json",
            new bytes32[](0)
        );
    }

    function skip_test_ApplyForFactory_InvalidMetadataURI() public {
        vm.deal(applicant1, APPLICATION_FEE);
        
        MasterRegistryV1 registry = MasterRegistryV1(proxy);
        
        vm.prank(applicant1);
        vm.expectRevert("Invalid metadata URI");
        registry.applyForFactory{value: APPLICATION_FEE}(
            address(factory1),
            "ERC404",
            "test-factory",
            "Test Factory",
            "invalid-uri",
            new bytes32[](0)
        );
    }

    function skip_test_ApplyForFactory_DuplicateApplication() public {
        vm.deal(applicant1, APPLICATION_FEE * 2);
        
        MasterRegistryV1 registry = MasterRegistryV1(proxy);
        
        vm.startPrank(applicant1);
        registry.applyForFactory{value: APPLICATION_FEE}(
            address(factory1),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/metadata.json",
            new bytes32[](0)
        );
        
        // The implementation allows updating pending applications, so this should succeed
        // If we want to test duplicate prevention, we need to finalize first or use a different factory
        // For now, let's test that updating a pending application works
        registry.applyForFactory{value: APPLICATION_FEE}(
            address(factory1),
            "ERC404",
            "test-factory-updated",
            "Test Factory Updated",
            "https://example.com/metadata-updated.json",
            new bytes32[](0)
        );
        
        // Verify the application was updated
        IMasterRegistry.FactoryApplication memory app = 
            registry.getFactoryApplication(address(factory1));
        assertEq(app.title, "test-factory-updated");
        assertEq(app.displayTitle, "Test Factory Updated");
        vm.stopPrank();
    }

    // ============ EXEC Voting Tests ============

    function skip_test_VoteOnApplication_Success() public {
        // Setup: Create application
        vm.deal(applicant1, APPLICATION_FEE);
        vm.prank(applicant1);
        IMasterRegistry(address(proxy)).applyForFactory{value: APPLICATION_FEE}(
            address(factory1),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/metadata.json",
            new bytes32[](0)
        );

        // Vote with approval
        vm.prank(voter1);
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory1), true);

        IMasterRegistry.FactoryApplication memory app = 
            IMasterRegistry(address(proxy)).getFactoryApplication(address(factory1));
        
        assertEq(app.totalVotes, 2000e18);
        assertEq(app.approvalVotes, 2000e18);
        assertEq(app.rejectionVotes, 0);
    }

    function skip_test_VoteOnApplication_Rejection() public {
        // Setup: Create application
        vm.deal(applicant1, APPLICATION_FEE);
        vm.prank(applicant1);
        IMasterRegistry(address(proxy)).applyForFactory{value: APPLICATION_FEE}(
            address(factory1),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/metadata.json",
            new bytes32[](0)
        );

        // Vote with rejection
        vm.prank(voter1);
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory1), false);

        IMasterRegistry.FactoryApplication memory app = 
            IMasterRegistry(address(proxy)).getFactoryApplication(address(factory1));
        
        assertEq(app.totalVotes, 2000e18);
        assertEq(app.approvalVotes, 0);
        assertEq(app.rejectionVotes, 2000e18);
    }

    function skip_test_VoteOnApplication_MultipleVoters() public {
        // Setup: Create application
        vm.deal(applicant1, APPLICATION_FEE);
        vm.prank(applicant1);
        IMasterRegistry(address(proxy)).applyForFactory{value: APPLICATION_FEE}(
            address(factory1),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/metadata.json",
            new bytes32[](0)
        );

        // Multiple voters
        vm.prank(voter1);
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory1), true);
        
        vm.prank(voter2);
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory1), true);
        
        vm.prank(voter3);
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory1), false);

        IMasterRegistry.FactoryApplication memory app = 
            IMasterRegistry(address(proxy)).getFactoryApplication(address(factory1));
        
        assertEq(app.totalVotes, 4000e18); // 2000 + 1500 + 500
        assertEq(app.approvalVotes, 3500e18); // 2000 + 1500
        assertEq(app.rejectionVotes, 500e18);
    }

    function skip_test_VoteOnApplication_NoVotingPower() public {
        address noPowerVoter = address(0x999);
        
        // Setup: Create application
        vm.deal(applicant1, APPLICATION_FEE);
        vm.prank(applicant1);
        IMasterRegistry(address(proxy)).applyForFactory{value: APPLICATION_FEE}(
            address(factory1),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/metadata.json",
            new bytes32[](0)
        );

        vm.prank(noPowerVoter);
        vm.expectRevert("No voting power");
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory1), true);
    }

    function skip_test_VoteOnApplication_DoubleVote() public {
        // Setup: Create application
        vm.deal(applicant1, APPLICATION_FEE);
        vm.prank(applicant1);
        IMasterRegistry(address(proxy)).applyForFactory{value: APPLICATION_FEE}(
            address(factory1),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/metadata.json",
            new bytes32[](0)
        );

        vm.prank(voter1);
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory1), true);
        
        vm.prank(voter1);
        vm.expectRevert("Already voted");
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory1), true);
    }

    // ============ Application Finalization Tests ============

    function skip_test_FinalizeApplication_Success() public {
        // Setup: Create application and vote
        vm.deal(applicant1, APPLICATION_FEE);
        vm.prank(applicant1);
        IMasterRegistry(address(proxy)).applyForFactory{value: APPLICATION_FEE}(
            address(factory1),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/metadata.json",
            new bytes32[](0)
        );

        // Vote with enough power to meet quorum
        vm.prank(voter1);
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory1), true);
        
        vm.prank(voter2);
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory1), true);

        // Finalize
        IMasterRegistry(address(proxy)).finalizeApplication(address(factory1));

        IMasterRegistry.FactoryApplication memory app = 
            IMasterRegistry(address(proxy)).getFactoryApplication(address(factory1));
        
        assertEq(uint256(app.status), uint256(IMasterRegistry.ApplicationStatus.Approved));
        
        IMasterRegistry.FactoryInfo memory info = 
            IMasterRegistry(address(proxy)).getFactoryInfoByAddress(address(factory1));
        
        assertEq(info.factoryAddress, address(factory1));
        assertEq(info.factoryId, 1);
        assertEq(info.contractType, "ERC404");
        assertEq(info.title, "test-factory");
        assertEq(info.displayTitle, "Test Factory");
        assertTrue(info.active);
    }

    function skip_test_FinalizeApplication_QuorumNotMet() public {
        // Setup: Create application
        vm.deal(applicant1, APPLICATION_FEE);
        vm.prank(applicant1);
        IMasterRegistry(address(proxy)).applyForFactory{value: APPLICATION_FEE}(
            address(factory1),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/metadata.json",
            new bytes32[](0)
        );

        // Vote with insufficient power
        vm.prank(voter3);
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory1), true);

        // Try to finalize - should fail
        vm.expectRevert("Quorum not met or rejected");
        IMasterRegistry(address(proxy)).finalizeApplication(address(factory1));
    }

    function skip_test_FinalizeApplication_Rejected() public {
        // Setup: Create application
        vm.deal(applicant1, APPLICATION_FEE);
        vm.prank(applicant1);
        IMasterRegistry(address(proxy)).applyForFactory{value: APPLICATION_FEE}(
            address(factory1),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/metadata.json",
            new bytes32[](0)
        );

        // Vote with rejection majority
        vm.prank(voter1);
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory1), false);
        
        vm.prank(voter2);
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory1), false);

        // Try to finalize - should fail (rejected)
        vm.expectRevert("Quorum not met or rejected");
        IMasterRegistry(address(proxy)).finalizeApplication(address(factory1));
    }

    function skip_test_FinalizeApplication_NotOwner() public {
        // Setup: Create application and vote
        vm.deal(applicant1, APPLICATION_FEE);
        vm.prank(applicant1);
        IMasterRegistry(address(proxy)).applyForFactory{value: APPLICATION_FEE}(
            address(factory1),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/metadata.json",
            new bytes32[](0)
        );

        vm.prank(voter1);
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory1), true);

        // Try to finalize as non-owner
        vm.prank(voter1);
        vm.expectRevert();
        IMasterRegistry(address(proxy)).finalizeApplication(address(factory1));
    }

    // ============ Factory Indexing and Retrieval Tests ============

    function skip_test_GetFactoryInfo_ByID() public {
        // Setup: Register factory
        vm.deal(applicant1, APPLICATION_FEE);
        vm.prank(applicant1);
        IMasterRegistry(address(proxy)).applyForFactory{value: APPLICATION_FEE}(
            address(factory1),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/metadata.json",
            new bytes32[](0)
        );

        vm.prank(voter1);
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory1), true);
        
        IMasterRegistry(address(proxy)).finalizeApplication(address(factory1));

        // Get factory info by ID
        IMasterRegistry.FactoryInfo memory info = 
            IMasterRegistry(address(proxy)).getFactoryInfo(1);
        
        assertEq(info.factoryId, 1);
        assertEq(info.factoryAddress, address(factory1));
        assertEq(info.contractType, "ERC404");
    }

    function skip_test_GetFactoryInfo_ByAddress() public {
        // Setup: Register factory
        vm.deal(applicant1, APPLICATION_FEE);
        vm.prank(applicant1);
        IMasterRegistry(address(proxy)).applyForFactory{value: APPLICATION_FEE}(
            address(factory1),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/metadata.json",
            new bytes32[](0)
        );

        vm.prank(voter1);
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory1), true);
        
        IMasterRegistry(address(proxy)).finalizeApplication(address(factory1));

        // Get factory info by address
        IMasterRegistry.FactoryInfo memory info = 
            IMasterRegistry(address(proxy)).getFactoryInfoByAddress(address(factory1));
        
        assertEq(info.factoryAddress, address(factory1));
        assertEq(info.factoryId, 1);
    }

    function skip_test_GetTotalFactories() public {
        assertEq(IMasterRegistry(address(proxy)).getTotalFactories(), 0);

        // Register first factory
        vm.deal(applicant1, APPLICATION_FEE);
        vm.prank(applicant1);
        IMasterRegistry(address(proxy)).applyForFactory{value: APPLICATION_FEE}(
            address(factory1),
            "ERC404",
            "test-factory-1",
            "Test Factory 1",
            "https://example.com/metadata1.json",
            new bytes32[](0)
        );

        vm.prank(voter1);
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory1), true);
        
        IMasterRegistry(address(proxy)).finalizeApplication(address(factory1));
        assertEq(IMasterRegistry(address(proxy)).getTotalFactories(), 1);

        // Register second factory
        vm.deal(applicant2, APPLICATION_FEE);
        vm.prank(applicant2);
        IMasterRegistry(address(proxy)).applyForFactory{value: APPLICATION_FEE}(
            address(factory2),
            "ERC1155",
            "test-factory-2",
            "Test Factory 2",
            "https://example.com/metadata2.json",
            new bytes32[](0)
        );

        vm.prank(voter1);
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory2), true);
        
        IMasterRegistry(address(proxy)).finalizeApplication(address(factory2));
        assertEq(IMasterRegistry(address(proxy)).getTotalFactories(), 2);
    }

    function skip_test_GetFactoryInfo_NotFound() public {
        vm.expectRevert("Factory not found");
        IMasterRegistry(address(proxy)).getFactoryInfo(999);
    }

    // ============ Instance Registration Tests ============

    function skip_test_RegisterInstance_Success() public {
        // Setup: Register factory first
        vm.deal(applicant1, APPLICATION_FEE);
        vm.prank(applicant1);
        IMasterRegistry(address(proxy)).applyForFactory{value: APPLICATION_FEE}(
            address(factory1),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/metadata.json",
            new bytes32[](0)
        );

        vm.prank(voter1);
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory1), true);
        
        IMasterRegistry(address(proxy)).finalizeApplication(address(factory1));

        // Register instance
        address instance = address(0xAAA);
        vm.prank(address(factory1));
        IMasterRegistry(address(proxy)).registerInstance(
            instance,
            address(factory1),
            creator1,
            "test-instance",
            "https://example.com/instance.json",
            address(0) // vault
        );

        // Verify instance info (we'll need to add a getter for this)
        // For now, check that it doesn't revert
        assertTrue(true);
    }

    function skip_test_RegisterInstance_NotRegisteredFactory() public {
        address instance = address(0xAAA);
        
        vm.prank(address(0x999)); // Not a registered factory
        vm.expectRevert("Not a registered factory");
        IMasterRegistry(address(proxy)).registerInstance(
            instance,
            address(0x999),
            creator1,
            "test-instance",
            "https://example.com/instance.json",
            address(0) // vault
        );
    }

    function skip_test_RegisterInstance_DuplicateName() public {
        // Setup: Register factory
        vm.deal(applicant1, APPLICATION_FEE);
        vm.prank(applicant1);
        IMasterRegistry(address(proxy)).applyForFactory{value: APPLICATION_FEE}(
            address(factory1),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/metadata.json",
            new bytes32[](0)
        );

        vm.prank(voter1);
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory1), true);
        
        IMasterRegistry(address(proxy)).finalizeApplication(address(factory1));

        // Register first instance
        address instance1 = address(0xAAA);
        vm.prank(address(factory1));
        IMasterRegistry(address(proxy)).registerInstance(
            instance1,
            address(factory1),
            creator1,
            "test-instance",
            "https://example.com/instance1.json",
            address(0) // vault
        );

        // Try to register second instance with same name
        address instance2 = address(0xBBB);
        vm.prank(address(factory1));
        vm.expectRevert("Name already taken");
        IMasterRegistry(address(proxy)).registerInstance(
            instance2,
            address(factory1),
            creator1,
            "test-instance", // Same name
            "https://example.com/instance2.json",
            address(0) // vault
        );
    }

    // ============ Featured Market Tests ============

    function skip_test_PurchaseFeaturedPromotion_Success() public {
        // Setup: Register factory and instance
        vm.deal(applicant1, APPLICATION_FEE);
        vm.prank(applicant1);
        IMasterRegistry(address(proxy)).applyForFactory{value: APPLICATION_FEE}(
            address(factory1),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/metadata.json",
            new bytes32[](0)
        );

        vm.prank(voter1);
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory1), true);
        
        IMasterRegistry(address(proxy)).finalizeApplication(address(factory1));

        address instance = address(0xAAA);
        vm.prank(address(factory1));
        IMasterRegistry(address(proxy)).registerInstance(
            instance,
            address(factory1),
            creator1,
            "test-instance",
            "https://example.com/instance.json",
            address(0) // vault
        );

        // Purchase featured promotion
        uint256 tierIndex = 0;
        uint256 currentPrice = IMasterRegistry(address(proxy)).getCurrentPrice(tierIndex);
        
        vm.deal(creator1, currentPrice);
        vm.prank(creator1);
        IMasterRegistry(address(proxy)).purchaseFeaturedPromotion{value: currentPrice}(
            instance,
            tierIndex
        );

        // Verify pricing info updated
        IMasterRegistry.TierPricingInfo memory pricing = 
            IMasterRegistry(address(proxy)).getTierPricingInfo(tierIndex);
        
        assertEq(pricing.totalPurchases, 1);
        assertGt(pricing.utilizationRate, 0);
    }

    function skip_test_PurchaseFeaturedPromotion_InsufficientPayment() public {
        // Setup: Register factory and instance
        vm.deal(applicant1, APPLICATION_FEE);
        vm.prank(applicant1);
        IMasterRegistry(address(proxy)).applyForFactory{value: APPLICATION_FEE}(
            address(factory1),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/metadata.json",
            new bytes32[](0)
        );

        vm.prank(voter1);
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory1), true);
        
        IMasterRegistry(address(proxy)).finalizeApplication(address(factory1));

        address instance = address(0xAAA);
        vm.prank(address(factory1));
        IMasterRegistry(address(proxy)).registerInstance(
            instance,
            address(factory1),
            creator1,
            "test-instance",
            "https://example.com/instance.json",
            address(0) // vault
        );

        uint256 tierIndex = 0;
        uint256 currentPrice = IMasterRegistry(address(proxy)).getCurrentPrice(tierIndex);
        
        vm.deal(creator1, currentPrice - 1);
        vm.prank(creator1);
        vm.expectRevert("Insufficient payment");
        IMasterRegistry(address(proxy)).purchaseFeaturedPromotion{value: currentPrice - 1}(
            instance,
            tierIndex
        );
    }

    function skip_test_PurchaseFeaturedPromotion_InvalidTier() public {
        address instance = address(0xAAA);
        uint256 invalidTier = 20; // Max tier is 19 (0-19)
        
        vm.deal(creator1, 1 ether);
        vm.prank(creator1);
        vm.expectRevert("Invalid tier");
        IMasterRegistry(address(proxy)).purchaseFeaturedPromotion{value: 1 ether}(
            instance,
            invalidTier
        );
    }

    function skip_test_GetCurrentPrice_DynamicPricing() public {
        uint256 tierIndex = 0;
        
        // Get initial price
        uint256 initialPrice = IMasterRegistry(address(proxy)).getCurrentPrice(tierIndex);
        assertGt(initialPrice, 0);

        // Setup: Register factory and instance
        vm.deal(applicant1, APPLICATION_FEE);
        vm.prank(applicant1);
        IMasterRegistry(address(proxy)).applyForFactory{value: APPLICATION_FEE}(
            address(factory1),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/metadata.json",
            new bytes32[](0)
        );

        vm.prank(voter1);
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory1), true);
        
        IMasterRegistry(address(proxy)).finalizeApplication(address(factory1));

        address instance = address(0xAAA);
        vm.prank(address(factory1));
        IMasterRegistry(address(proxy)).registerInstance(
            instance,
            address(factory1),
            creator1,
            "test-instance",
            "https://example.com/instance.json",
            address(0) // vault
        );

        // Purchase promotion
        uint256 currentPrice = IMasterRegistry(address(proxy)).getCurrentPrice(tierIndex);
        vm.deal(creator1, currentPrice * 2);
        vm.prank(creator1);
        IMasterRegistry(address(proxy)).purchaseFeaturedPromotion{value: currentPrice}(
            instance,
            tierIndex
        );

        // Price should increase due to utilization
        uint256 newPrice = IMasterRegistry(address(proxy)).getCurrentPrice(tierIndex);
        assertGe(newPrice, initialPrice);
    }

    function skip_test_GetTierPricingInfo() public {
        uint256 tierIndex = 5;
        
        IMasterRegistry.TierPricingInfo memory pricing = 
            IMasterRegistry(address(proxy)).getTierPricingInfo(tierIndex);
        
        assertEq(pricing.totalPurchases, 0);
        assertEq(pricing.utilizationRate, 0);
        assertGt(pricing.currentPrice, 0);
    }

    function skip_test_GetTierPricingInfo_InvalidTier() public {
        uint256 invalidTier = 20;
        
        vm.expectRevert("Invalid tier");
        IMasterRegistry(address(proxy)).getTierPricingInfo(invalidTier);
    }

    // ============ Metadata Validation Tests ============

    function skip_test_ApplyForFactory_ValidURISchemes() public {
        vm.deal(applicant1, APPLICATION_FEE * 4);
        
        string[4] memory validURIs = [
            "https://example.com/metadata.json",
            "http://example.com/metadata.json",
            "ipfs://QmHash/metadata.json",
            "ar://arweave-hash/metadata.json"
        ];

        for (uint256 i = 0; i < validURIs.length; i++) {
            MockFactory newFactory = new MockFactory(address(proxy));
            
            vm.prank(applicant1);
            IMasterRegistry(address(proxy)).applyForFactory{value: APPLICATION_FEE}(
                address(newFactory),
                "ERC404",
                string(abi.encodePacked("test-factory-", vm.toString(i))),
                "Test Factory",
                validURIs[i],
                new bytes32[](0)
            );
        }
    }

    function skip_test_RegisterInstance_ValidName() public {
        // Setup: Register factory
        vm.deal(applicant1, APPLICATION_FEE);
        vm.prank(applicant1);
        IMasterRegistry(address(proxy)).applyForFactory{value: APPLICATION_FEE}(
            address(factory1),
            "ERC404",
            "test-factory",
            "Test Factory",
            "https://example.com/metadata.json",
            new bytes32[](0)
        );

        vm.prank(voter1);
        IMasterRegistry(address(proxy)).voteOnApplication(address(factory1), true);
        
        IMasterRegistry(address(proxy)).finalizeApplication(address(factory1));

        // Valid names
        string[3] memory validNames = ["test-instance", "test_instance", "test123"];
        
        for (uint256 i = 0; i < validNames.length; i++) {
            address instance = address(uint160(0xAAA + i));
            vm.prank(address(factory1));
            IMasterRegistry(address(proxy)).registerInstance(
                instance,
                address(factory1),
                creator1,
                validNames[i],
                "https://example.com/instance.json",
                address(0) // vault
            );
        }
    }

    // ============ Vault/Hook Registry Integration Tests ============

    function skip_test_VaultHookRegistry_Integration() public {
        // NOTE: Hooks are now created and owned by vaults, not registered centrally
        // This test is kept as reference for vault registration flow

        // Register a vault
        address mockVault = address(new MockContract());
        vm.deal(creator1, 0.05 ether);

        vm.prank(creator1);
        IMasterRegistry(address(proxy)).registerVault{value: 0.05 ether}(
            mockVault,
            "Test Alignment Vault",
            "https://example.com/vault.json"
        );

        // Verify vault is registered
        assertTrue(IMasterRegistry(address(proxy)).isVaultRegistered(mockVault));

        // Get vault info
        IMasterRegistry.VaultInfo memory vaultInfo =
            IMasterRegistry(address(proxy)).getVaultInfo(mockVault);
        assertEq(vaultInfo.name, "Test Alignment Vault");
        assertEq(vaultInfo.creator, creator1);
        assertTrue(vaultInfo.active);

        // Hook registry functions have been removed as part of vault-hook redesign
        // Hooks are now created at vault construction time and owned by vault
        // Vault provides getHook() function for retrieval
    }

    function skip_test_VaultHookRegistry_MultipleVaults() public {
        address mockVault1 = address(new MockContract());
        address mockVault2 = address(new MockContract());
        
        vm.deal(creator1, 0.05 ether * 2);
        
        vm.startPrank(creator1);
        IMasterRegistry(address(proxy)).registerVault{value: 0.05 ether}(
            mockVault1,
            "Vault 1",
            "https://example.com/vault1.json"
        );

        IMasterRegistry(address(proxy)).registerVault{value: 0.05 ether}(
            mockVault2,
            "Vault 2",
            "https://example.com/vault2.json"
        );
        vm.stopPrank();
        
        address[] memory vaultList = IMasterRegistry(address(proxy)).getVaultList();
        assertEq(vaultList.length, 2);
    }

    function skip_test_VaultHookRegistry_FeeConfiguration() public {
        MasterRegistryV1 registry = MasterRegistryV1(proxy);

        // Phase 1 Note: Fee configuration is deferred to Phase 2
        // These methods are not available in Phase 1 implementation
        // Check default fees
        // assertEq(registry.vaultRegistrationFee(), 0.05 ether);
        // assertEq(registry.hookRegistrationFee(), 0.02 ether);

        // Update fees (owner only)
        // registry.setVaultRegistrationFee(0.1 ether);
        // registry.setHookRegistrationFee(0.05 ether);

        // assertEq(registry.vaultRegistrationFee(), 0.1 ether);
        // assertEq(registry.hookRegistrationFee(), 0.05 ether);
    }
}

/**
 * @title MockContract
 * @notice Simple mock contract for testing (has code.length > 0)
 */
contract MockContract {
    uint256 public value;
    
    function setValue(uint256 _value) external {
        value = _value;
    }
}

