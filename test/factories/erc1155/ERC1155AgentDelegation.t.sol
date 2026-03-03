// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1155Factory} from "../../../src/factories/erc1155/ERC1155Factory.sol";
import {ERC1155Instance} from "../../../src/factories/erc1155/ERC1155Instance.sol";
import {UniAlignmentVault} from "../../../src/vaults/uni/UniAlignmentVault.sol";
import {MockEXECToken} from "../../mocks/MockEXECToken.sol";
import {MockMasterRegistry} from "../../mocks/MockMasterRegistry.sol";
import {MockZRouter} from "../../mocks/MockZRouter.sol";
import {MockVaultPriceValidator} from "../../mocks/MockVaultPriceValidator.sol";
import {IVaultPriceValidator} from "../../../src/interfaces/IVaultPriceValidator.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {ComponentRegistry} from "../../../src/registry/ComponentRegistry.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {GlobalMessagingTestBase} from "../../base/GlobalMessagingTestBase.sol";
import {MockAlignmentRegistry} from "../../mocks/MockAlignmentRegistry.sol";
import {IAlignmentRegistry} from "../../../src/master/interfaces/IAlignmentRegistry.sol";

contract ERC1155AgentDelegationTest is GlobalMessagingTestBase {
    ERC1155Factory public factory;
    UniAlignmentVault public vault;
    MockMasterRegistry public mockRegistry;
    MockEXECToken public token;
    ComponentRegistry public componentRegistry;
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

        ComponentRegistry compRegImpl = new ComponentRegistry();
        address compRegProxy = LibClone.deployERC1967(address(compRegImpl));
        componentRegistry = ComponentRegistry(compRegProxy);
        componentRegistry.initialize(owner);

        factory = new ERC1155Factory(address(mockRegistry), address(0x200), address(globalRegistry), address(componentRegistry));

        // Register agent globally (on mock registry)
        mockRegistry.setAgent(agent, true);

        vm.stopPrank();
    }

    // ── Agent creates instance on behalf of artist ──

    function test_agent_creates_instance_on_behalf() public {
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Agent Created",
            "ipfs://test",
            artist,        // creator is artist, not agent
            address(vault),
            ""
        );

        ERC1155Instance inst = ERC1155Instance(instance);
        assertEq(inst.owner(), artist);
        assertTrue(inst.agentDelegationEnabled());
    }

    function test_self_created_instance_delegation_disabled() public {
        vm.deal(artist, 1 ether);
        vm.prank(artist);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Self Created",
            "ipfs://test",
            artist,
            address(vault),
            ""
        );

        ERC1155Instance inst = ERC1155Instance(instance);
        assertFalse(inst.agentDelegationEnabled());
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
            ""
        );
    }

    // ── Agent adds edition via factory ──

    function test_agent_adds_edition_via_factory() public {
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Agent Collection",
            "ipfs://test",
            artist,
            address(vault),
            ""
        );

        vm.prank(agent);
        uint256 editionId = factory.addEdition(
            instance,
            "Piece 1",
            0.1 ether,
            0,
            "ipfs://piece1",
            ERC1155Instance.PricingModel.UNLIMITED,
            0,
            0
        );

        assertEq(editionId, 1);
    }

    function test_agent_blocked_when_delegation_disabled() public {
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Toggle Test",
            "ipfs://test",
            artist,
            address(vault),
            ""
        );

        // Artist disables delegation
        vm.prank(artist);
        ERC1155Instance(instance).setAgentDelegation(false);

        // Agent tries to add edition via factory — should fail at instance level
        vm.prank(agent);
        vm.expectRevert();
        factory.addEdition(
            instance, "Piece 2", 0.1 ether, 0,
            "ipfs://piece2", ERC1155Instance.PricingModel.UNLIMITED, 0, 0
        );
    }

    function test_agent_blocked_after_global_revocation() public {
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Revoke Test",
            "ipfs://test",
            artist,
            address(vault),
            ""
        );

        // Revoke agent globally
        mockRegistry.setAgent(agent, false);

        // Agent tries to add edition — should fail at factory level
        vm.prank(agent);
        vm.expectRevert();
        factory.addEdition(
            instance, "Piece 2", 0.1 ether, 0,
            "ipfs://piece2", ERC1155Instance.PricingModel.UNLIMITED, 0, 0
        );
    }

    // ── Artist direct access always works ──

    function test_artist_adds_edition_directly() public {
        vm.deal(artist, 1 ether);
        vm.prank(artist);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Direct Test",
            "ipfs://test",
            artist,
            address(vault),
            ""
        );

        vm.prank(artist);
        ERC1155Instance(instance).addEdition(
            "Direct Piece", 0.1 ether, 0,
            "ipfs://direct", ERC1155Instance.PricingModel.UNLIMITED, 0, 0
        );

        assertEq(ERC1155Instance(instance).nextEditionId(), 2);
    }

    // ── setAgentDelegation ──

    function test_only_owner_can_set_delegation() public {
        vm.deal(artist, 1 ether);
        vm.prank(artist);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Owner Only",
            "ipfs://test",
            artist,
            address(vault),
            ""
        );

        vm.prank(nobody);
        vm.expectRevert();
        ERC1155Instance(instance).setAgentDelegation(true);
    }
}
