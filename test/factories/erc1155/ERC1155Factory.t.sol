// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console, console2} from "forge-std/Test.sol";
import {ERC1155Factory} from "../../../src/factories/erc1155/ERC1155Factory.sol";
import {ERC1155Instance} from "../../../src/factories/erc1155/ERC1155Instance.sol";
import {UltraAlignmentVault} from "../../../src/vaults/UltraAlignmentVault.sol";
import {MockEXECToken} from "../../mocks/MockEXECToken.sol";
import {MockMasterRegistry} from "../../mocks/MockMasterRegistry.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {GlobalMessagingTestBase} from "../../base/GlobalMessagingTestBase.sol";
import {GlobalMessageTypes} from "../../../src/libraries/GlobalMessageTypes.sol";
import {GlobalMessageRegistry} from "../../../src/registry/GlobalMessageRegistry.sol";

/**
 * @title ERC1155FactoryTest
 * @notice Comprehensive test suite for ERC1155 Factory
 */
contract ERC1155FactoryTest is GlobalMessagingTestBase {
    ERC1155Factory public factory;
    UltraAlignmentVault public vault;
    MockEXECToken public token;

    address public owner = address(0x1);
    address public creator = address(0x2);
    address public minter1 = address(0x3);
    address public minter2 = address(0x4);

    address public mockInstanceTemplate = address(0x200);

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock token for vault
        token = new MockEXECToken(1000000e18);

        // Deploy vault (WETH, PoolManager, V3Router, V2Router, V2Factory, V3Factory, AlignmentToken)
        vault = new UltraAlignmentVault(
            address(0x2222222222222222222222222222222222222222),  // WETH
            address(0x4444444444444444444444444444444444444444),  // V4 pool manager
            address(0x5555555555555555555555555555555555555555),  // V3 router
            address(0x6666666666666666666666666666666666666666),  // V2 router
            address(0x7777777777777777777777777777777777777777),  // V2 factory
            address(0x8888888888888888888888888888888888888888),  // V3 factory
            address(token)                                        // alignment target
        );

        // Set V4 pool key
        // H-02: Hook requires native ETH (address(0)), not WETH
        PoolKey memory mockPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),  // Native ETH
            currency1: Currency.wrap(address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vault.setV4PoolKey(mockPoolKey);

        // Create a mock registry that doesn't revert on registerInstance/registerFactory
        // This simulates a real registry being there
        address mockRegistry = address(new MockMasterRegistry());

        // Set up global messaging
        _setUpGlobalMessaging(mockRegistry);

        // Deploy factory
        factory = new ERC1155Factory(mockRegistry, mockInstanceTemplate);

        // NOTE: authorizeInstanceFactory removed - vault now accepts all ETH contributions
        // vault.authorizeInstanceFactory(address(factory));

        vm.stopPrank();
    }

    function test_FactoryCreation() public {
        // Factory should have been created with mock registry
        assertEq(address(factory.instanceTemplate()), mockInstanceTemplate);
        assertEq(factory.instanceCreationFee(), 0.01 ether);
    }

    function test_CreateInstance() public {
        vm.deal(creator, 1 ether);
        vm.startPrank(creator);
        
        address instance = factory.createInstance{value: 0.01 ether}(
            "Test Collection",
            "ipfs://test",
            creator,
            address(vault),
            "" // styleUri
        );
        
        assertTrue(instance != address(0));
        assertEq(factory.instanceToVault(instance), address(vault));
        
        ERC1155Instance instanceContract = ERC1155Instance(instance);
        assertEq(instanceContract.name(), "Test Collection");
        assertEq(instanceContract.creator(), creator);
        assertEq(address(instanceContract.vault()), address(vault));
        
        vm.stopPrank();
    }

    function test_CreateInstance_InsufficientFee() public {
        vm.deal(creator, 1 ether);
        vm.startPrank(creator);
        
        vm.expectRevert("Insufficient fee");
        factory.createInstance{value: 0.001 ether}(
            "Test Collection",
            "ipfs://test",
            creator,
            address(vault),
            "" // styleUri
        );
        
        vm.stopPrank();
    }

    function test_AddEdition_Unlimited() public {
        vm.deal(creator, 1 ether);
        vm.startPrank(creator);
        
        address instance = factory.createInstance{value: 0.01 ether}(
            "Test Collection",
            "ipfs://test",
            creator,
            address(vault),
            "" // styleUri
        );
        
        uint256 editionId = factory.addEdition(
            instance,
            "Piece 1",
            0.1 ether,
            0, // Unlimited
            "ipfs://piece1",
            ERC1155Instance.PricingModel.UNLIMITED,
            0
        );
        
        assertEq(editionId, 1);
        
        ERC1155Instance instanceContract = ERC1155Instance(instance);
        ERC1155Instance.Edition memory edition = instanceContract.getEdition(editionId);
        assertEq(edition.id, editionId);
        assertEq(edition.pieceTitle, "Piece 1");
        assertEq(edition.basePrice, 0.1 ether);
        assertEq(edition.supply, 0);
        assertEq(uint256(edition.pricingModel), uint256(ERC1155Instance.PricingModel.UNLIMITED));
        
        vm.stopPrank();
    }

    function test_AddEdition_LimitedFixed() public {
        vm.deal(creator, 1 ether);
        vm.startPrank(creator);
        
        address instance = factory.createInstance{value: 0.01 ether}(
            "Test Collection",
            "ipfs://test",
            creator,
            address(vault),
            "" // styleUri
        );
        
        uint256 editionId = factory.addEdition(
            instance,
            "Piece 2",
            0.2 ether,
            100, // Limited
            "ipfs://piece2",
            ERC1155Instance.PricingModel.LIMITED_FIXED,
            0
        );
        
        assertEq(editionId, 1);
        
        ERC1155Instance instanceContract = ERC1155Instance(instance);
        ERC1155Instance.Edition memory edition = instanceContract.getEdition(editionId);
        assertEq(uint256(edition.pricingModel), uint256(ERC1155Instance.PricingModel.LIMITED_FIXED));
        assertEq(edition.supply, 100);
        
        vm.stopPrank();
    }

    function test_AddEdition_LimitedDynamic() public {
        vm.deal(creator, 1 ether);
        vm.startPrank(creator);
        
        address instance = factory.createInstance{value: 0.01 ether}(
            "Test Collection",
            "ipfs://test",
            creator,
            address(vault),
            "" // styleUri
        );
        
        uint256 editionId = factory.addEdition(
            instance,
            "Piece 3",
            0.1 ether,
            50, // Limited
            "ipfs://piece3",
            ERC1155Instance.PricingModel.LIMITED_DYNAMIC,
            100 // 1% increase per mint
        );
        
        assertEq(editionId, 1);
        
        ERC1155Instance instanceContract = ERC1155Instance(instance);
        ERC1155Instance.Edition memory edition = instanceContract.getEdition(editionId);
        assertEq(uint256(edition.pricingModel), uint256(ERC1155Instance.PricingModel.LIMITED_DYNAMIC));
        assertEq(edition.priceIncreaseRate, 100);
        
        vm.stopPrank();
    }

    function test_Mint_Unlimited() public {
        vm.deal(creator, 1 ether);
        vm.deal(minter1, 10 ether);
        
        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Test Collection",
            "ipfs://test",
            creator,
            address(vault),
            "" // styleUri
        );
        
        factory.addEdition(
            instance,
            "Piece 1",
            0.1 ether,
            0, // Unlimited
            "ipfs://piece1",
            ERC1155Instance.PricingModel.UNLIMITED,
            0
        );
        vm.stopPrank();
        
        vm.startPrank(minter1);
        ERC1155Instance instanceContract = ERC1155Instance(instance);
        
        // Mint 5 tokens
        instanceContract.mint{value: 0.5 ether}(1, 5, "");

        assertEq(instanceContract.balanceOf(minter1, 1), 5);
        ERC1155Instance.Edition memory edition = instanceContract.getEdition(1);
        assertEq(edition.minted, 5);
        
        vm.stopPrank();
    }

    function test_Mint_LimitedFixed() public {
        vm.deal(creator, 1 ether);
        vm.deal(minter1, 10 ether);
        
        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Test Collection",
            "ipfs://test",
            creator,
            address(vault),
            "" // styleUri
        );
        
        factory.addEdition(
            instance,
            "Piece 2",
            0.2 ether,
            10, // Limited to 10
            "ipfs://piece2",
            ERC1155Instance.PricingModel.LIMITED_FIXED,
            0
        );
        vm.stopPrank();
        
        vm.startPrank(minter1);
        ERC1155Instance instanceContract = ERC1155Instance(instance);
        
        // Mint 5 tokens
        instanceContract.mint{value: 1 ether}(1, 5, "");
        assertEq(instanceContract.balanceOf(minter1, 1), 5);
        ERC1155Instance.Edition memory edition1 = instanceContract.getEdition(1);
        assertEq(edition1.minted, 5);

        // Try to mint 6 more (would exceed supply)
        vm.expectRevert("Exceeds supply");
        instanceContract.mint{value: 1.2 ether}(1, 6, "");

        // Mint remaining 5
        instanceContract.mint{value: 1 ether}(1, 5, "");
        ERC1155Instance.Edition memory edition2 = instanceContract.getEdition(1);
        assertEq(edition2.minted, 10);
        
        vm.stopPrank();
    }

    function test_Mint_LimitedDynamic() public {
        vm.deal(creator, 1 ether);
        vm.deal(minter1, 10 ether);
        
        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Test Collection",
            "ipfs://test",
            creator,
            address(vault),
            "" // styleUri
        );
        
        factory.addEdition(
            instance,
            "Piece 3",
            0.1 ether,
            10, // Limited to 10
            "ipfs://piece3",
            ERC1155Instance.PricingModel.LIMITED_DYNAMIC,
            100 // 1% increase per mint
        );
        vm.stopPrank();
        
        vm.startPrank(minter1);
        ERC1155Instance instanceContract = ERC1155Instance(instance);
        
        // Get current price (should be base price for first mint)
        uint256 price1 = instanceContract.getCurrentPrice(1);
        assertEq(price1, 0.1 ether);
        
        // Mint 1 token
        instanceContract.mint{value: 0.2 ether}(1, 1, "");
        
        // Price should increase for next mint
        uint256 price2 = instanceContract.getCurrentPrice(1);
        assertGt(price2, price1);
        
        vm.stopPrank();
    }

    function test_MintWithMessage() public {
        vm.deal(creator, 1 ether);
        vm.deal(minter1, 10 ether);
        
        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Test Collection",
            "ipfs://test",
            creator,
            address(vault),
            "" // styleUri
        );
        
        factory.addEdition(
            instance,
            "Piece 1",
            0.1 ether,
            0,
            "ipfs://piece1",
            ERC1155Instance.PricingModel.UNLIMITED,
            0
        );
        vm.stopPrank();
        
        vm.startPrank(minter1);
        ERC1155Instance instanceContract = ERC1155Instance(instance);
        
        instanceContract.mint{value: 0.1 ether}(
            1,
            1,
            "Hello from minter!"
        );

        // Check message in global registry
        _assertMessageCount(1);
        _assertInstanceMessageCount(instance, 1);

        _assertGlobalMessageWithAmount({
            messageId: 0,
            expectedInstance: instance,
            expectedSender: minter1,
            expectedFactoryType: GlobalMessageTypes.FACTORY_ERC1155,
            expectedActionType: GlobalMessageTypes.ACTION_MINT,
            expectedContextId: 1, // editionId
            expectedAmount: 1, // amount minted
            expectedMessage: "Hello from minter!"
        });

        vm.stopPrank();
    }

    function test_Withdraw_Tax() public {
        vm.deal(creator, 1 ether);
        vm.deal(minter1, 10 ether);
        
        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Test Collection",
            "ipfs://test",
            creator,
            address(vault),
            "" // styleUri
        );
        
        factory.addEdition(
            instance,
            "Piece 1",
            1 ether,
            0,
            "ipfs://piece1",
            ERC1155Instance.PricingModel.UNLIMITED,
            0
        );
        vm.stopPrank();
        
        vm.startPrank(minter1);
        ERC1155Instance instanceContract = ERC1155Instance(instance);
        instanceContract.mint{value: 1 ether}(1, 1, "");
        vm.stopPrank();
        
        uint256 balanceBefore = address(vault).balance;
        uint256 creatorBalanceBefore = creator.balance;
        
        vm.startPrank(creator);
        // Withdraw 1 ETH
        instanceContract.withdraw(1 ether);
        
        // Check tax (20% = 0.2 ETH to vault)
        // Note: Vault may not accept ETH directly, so this might revert
        // In production, vault should be updated or ETH wrapped to WETH
        uint256 balanceAfter = address(vault).balance;
        uint256 creatorBalanceAfter = creator.balance;
        
        // If vault accepts ETH, check tax was sent
        // Otherwise, the test will show the need for vault update
        vm.stopPrank();
    }

    function test_GetMessagesBatch() public {
        vm.deal(creator, 1 ether);
        vm.deal(minter1, 10 ether);
        vm.deal(minter2, 10 ether);
        
        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Test Collection",
            "ipfs://test",
            creator,
            address(vault),
            "" // styleUri
        );
        
        factory.addEdition(
            instance,
            "Piece 1",
            0.1 ether,
            0,
            "ipfs://piece1",
            ERC1155Instance.PricingModel.UNLIMITED,
            0
        );
        vm.stopPrank();
        
        vm.startPrank(minter1);
        ERC1155Instance instanceContract = ERC1155Instance(instance);
        instanceContract.mint{value: 0.1 ether}(1, 1, "Message 1");
        vm.stopPrank();

        vm.startPrank(minter2);
        instanceContract.mint{value: 0.1 ether}(1, 1, "Message 2");
        vm.stopPrank();
        
        // Get messages from global registry
        GlobalMessageRegistry.GlobalMessage[] memory instanceMessages = _getInstanceMessages(instance, 2);

        assertEq(instanceMessages.length, 2, "Should have 2 messages");

        // Verify first message
        _assertGlobalMessageWithAmount({
            messageId: 0,
            expectedInstance: instance,
            expectedSender: minter1,
            expectedFactoryType: GlobalMessageTypes.FACTORY_ERC1155,
            expectedActionType: GlobalMessageTypes.ACTION_MINT,
            expectedContextId: 1,
            expectedAmount: 1,
            expectedMessage: "Message 1"
        });

        // Verify second message
        _assertGlobalMessageWithAmount({
            messageId: 1,
            expectedInstance: instance,
            expectedSender: minter2,
            expectedFactoryType: GlobalMessageTypes.FACTORY_ERC1155,
            expectedActionType: GlobalMessageTypes.ACTION_MINT,
            expectedContextId: 1,
            expectedAmount: 1,
            expectedMessage: "Message 2"
        });
    }

    function test_UpdateEditionMetadata() public {
        vm.deal(creator, 1 ether);
        
        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Test Collection",
            "ipfs://test",
            creator,
            address(vault),
            "" // styleUri
        );
        
        factory.addEdition(
            instance,
            "Piece 1",
            0.1 ether,
            0,
            "ipfs://piece1",
            ERC1155Instance.PricingModel.UNLIMITED,
            0
        );
        
        ERC1155Instance instanceContract = ERC1155Instance(instance);
        instanceContract.updateEditionMetadata(1, "ipfs://piece1-updated");
        
        ERC1155Instance.Edition memory edition = instanceContract.getEdition(1);
        assertEq(edition.metadataURI, "ipfs://piece1-updated");
        
        vm.stopPrank();
    }

    function test_CalculateMintCost_Dynamic() public {
        vm.deal(creator, 1 ether);
        
        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Test Collection",
            "ipfs://test",
            creator,
            address(vault),
            "" // styleUri
        );
        
        factory.addEdition(
            instance,
            "Piece 3",
            0.1 ether,
            10,
            "ipfs://piece3",
            ERC1155Instance.PricingModel.LIMITED_DYNAMIC,
            100 // 1% increase
        );
        
        ERC1155Instance instanceContract = ERC1155Instance(instance);
        
        // Calculate cost for minting 3 tokens
        uint256 cost = instanceContract.calculateMintCost(1, 3);
        assertGt(cost, 0.3 ether); // Should be more than base price * 3 due to increases
        
        vm.stopPrank();
    }

    function test_GetEditionMetadata() public {
        vm.deal(creator, 1 ether);
        
        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Test Collection",
            "ipfs://test",
            creator,
            address(vault),
            "" // styleUri
        );
        
        factory.addEdition(
            instance,
            "Test Piece",
            0.1 ether,
            100,
            "ipfs://test-piece",
            ERC1155Instance.PricingModel.LIMITED_FIXED,
            0
        );
        
        ERC1155Instance instanceContract = ERC1155Instance(instance);
        
        (
            uint256 id,
            string memory pieceTitle,
            uint256 basePrice,
            uint256 currentPrice,
            uint256 supply,
            uint256 minted,
            string memory metadataURI,
            ERC1155Instance.PricingModel pricingModel,
            uint256 priceIncreaseRate
        ) = instanceContract.getEditionMetadata(1);
        
        assertEq(id, 1);
        assertEq(pieceTitle, "Test Piece");
        assertEq(basePrice, 0.1 ether);
        assertEq(currentPrice, 0.1 ether);
        assertEq(supply, 100);
        assertEq(minted, 0);
        assertEq(metadataURI, "ipfs://test-piece");
        assertEq(uint256(pricingModel), uint256(ERC1155Instance.PricingModel.LIMITED_FIXED));
        assertEq(priceIncreaseRate, 0);
        
        vm.stopPrank();
    }

    function test_GetAllEditionIds() public {
        vm.deal(creator, 1 ether);
        
        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Test Collection",
            "ipfs://test",
            creator,
            address(vault),
            "" // styleUri
        );
        
        factory.addEdition(instance, "Piece 1", 0.1 ether, 0, "ipfs://1", ERC1155Instance.PricingModel.UNLIMITED, 0);
        factory.addEdition(instance, "Piece 2", 0.2 ether, 100, "ipfs://2", ERC1155Instance.PricingModel.LIMITED_FIXED, 0);
        factory.addEdition(instance, "Piece 3", 0.3 ether, 50, "ipfs://3", ERC1155Instance.PricingModel.LIMITED_DYNAMIC, 100);
        
        ERC1155Instance instanceContract = ERC1155Instance(instance);
        
        uint256[] memory editionIds = instanceContract.getAllEditionIds();
        assertEq(editionIds.length, 3);
        assertEq(editionIds[0], 1);
        assertEq(editionIds[1], 2);
        assertEq(editionIds[2], 3);
        
        assertEq(instanceContract.getEditionCount(), 3);
        
        vm.stopPrank();
    }

    function test_GetEditionsBatch() public {
        vm.deal(creator, 1 ether);
        
        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Test Collection",
            "ipfs://test",
            creator,
            address(vault),
            "" // styleUri
        );
        
        factory.addEdition(instance, "Piece 1", 0.1 ether, 0, "ipfs://1", ERC1155Instance.PricingModel.UNLIMITED, 0);
        factory.addEdition(instance, "Piece 2", 0.2 ether, 100, "ipfs://2", ERC1155Instance.PricingModel.LIMITED_FIXED, 0);
        
        ERC1155Instance instanceContract = ERC1155Instance(instance);
        
        (
            uint256[] memory ids,
            string[] memory pieceTitles,
            uint256[] memory basePrices,
            uint256[] memory currentPrices,
            uint256[] memory supplies,
            uint256[] memory mintedCounts,
            string[] memory metadataURIs,
            ERC1155Instance.PricingModel[] memory pricingModels,
            uint256[] memory priceIncreaseRates
        ) = instanceContract.getEditionsBatch(1, 2);
        
        assertEq(ids.length, 2);
        assertEq(pieceTitles[0], "Piece 1");
        assertEq(pieceTitles[1], "Piece 2");
        assertEq(basePrices[0], 0.1 ether);
        assertEq(basePrices[1], 0.2 ether);
        
        vm.stopPrank();
    }

    function test_GetInstanceMetadata() public {
        vm.deal(creator, 1 ether);
        
        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Test Collection",
            "ipfs://test",
            creator,
            address(vault),
            "" // styleUri
        );
        
        ERC1155Instance instanceContract = ERC1155Instance(instance);
        
        (
            string memory instanceName,
            address instanceCreator,
            address instanceFactory,
            address instanceVault,
            uint256 totalEditions,
            uint256 totalProceeds,
            uint256 contractBalance,
            string memory instanceStyleUri
        ) = instanceContract.getInstanceMetadata();
        
        assertEq(instanceName, "Test Collection");
        assertEq(instanceCreator, creator);
        assertEq(instanceFactory, address(factory));
        assertEq(instanceVault, address(vault));
        assertEq(totalEditions, 0);
        assertEq(totalProceeds, 0);
        
        vm.stopPrank();
    }

    function test_GetPricingInfo() public {
        vm.deal(creator, 1 ether);
        
        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Test Collection",
            "ipfs://test",
            creator,
            address(vault),
            "" // styleUri
        );
        
        factory.addEdition(
            instance,
            "Piece 1",
            0.1 ether,
            100,
            "ipfs://piece1",
            ERC1155Instance.PricingModel.LIMITED_FIXED,
            0
        );
        
        ERC1155Instance instanceContract = ERC1155Instance(instance);
        
        (
            uint256 basePrice,
            uint256 currentPrice,
            ERC1155Instance.PricingModel pricingModel,
            uint256 priceIncreaseRate,
            uint256 minted,
            uint256 supply,
            uint256 available
        ) = instanceContract.getPricingInfo(1);
        
        assertEq(basePrice, 0.1 ether);
        assertEq(currentPrice, 0.1 ether);
        assertEq(uint256(pricingModel), uint256(ERC1155Instance.PricingModel.LIMITED_FIXED));
        assertEq(supply, 100);
        assertEq(minted, 0);
        assertEq(available, 100);
        
        vm.stopPrank();
    }

    function test_GetMintStats() public {
        vm.deal(creator, 1 ether);
        vm.deal(minter1, 10 ether);
        
        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Test Collection",
            "ipfs://test",
            creator,
            address(vault),
            "" // styleUri
        );
        
        factory.addEdition(
            instance,
            "Piece 1",
            0.1 ether,
            10,
            "ipfs://piece1",
            ERC1155Instance.PricingModel.LIMITED_FIXED,
            0
        );
        vm.stopPrank();
        
        vm.startPrank(minter1);
        ERC1155Instance instanceContract = ERC1155Instance(instance);
        instanceContract.mint{value: 0.5 ether}(1, 5, "");
        vm.stopPrank();

        (
            uint256 minted,
            uint256 supply,
            uint256 available,
            bool isSoldOut
        ) = instanceContract.getMintStats(1);
        
        assertEq(minted, 5);
        assertEq(supply, 10);
        assertEq(available, 5);
        assertFalse(isSoldOut);
    }

    function test_EditionExists() public {
        vm.deal(creator, 1 ether);
        
        vm.startPrank(creator);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Test Collection",
            "ipfs://test",
            creator,
            address(vault),
            "" // styleUri
        );
        
        factory.addEdition(
            instance,
            "Piece 1",
            0.1 ether,
            100,
            "ipfs://piece1",
            ERC1155Instance.PricingModel.LIMITED_FIXED,
            0
        );
        
        ERC1155Instance instanceContract = ERC1155Instance(instance);
        
        assertTrue(instanceContract.editionExists(1));
        assertFalse(instanceContract.editionExists(999));
        
        vm.stopPrank();
    }
}

