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
import {ICreateX, CREATEX} from "../../../src/shared/CreateXConstants.sol";
import {CREATEX_BYTECODE} from "createx-forge/script/CreateX.d.sol";
import {FreeMintParams} from "../../../src/interfaces/IFactoryTypes.sol";
import {GatingScope} from "../../../src/gating/IGatingModule.sol";

contract ERC1155AgentDelegationTest is GlobalMessagingTestBase {
    ERC1155Factory public factory;
    UniAlignmentVault public vault;
    MockMasterRegistry public mockRegistry;
    MockEXECToken public token;
    ComponentRegistry public componentRegistry;
    MockAlignmentRegistry public mockAlignmentRegistry;

    uint256 internal _saltCounter;

    uint256 constant TARGET_ID = 1;
    address public owner = address(0x1);
    address public artist = address(0x5);
    address public agent = address(0x10);
    address public nobody = address(0x99);

    function _nextSalt() internal returns (bytes32) {
        _saltCounter++;
        return bytes32(abi.encodePacked(address(factory), uint8(0x00), bytes11(uint88(_saltCounter))));
    }

    function _params(string memory _name, address _creator) internal view returns (ERC1155Factory.CreateParams memory) {
        return ERC1155Factory.CreateParams({
            name: _name,
            metadataURI: "ipfs://test",
            creator: _creator,
            vault: address(vault),
            styleUri: "",
            gatingModule: address(0),
            freeMint: FreeMintParams({allocation: 0, scope: GatingScope.BOTH})
        });
    }

    function setUp() public {
        vm.startPrank(owner);
        vm.etch(CREATEX, CREATEX_BYTECODE);

        token = new MockEXECToken(1000000e18);
        mockAlignmentRegistry = new MockAlignmentRegistry();
        mockAlignmentRegistry.setTargetActive(TARGET_ID, true);
        mockAlignmentRegistry.setTokenInTarget(TARGET_ID, address(token), true);

        {
            UniAlignmentVault _impl = new UniAlignmentVault();
            vault = UniAlignmentVault(payable(LibClone.clone(address(_impl))));
            vault.initialize(
                owner,
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

        factory = new ERC1155Factory(address(mockRegistry), address(globalRegistry), address(componentRegistry), address(0xBEEF));

        // Register agent globally (on mock registry)
        mockRegistry.setAgent(agent, true);

        vm.stopPrank();
    }

    // ── Agent creates instance on behalf of artist ──

    function test_agent_creates_instance_on_behalf() public {
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Agent Created", artist)  // creator is artist, not agent
        );

        ERC1155Instance inst = ERC1155Instance(instance);
        assertEq(inst.owner(), artist);
        assertTrue(inst.agentDelegationEnabled());
    }

    function test_self_created_instance_delegation_disabled() public {
        vm.deal(artist, 1 ether);
        vm.prank(artist);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Self Created", artist)
        );

        ERC1155Instance inst = ERC1155Instance(instance);
        assertFalse(inst.agentDelegationEnabled());
    }

    function test_non_agent_cannot_create_on_behalf() public {
        vm.deal(nobody, 1 ether);
        vm.prank(nobody);
        vm.expectRevert();
        factory.createInstance{value: 0}(
            _nextSalt(), _params("Should Fail", artist)
        );
    }

    // ── Agent adds edition via factory ──

    function test_agent_adds_edition_via_instance() public {
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Agent Collection", artist)
        );

        // agentDelegationEnabled is true because agent created on behalf of artist
        vm.prank(agent);
        ERC1155Instance(instance).addEdition(
            "Piece 1",
            0.1 ether,
            0,
            "ipfs://piece1",
            ERC1155Instance.PricingModel.UNLIMITED,
            0,
            0
        );

        assertEq(ERC1155Instance(instance).nextEditionId(), 2); // edition 1 added
    }

    function test_agent_blocked_when_delegation_disabled() public {
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Toggle Test", artist)
        );

        // Artist disables delegation
        vm.prank(artist);
        ERC1155Instance(instance).setAgentDelegation(false);

        // Agent tries to add edition directly — should fail at instance level
        vm.prank(agent);
        vm.expectRevert();
        ERC1155Instance(instance).addEdition(
            "Piece 2", 0.1 ether, 0,
            "ipfs://piece2", ERC1155Instance.PricingModel.UNLIMITED, 0, 0
        );
    }

    function test_agent_blocked_after_global_revocation() public {
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Revoke Test", artist)
        );

        // Revoke agent globally
        mockRegistry.setAgent(agent, false);

        // Agent tries to add edition directly — instance checks masterRegistry.isAgent
        vm.prank(agent);
        vm.expectRevert();
        ERC1155Instance(instance).addEdition(
            "Piece 2", 0.1 ether, 0,
            "ipfs://piece2", ERC1155Instance.PricingModel.UNLIMITED, 0, 0
        );
    }

    // ── Artist direct access always works ──

    function test_artist_adds_edition_directly() public {
        vm.deal(artist, 1 ether);
        vm.prank(artist);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Direct Test", artist)
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
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Owner Only", artist)
        );

        vm.prank(nobody);
        vm.expectRevert();
        ERC1155Instance(instance).setAgentDelegation(true);
    }
}
