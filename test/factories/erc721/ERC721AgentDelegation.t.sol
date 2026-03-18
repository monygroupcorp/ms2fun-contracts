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
import {ICreateX, CREATEX} from "../../../src/shared/CreateXConstants.sol";
import {CREATEX_BYTECODE} from "createx-forge/script/CreateX.d.sol";

contract ERC721AgentDelegationTest is GlobalMessagingTestBase {
    ERC721AuctionFactory public factory;
    UniAlignmentVault public vault;
    MockMasterRegistry public mockRegistry;
    MockEXECToken public token;
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

    function _params(string memory _name, address _creator) internal view returns (ERC721AuctionFactory.CreateParams memory) {
        return ERC721AuctionFactory.CreateParams({
            name: _name,
            metadataURI: "ipfs://test",
            creator: _creator,
            vault: address(vault),
            symbol: "ART",
            lines: 1,
            baseDuration: 1 days,
            timeBuffer: 15 minutes,
            bidIncrement: 0.01 ether
        });
    }

    function setUp() public {
        vm.etch(CREATEX, CREATEX_BYTECODE);

        vm.startPrank(owner);

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

        factory = new ERC721AuctionFactory(address(mockRegistry), address(globalRegistry), address(0xBEEF));
        factory.setProtocolTreasury(owner);

        mockRegistry.setAgent(agent, true);

        vm.stopPrank();
    }

    // ── Agent creates instance on behalf ──

    function test_agent_creates_instance_on_behalf() public {
        vm.deal(agent, 1 ether);
        vm.prank(agent);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Agent Auction", artist)
        );

        ERC721AuctionInstance inst = ERC721AuctionInstance(payable(instance));
        assertEq(inst.owner(), artist);
        assertTrue(inst.agentDelegationEnabled());
    }

    function test_self_created_delegation_disabled() public {
        vm.deal(artist, 1 ether);
        vm.prank(artist);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Self Auction", artist)
        );

        assertFalse(ERC721AuctionInstance(payable(instance)).agentDelegationEnabled());
    }

    function test_non_agent_cannot_create_on_behalf() public {
        vm.deal(nobody, 1 ether);
        vm.prank(nobody);
        vm.expectRevert();
        factory.createInstance{value: 0}(
            _nextSalt(), _params("Should Fail", artist)
        );
    }

    // ── Agent queues piece directly on instance ──

    function test_agent_queues_piece_directly() public {
        vm.deal(agent, 2 ether);
        vm.prank(agent);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Queue Test", artist)
        );

        // agentDelegationEnabled is true — agent calls instance directly
        vm.prank(agent);
        ERC721AuctionInstance(payable(instance)).queuePiece{value: 0.1 ether}("ipfs://piece1");

        assertEq(ERC721AuctionInstance(payable(instance)).nextTokenId(), 2);
    }

    function test_agent_blocked_when_delegation_disabled() public {
        vm.deal(agent, 2 ether);
        vm.prank(agent);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Toggle Test", artist)
        );

        vm.prank(artist);
        ERC721AuctionInstance(payable(instance)).setAgentDelegation(false);

        vm.prank(agent);
        vm.expectRevert();
        ERC721AuctionInstance(payable(instance)).queuePiece{value: 0.1 ether}("ipfs://piece2");
    }

    function test_agent_blocked_after_global_revocation() public {
        vm.deal(agent, 2 ether);
        vm.prank(agent);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Revoke Test", artist)
        );

        mockRegistry.setAgent(agent, false);

        vm.prank(agent);
        vm.expectRevert();
        ERC721AuctionInstance(payable(instance)).queuePiece{value: 0.1 ether}("ipfs://piece2");
    }

    // ── Artist direct access always works ──

    function test_artist_queues_piece_directly() public {
        vm.deal(artist, 1 ether);
        vm.prank(artist);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Direct Test", artist)
        );

        vm.prank(artist);
        ERC721AuctionInstance(payable(instance)).queuePiece{value: 0.05 ether}("ipfs://direct");
        assertEq(ERC721AuctionInstance(payable(instance)).nextTokenId(), 2);
    }

    function test_only_owner_can_set_delegation() public {
        vm.deal(artist, 1 ether);
        vm.prank(artist);
        address instance = factory.createInstance{value: 0}(
            _nextSalt(), _params("Auth Test", artist)
        );

        vm.prank(nobody);
        vm.expectRevert();
        ERC721AuctionInstance(payable(instance)).setAgentDelegation(true);
    }
}
