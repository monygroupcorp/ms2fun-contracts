// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC721AuctionFactory} from "../../../src/factories/erc721/ERC721AuctionFactory.sol";
import {ERC721AuctionInstance} from "../../../src/factories/erc721/ERC721AuctionInstance.sol";
import {UniAlignmentVault} from "../../../src/vaults/uni/UniAlignmentVault.sol";
import {MockEXECToken} from "../../mocks/MockEXECToken.sol";
import {MockMasterRegistry} from "../../mocks/MockMasterRegistry.sol";
import {MockZRouter} from "../../mocks/MockZRouter.sol";
import {MockVaultPriceValidator} from "../../mocks/MockVaultPriceValidator.sol";
import {IVaultPriceValidator} from "../../../src/interfaces/IVaultPriceValidator.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {GlobalMessagingTestBase} from "../../base/GlobalMessagingTestBase.sol";
import {MockAlignmentRegistry} from "../../mocks/MockAlignmentRegistry.sol";
import {IAlignmentRegistry} from "../../../src/master/interfaces/IAlignmentRegistry.sol";

contract ERC721AgentDelegationTest is GlobalMessagingTestBase {
    ERC721AuctionFactory public factory;
    UniAlignmentVault public vault;
    MockMasterRegistry public mockRegistry;
    MockEXECToken public token;
    MockAlignmentRegistry public mockAlignmentRegistry;

    uint256 constant TARGET_ID = 1;
    address public owner = address(0x1);
    address public artist = address(0x5);
    address public agent = address(0x10);
    address public nobody = address(0x99);

    function setUp() public {
        vm.startPrank(owner);

        token = new MockEXECToken(1000000e18);
        mockAlignmentRegistry = new MockAlignmentRegistry();
        mockAlignmentRegistry.setTargetActive(TARGET_ID, true);
        mockAlignmentRegistry.setTokenInTarget(TARGET_ID, address(token), true);

        {
            UniAlignmentVault _impl = new UniAlignmentVault();
            vault = UniAlignmentVault(payable(LibClone.clone(address(_impl))));
            vault.initialize(
                address(0x2222222222222222222222222222222222222222),
                address(0x4444444444444444444444444444444444444444),
                address(token),
                address(new MockZRouter()),
                3000, 60,
                IVaultPriceValidator(address(new MockVaultPriceValidator())),
                IAlignmentRegistry(address(mockAlignmentRegistry)),
                TARGET_ID
            );
        }

        PoolKey memory mockPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))
        });
        vault.setV4PoolKey(mockPoolKey);

        mockRegistry = new MockMasterRegistry();
        _setUpGlobalMessaging(address(mockRegistry));

        factory = new ERC721AuctionFactory(address(mockRegistry), address(globalRegistry));
        factory.setProtocolTreasury(owner);

        mockRegistry.setAgent(agent, true);

        vm.stopPrank();
    }

    // ── Agent creates instance on behalf ──

    function test_agent_creates_instance_on_behalf() public {
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Agent Auction",
            "ipfs://test",
            artist,
            address(vault),
            "AART",
            1,           // lines
            1 days,      // baseDuration
            15 minutes,  // timeBuffer
            0.01 ether   // bidIncrement
        );

        ERC721AuctionInstance inst = ERC721AuctionInstance(payable(instance));
        assertEq(inst.owner(), artist);
        assertTrue(inst.agentDelegationEnabled());
    }

    function test_self_created_delegation_disabled() public {
        vm.deal(artist, 1 ether);
        vm.prank(artist);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Self Auction",
            "ipfs://test",
            artist,
            address(vault),
            "SELF",
            1, 1 days, 15 minutes, 0.01 ether
        );

        assertFalse(ERC721AuctionInstance(payable(instance)).agentDelegationEnabled());
    }

    function test_non_agent_cannot_create_on_behalf() public {
        vm.deal(nobody, 1 ether);
        vm.prank(nobody);
        vm.expectRevert();
        factory.createInstance{value: 0.01 ether}(
            "Should Fail",
            "ipfs://test",
            artist,
            address(vault),
            "FAIL",
            1, 1 days, 15 minutes, 0.01 ether
        );
    }

    // ── Agent queues piece via factory ──

    function test_agent_queues_piece_via_factory() public {
        vm.deal(agent, 2 ether);
        vm.prank(agent);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Queue Test",
            "ipfs://test",
            artist,
            address(vault),
            "QT",
            1, 1 days, 15 minutes, 0.01 ether
        );

        vm.prank(agent);
        factory.queuePiece{value: 0.1 ether}(instance, "ipfs://piece1");

        assertEq(ERC721AuctionInstance(payable(instance)).nextTokenId(), 2);
    }

    function test_agent_blocked_when_delegation_disabled() public {
        vm.deal(agent, 2 ether);
        vm.prank(agent);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Toggle Test",
            "ipfs://test",
            artist,
            address(vault),
            "TOG",
            1, 1 days, 15 minutes, 0.01 ether
        );

        vm.prank(artist);
        ERC721AuctionInstance(payable(instance)).setAgentDelegation(false);

        vm.prank(agent);
        vm.expectRevert();
        factory.queuePiece{value: 0.1 ether}(instance, "ipfs://piece2");
    }

    function test_agent_blocked_after_global_revocation() public {
        vm.deal(agent, 2 ether);
        vm.prank(agent);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Revoke Test",
            "ipfs://test",
            artist,
            address(vault),
            "REV",
            1, 1 days, 15 minutes, 0.01 ether
        );

        mockRegistry.setAgent(agent, false);

        vm.prank(agent);
        vm.expectRevert();
        factory.queuePiece{value: 0.1 ether}(instance, "ipfs://piece2");
    }

    // ── Artist direct access always works ──

    function test_artist_queues_piece_directly() public {
        vm.deal(artist, 1 ether);
        vm.prank(artist);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Direct Test",
            "ipfs://test",
            artist,
            address(vault),
            "DIR",
            1, 1 days, 15 minutes, 0.01 ether
        );

        vm.prank(artist);
        ERC721AuctionInstance(payable(instance)).queuePiece{value: 0.05 ether}("ipfs://direct");
        assertEq(ERC721AuctionInstance(payable(instance)).nextTokenId(), 2);
    }

    function test_only_owner_can_set_delegation() public {
        vm.deal(artist, 1 ether);
        vm.prank(artist);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Auth Test",
            "ipfs://test",
            artist,
            address(vault),
            "AUTH",
            1, 1 days, 15 minutes, 0.01 ether
        );

        vm.prank(nobody);
        vm.expectRevert();
        ERC721AuctionInstance(payable(instance)).setAgentDelegation(true);
    }
}
