// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ERC721AuctionFactory} from "../../../src/factories/erc721/ERC721AuctionFactory.sol";
import {ERC721AuctionInstance} from "../../../src/factories/erc721/ERC721AuctionInstance.sol";
import {UltraAlignmentVault} from "../../../src/vaults/UltraAlignmentVault.sol";
import {MockEXECToken} from "../../mocks/MockEXECToken.sol";
import {MockMasterRegistry} from "../../mocks/MockMasterRegistry.sol";
import {MockVaultSwapRouter} from "../../mocks/MockVaultSwapRouter.sol";
import {MockVaultPriceValidator} from "../../mocks/MockVaultPriceValidator.sol";
import {IVaultSwapRouter} from "../../../src/interfaces/IVaultSwapRouter.sol";
import {IVaultPriceValidator} from "../../../src/interfaces/IVaultPriceValidator.sol";
import {GlobalMessageRegistry} from "../../../src/registry/GlobalMessageRegistry.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

contract ERC721AuctionFactoryTest is Test {
    ERC721AuctionFactory public factory;
    UltraAlignmentVault public vault;
    MockEXECToken public token;
    MockMasterRegistry public mockRegistry;

    address public owner = address(0x1);
    address public artist = address(0x2);
    address public bidder1 = address(0x3);
    address public bidder2 = address(0x4);
    address public treasury = address(0x5);

    uint40 constant BASE_DURATION = 1 hours;
    uint40 constant TIME_BUFFER = 5 minutes;
    uint256 constant BID_INCREMENT = 0.01 ether;

    function setUp() public {
        vm.startPrank(owner);

        token = new MockEXECToken(1000000e18);

        {
            UltraAlignmentVault _impl = new UltraAlignmentVault();
            vault = UltraAlignmentVault(payable(LibClone.clone(address(_impl))));
            vault.initialize(
                address(0x2222222222222222222222222222222222222222),
                address(0x4444444444444444444444444444444444444444),
                address(0x5555555555555555555555555555555555555555),
                address(0x6666666666666666666666666666666666666666),
                address(0x7777777777777777777777777777777777777777),
                address(0x8888888888888888888888888888888888888888),
                address(token),
                address(0xC1EA),
                100,
                IVaultSwapRouter(address(new MockVaultSwapRouter())),
                IVaultPriceValidator(address(new MockVaultPriceValidator()))
            );
        }

        PoolKey memory mockPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        vault.setV4PoolKey(mockPoolKey);

        mockRegistry = new MockMasterRegistry();

        GlobalMessageRegistry msgRegistry = new GlobalMessageRegistry();
        msgRegistry.initialize(owner, address(mockRegistry));
        factory = new ERC721AuctionFactory(address(mockRegistry), address(0xC1EA), 2000, address(msgRegistry));
        factory.setProtocolTreasury(treasury);

        vm.stopPrank();
    }

    // ┌─────────────────────────┐
    // │    Factory Tests        │
    // └─────────────────────────┘

    function test_FactoryCreation() public view {
        assertEq(factory.instanceCreationFee(), 0.01 ether);
        assertEq(factory.creator(), address(0xC1EA));
        assertEq(factory.creatorFeeBps(), 2000);
    }

    function test_CreateInstance() public {
        vm.deal(artist, 1 ether);
        vm.prank(artist);

        address instance = factory.createInstance{value: 0.01 ether}(
            "Test Auctions",
            "ipfs://test",
            artist,
            address(vault),
            "TART",
            1,
            BASE_DURATION,
            TIME_BUFFER,
            BID_INCREMENT
        );

        assertTrue(instance != address(0));
        ERC721AuctionInstance inst = ERC721AuctionInstance(payable(instance));
        assertEq(inst.name(), "Test Auctions");
        assertEq(inst.symbol(), "TART");
        assertEq(inst.vault(), address(vault));
        assertEq(inst.protocolTreasury(), treasury);
        assertEq(inst.lines(), 1);
        assertEq(inst.baseDuration(), BASE_DURATION);
        assertEq(inst.timeBuffer(), TIME_BUFFER);
        assertEq(inst.bidIncrement(), BID_INCREMENT);
        assertEq(inst.owner(), artist);
    }

    function test_CreateInstance_InsufficientFee() public {
        vm.deal(artist, 1 ether);
        vm.prank(artist);

        vm.expectRevert("Insufficient fee");
        factory.createInstance{value: 0.001 ether}(
            "Test Auctions",
            "ipfs://test",
            artist,
            address(vault),
            "TART",
            1,
            BASE_DURATION,
            TIME_BUFFER,
            BID_INCREMENT
        );
    }

    function test_CreateInstance_FeeSplit() public {
        vm.deal(artist, 1 ether);
        vm.prank(artist);

        factory.createInstance{value: 0.01 ether}(
            "Test Auctions",
            "ipfs://test",
            artist,
            address(vault),
            "TART",
            1,
            BASE_DURATION,
            TIME_BUFFER,
            BID_INCREMENT
        );

        // 20% to creator, 80% to protocol
        assertEq(factory.accumulatedCreatorFees(), 0.002 ether);
        assertEq(factory.accumulatedProtocolFees(), 0.008 ether);
    }

    function test_CreateInstance_RefundsExcess() public {
        vm.deal(artist, 1 ether);
        uint256 balBefore = artist.balance;
        vm.prank(artist);

        factory.createInstance{value: 0.05 ether}(
            "Test Auctions",
            "ipfs://test",
            artist,
            address(vault),
            "TART",
            1,
            BASE_DURATION,
            TIME_BUFFER,
            BID_INCREMENT
        );

        // Should have refunded 0.04 ether
        assertEq(balBefore - artist.balance, 0.01 ether);
    }

    function test_WithdrawFees() public {
        // Create an instance to generate fees
        vm.deal(artist, 1 ether);
        vm.prank(artist);
        factory.createInstance{value: 0.01 ether}(
            "Test Auctions",
            "ipfs://test",
            artist,
            address(vault),
            "TART",
            1,
            BASE_DURATION,
            TIME_BUFFER,
            BID_INCREMENT
        );

        // Withdraw protocol fees
        vm.prank(owner);
        factory.withdrawProtocolFees();
        assertEq(factory.accumulatedProtocolFees(), 0);

        // Withdraw creator fees
        vm.prank(address(0xC1EA));
        factory.withdrawCreatorFees();
        assertEq(factory.accumulatedCreatorFees(), 0);
    }

    // ┌─────────────────────────┐
    // │   Auction Flow Tests    │
    // └─────────────────────────┘

    function _createDefaultInstance() internal returns (ERC721AuctionInstance) {
        vm.deal(artist, 100 ether);
        vm.prank(artist);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Artist Collection",
            "ipfs://meta",
            artist,
            address(vault),
            "ART",
            1,
            BASE_DURATION,
            TIME_BUFFER,
            BID_INCREMENT
        );
        return ERC721AuctionInstance(payable(instance));
    }

    function test_QueuePiece() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        assertEq(auction.tokenId, 1);
        assertEq(auction.minBid, 0.1 ether);
        assertEq(auction.highBidder, address(0));
        assertTrue(auction.startTime > 0); // Should auto-start (first piece on line)
        assertFalse(auction.settled);
    }

    function test_QueuePiece_RequiresDeposit() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        vm.expectRevert("Deposit required");
        inst.queuePiece{value: 0}("ipfs://piece1");
    }

    function test_QueuePiece_RequiresURI() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        vm.expectRevert("URI required");
        inst.queuePiece{value: 0.1 ether}("");
    }

    function test_QueuePiece_OnlyOwner() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        vm.expectRevert();
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");
    }

    function test_Bidding_FirstBid() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, bytes(""));

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        assertEq(auction.highBidder, bidder1);
        assertEq(auction.highBid, 0.1 ether);
    }

    function test_Bidding_BelowMinimum() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        vm.expectRevert("Bid below minimum");
        inst.createBid{value: 0.05 ether}(1, bytes(""));
    }

    function test_Bidding_Outbid() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        // First bid
        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, bytes(""));

        // Outbid
        uint256 bidder1BalBefore = bidder1.balance;
        vm.deal(bidder2, 1 ether);
        vm.prank(bidder2);
        inst.createBid{value: 0.15 ether}(1, bytes(""));

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        assertEq(auction.highBidder, bidder2);
        assertEq(auction.highBid, 0.15 ether);

        // Bidder1 should have been refunded
        assertEq(bidder1.balance, bidder1BalBefore + 0.1 ether);
    }

    function test_Bidding_IncrementTooLow() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, bytes(""));

        vm.deal(bidder2, 1 ether);
        vm.prank(bidder2);
        vm.expectRevert("Bid too low");
        inst.createBid{value: 0.105 ether}(1, bytes("")); // Less than 0.1 + 0.01 increment
    }

    function test_Bidding_AntiSnipe() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        uint40 originalEnd = auction.endTime;

        // Warp to 2 minutes before end (within 5-minute buffer)
        vm.warp(originalEnd - 2 minutes);

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, bytes(""));

        auction = inst.getAuction(1);
        // End time should be extended by timeBuffer from current time
        assertEq(auction.endTime, uint40(block.timestamp) + TIME_BUFFER);
        assertTrue(auction.endTime > originalEnd);
    }

    function test_Bidding_ExpiredAuction() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        // Warp past end time
        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        vm.warp(auction.endTime + 1);

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        vm.expectRevert("Auction expired");
        inst.createBid{value: 0.1 ether}(1, bytes(""));
    }

    // ┌─────────────────────────┐
    // │   Settlement Tests      │
    // └─────────────────────────┘

    function test_SettleAuction() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        // Place bid
        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 1 ether}(1, bytes(""));

        // Warp past end
        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        vm.warp(auction.endTime);

        uint256 artistBalBefore = artist.balance;
        uint256 vaultBalBefore = address(vault).balance;

        // Settle
        inst.settleAuction(1);

        // NFT minted to bidder1
        assertEq(inst.ownerOf(1), bidder1);

        // Creator deposit refunded + 80% of winning bid
        uint256 expectedCreatorPay = 0.1 ether + (1 ether * 80) / 100;
        assertEq(artist.balance - artistBalBefore, expectedCreatorPay);

        // 20% of winning bid to vault
        uint256 expectedVaultCut = (1 ether * 20) / 100;
        assertEq(address(vault).balance - vaultBalBefore, expectedVaultCut);

        // Auction marked as settled
        auction = inst.getAuction(1);
        assertTrue(auction.settled);
    }

    function test_SettleAuction_BeforeEnd() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, bytes(""));

        vm.expectRevert("Auction not ended");
        inst.settleAuction(1);
    }

    function test_SettleAuction_NoBids() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        vm.warp(auction.endTime);

        vm.expectRevert("No bids");
        inst.settleAuction(1);
    }

    // ┌─────────────────────────┐
    // │  Unsold Reclaim Tests   │
    // └─────────────────────────┘

    function test_ReclaimUnsold() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        // Warp past end
        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        vm.warp(auction.endTime);

        uint256 treasuryBalBefore = treasury.balance;

        // Reclaim
        vm.prank(artist);
        inst.reclaimUnsold(1);

        // Deposit forfeited to treasury
        assertEq(treasury.balance - treasuryBalBefore, 0.1 ether);

        // Auction settled
        auction = inst.getAuction(1);
        assertTrue(auction.settled);
    }

    function test_ReclaimUnsold_HasBids() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, bytes(""));

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        vm.warp(auction.endTime);

        vm.prank(artist);
        vm.expectRevert("Has bids - use settleAuction");
        inst.reclaimUnsold(1);
    }

    function test_ReclaimUnsold_OnlyOwner() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        vm.warp(auction.endTime);

        vm.prank(bidder1);
        vm.expectRevert();
        inst.reclaimUnsold(1);
    }

    // ┌─────────────────────────┐
    // │    Lines System Tests   │
    // └─────────────────────────┘

    function test_Lines_RoundRobin() public {
        // Create instance with 3 lines
        vm.deal(artist, 100 ether);
        vm.prank(artist);
        address instance = factory.createInstance{value: 0.01 ether}(
            "Multi Line",
            "ipfs://meta",
            artist,
            address(vault),
            "ML",
            3,
            BASE_DURATION,
            TIME_BUFFER,
            BID_INCREMENT
        );
        ERC721AuctionInstance inst = ERC721AuctionInstance(payable(instance));

        // Queue 6 pieces
        vm.startPrank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://1"); // tokenId 1 -> line 0
        inst.queuePiece{value: 0.1 ether}("ipfs://2"); // tokenId 2 -> line 1
        inst.queuePiece{value: 0.1 ether}("ipfs://3"); // tokenId 3 -> line 2
        inst.queuePiece{value: 0.1 ether}("ipfs://4"); // tokenId 4 -> line 0
        inst.queuePiece{value: 0.1 ether}("ipfs://5"); // tokenId 5 -> line 1
        inst.queuePiece{value: 0.1 ether}("ipfs://6"); // tokenId 6 -> line 2
        vm.stopPrank();

        // Check active auctions per line
        assertEq(inst.getActiveAuction(0), 1);
        assertEq(inst.getActiveAuction(1), 2);
        assertEq(inst.getActiveAuction(2), 3);

        // Queue lengths: 2 each (1 active + 1 pending)
        assertEq(inst.getQueueLength(0), 2);
        assertEq(inst.getQueueLength(1), 2);
        assertEq(inst.getQueueLength(2), 2);
    }

    function test_Lines_AutoAdvance() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        // Queue 2 pieces on same line
        vm.startPrank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://1");
        inst.queuePiece{value: 0.1 ether}("ipfs://2");
        vm.stopPrank();

        // Piece 1 should be active, piece 2 queued
        assertEq(inst.getActiveAuction(0), 1);

        // Bid and settle piece 1
        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, bytes(""));

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        vm.warp(auction.endTime);
        inst.settleAuction(1);

        // Piece 2 should now be active
        assertEq(inst.getActiveAuction(0), 2);
        auction = inst.getAuction(2);
        assertTrue(auction.startTime > 0);
    }

    // ┌─────────────────────────┐
    // │    TokenURI Tests       │
    // └─────────────────────────┘

    function test_TokenURI() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        // Bid and settle
        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, bytes(""));

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        vm.warp(auction.endTime);
        inst.settleAuction(1);

        assertEq(inst.tokenURI(1), "ipfs://piece1");
    }

    // ┌─────────────────────────┐
    // │   Full Workflow Test    │
    // └─────────────────────────┘

    function test_FullWorkflow_QueueBidSettle() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        // Artist queues 3 pieces
        vm.startPrank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://1");
        inst.queuePiece{value: 0.2 ether}("ipfs://2");
        inst.queuePiece{value: 0.3 ether}("ipfs://3");
        vm.stopPrank();

        // Piece 1 is active, 2 and 3 are queued
        assertEq(inst.getActiveAuction(0), 1);

        // Bid on piece 1
        vm.deal(bidder1, 10 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.5 ether}(1, bytes(""));

        // Settle piece 1
        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        vm.warp(auction.endTime);
        inst.settleAuction(1);

        assertEq(inst.ownerOf(1), bidder1);
        assertEq(inst.getActiveAuction(0), 2);

        // Piece 2: no bids, reclaim
        auction = inst.getAuction(2);
        vm.warp(auction.endTime);
        vm.prank(artist);
        inst.reclaimUnsold(2);

        assertEq(inst.getActiveAuction(0), 3);

        // Piece 3: bid and settle
        vm.prank(bidder1);
        inst.createBid{value: 0.3 ether}(3, bytes(""));

        auction = inst.getAuction(3);
        vm.warp(auction.endTime);
        inst.settleAuction(3);

        assertEq(inst.ownerOf(3), bidder1);
        assertEq(inst.getActiveAuction(0), 0); // No more pieces
    }

    // ┌─────────────────────────┐
    // │   Messaging Tests       │
    // └─────────────────────────┘

    function test_Bidding_WithMessage() public {
        ERC721AuctionInstance inst = _createDefaultInstance();

        vm.prank(artist);
        inst.queuePiece{value: 0.1 ether}("ipfs://piece1");

        // Bid with a message
        vm.deal(bidder1, 1 ether);
        vm.prank(bidder1);
        inst.createBid{value: 0.1 ether}(1, abi.encode(uint8(0), uint256(0), bytes32(0), bytes32(0), "gm love this piece"));

        ERC721AuctionInstance.Auction memory auction = inst.getAuction(1);
        assertEq(auction.highBidder, bidder1);
        assertEq(auction.highBid, 0.1 ether);
    }

    function test_GetGlobalMessageRegistry() public {
        ERC721AuctionInstance inst = _createDefaultInstance();
        // globalMessageRegistry is now set at factory construction, passed to instances as immutable
        assertTrue(inst.getGlobalMessageRegistry() != address(0));
    }
}
