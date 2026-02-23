// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "solady/tokens/ERC721.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IAlignmentVault} from "../../interfaces/IAlignmentVault.sol";
import {IFactoryInstance} from "../../interfaces/IFactoryInstance.sol";
import {IGlobalMessageRegistry} from "../../registry/interfaces/IGlobalMessageRegistry.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IInstanceLifecycle, TYPE_ERC721, STATE_ACTIVE} from "../../interfaces/IInstanceLifecycle.sol";

/**
 * @title ERC721AuctionInstance
 * @notice ERC721 contract with built-in English auction mechanics for 1/1 artists.
 *         Artists queue pieces with metadata and ETH deposits, buyers bid in English auctions.
 * @dev Implements parallel auction lines (1-3 concurrent slots) with round-robin token assignment.
 *      All auction parameters are immutable after creation for predictability.
 */
contract ERC721AuctionInstance is ERC721, Ownable, ReentrancyGuard, IFactoryInstance, IInstanceLifecycle {
    // ┌─────────────────────────┐
    // │         Types           │
    // └─────────────────────────┘

    struct Auction {
        uint24 tokenId;
        string tokenURI;
        uint256 minBid;         // Creator's deposit = minimum bid
        address highBidder;
        uint256 highBid;
        uint40 startTime;
        uint40 endTime;
        bool settled;
    }

    // ┌─────────────────────────┐
    // │   Immutable Config      │
    // └─────────────────────────┘

    IAlignmentVault public immutable _vault;
    address public immutable _protocolTreasury;
    IGlobalMessageRegistry public immutable globalMessageRegistry;
    uint8 public immutable lines;
    uint40 public immutable baseDuration;
    uint40 public immutable timeBuffer;
    uint256 public immutable bidIncrement;

    // ┌─────────────────────────┐
    // │      State Variables     │
    // └─────────────────────────┘

    string private _name;
    string private _symbol;

    // Next token ID to be assigned when queuing a piece (1-indexed)
    uint24 public nextTokenId;

    // Per-line queues: lineIndex => array of tokenIds in queue order
    mapping(uint8 => uint24[]) public lineQueues;
    // Per-line: index of next piece to activate from the queue
    mapping(uint8 => uint256) public lineQueueHead;

    // Token data
    mapping(uint24 => Auction) public auctions;
    mapping(uint24 => string) private _tokenURIs;


    // ┌─────────────────────────┐
    // │         Events          │
    // └─────────────────────────┘

    event PieceQueued(uint24 indexed tokenId, uint8 indexed line, uint256 minBid, string tokenURI);
    event AuctionStarted(uint24 indexed tokenId, uint40 startTime, uint40 endTime);
    event BidPlaced(uint24 indexed tokenId, address indexed bidder, uint256 amount);
    event AuctionSettled(uint24 indexed tokenId, address indexed winner, uint256 amount);
    event UnsoldReclaimed(uint24 indexed tokenId, uint256 forfeitedDeposit);

    // ┌─────────────────────────┐
    // │      Constructor        │
    // └─────────────────────────┘

    constructor(
        address vault_,
        address protocolTreasury_,
        address owner_,
        string memory name_,
        string memory symbol_,
        uint8 lines_,
        uint40 baseDuration_,
        uint40 timeBuffer_,
        uint256 bidIncrement_,
        address globalMessageRegistry_
    ) {
        require(vault_ != address(0), "Invalid vault");
        require(protocolTreasury_ != address(0), "Invalid treasury");
        require(owner_ != address(0), "Invalid owner");
        require(globalMessageRegistry_ != address(0), "Invalid global message registry");
        require(bytes(name_).length > 0, "Invalid name");
        require(bytes(symbol_).length > 0, "Invalid symbol");
        require(lines_ >= 1 && lines_ <= 3, "Lines must be 1-3");
        require(baseDuration_ > 0, "Invalid duration");
        require(timeBuffer_ > 0, "Invalid time buffer");
        require(bidIncrement_ > 0, "Invalid bid increment");

        _initializeOwner(owner_);
        _vault = IAlignmentVault(payable(vault_));
        _protocolTreasury = protocolTreasury_;
        _name = name_;
        _symbol = symbol_;
        lines = lines_;
        baseDuration = baseDuration_;
        timeBuffer = timeBuffer_;
        bidIncrement = bidIncrement_;
        globalMessageRegistry = IGlobalMessageRegistry(globalMessageRegistry_);
        nextTokenId = 1;
    }

    // ┌─────────────────────────┐
    // │   IFactoryInstance      │
    // └─────────────────────────┘

    function vault() external view override returns (address) {
        return address(_vault);
    }

    function protocolTreasury() external view override returns (address) {
        return _protocolTreasury;
    }

    function getGlobalMessageRegistry() external view override returns (address) {
        return address(globalMessageRegistry);
    }

    // ── IInstanceLifecycle ─────────────────────────────────────────────────────

    function instanceType() external pure override returns (bytes32) {
        return TYPE_ERC721;
    }

    // ┌─────────────────────────┐
    // │   ERC721 Overrides      │
    // └─────────────────────────┘

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId), "Token does not exist");
        return _tokenURIs[uint24(tokenId)];
    }

    // ┌─────────────────────────┐
    // │    Piece Queuing        │
    // └─────────────────────────┘

    /**
     * @notice Queue a new piece for auction
     * @dev msg.value becomes the minimum bid (creator's skin in the game).
     *      Piece is assigned to a line via round-robin and starts immediately if line is idle.
     * @param _tokenURI Metadata URI for the piece (required)
     */
    function queuePiece(string calldata _tokenURI) external payable onlyOwner nonReentrant {
        require(msg.value > 0, "Deposit required");
        require(bytes(_tokenURI).length > 0, "URI required");

        uint24 tokenId = nextTokenId++;
        if (tokenId == 1) emit StateChanged(STATE_ACTIVE);
        uint8 line = uint8((tokenId - 1) % lines);

        auctions[tokenId] = Auction({
            tokenId: tokenId,
            tokenURI: _tokenURI,
            minBid: msg.value,
            highBidder: address(0),
            highBid: 0,
            startTime: 0,
            endTime: 0,
            settled: false
        });
        _tokenURIs[tokenId] = _tokenURI;

        // Add to line queue
        lineQueues[line].push(tokenId);

        emit PieceQueued(tokenId, line, msg.value, _tokenURI);

        // If this is the only piece in the queue for this line, start it
        if (lineQueues[line].length - lineQueueHead[line] == 1) {
            _startAuction(tokenId);
        }
    }

    // ┌─────────────────────────┐
    // │       Bidding           │
    // └─────────────────────────┘

    /**
     * @notice Place a bid on an active auction
     * @dev First bid must meet minBid. Subsequent bids must exceed current by bidIncrement.
     *      Previous bidder is refunded via forceSafeTransferETH. Late bids extend the auction.
     * @param tokenId The token ID to bid on
     */
    function createBid(uint24 tokenId, bytes calldata messageData) external payable nonReentrant {
        Auction storage auction = auctions[tokenId];
        require(auction.tokenId != 0, "Auction does not exist");
        require(auction.startTime != 0, "Auction not started");
        require(!auction.settled, "Auction already settled");
        require(block.timestamp < auction.endTime, "Auction expired");

        if (auction.highBidder == address(0)) {
            // First bid must meet minimum
            require(msg.value >= auction.minBid, "Bid below minimum");
        } else {
            // Subsequent bids must exceed current by increment
            require(msg.value >= auction.highBid + bidIncrement, "Bid too low");
        }

        // Refund previous bidder
        address previousBidder = auction.highBidder;
        uint256 previousBid = auction.highBid;

        auction.highBidder = msg.sender;
        auction.highBid = msg.value;

        if (previousBidder != address(0)) {
            SafeTransferLib.forceSafeTransferETH(previousBidder, previousBid);
        }

        // Anti-snipe: extend if bid is within timeBuffer of end
        if (auction.endTime - block.timestamp < timeBuffer) {
            auction.endTime = uint40(block.timestamp) + timeBuffer;
        }

        if (messageData.length > 0) {
            globalMessageRegistry.postForAction(msg.sender, address(this), messageData);
        }

        emit BidPlaced(tokenId, msg.sender, msg.value);
    }

    // ┌─────────────────────────┐
    // │     Settlement          │
    // └─────────────────────────┘

    /**
     * @notice Settle an auction after it ends with bids
     * @dev Mints NFT to winner, refunds creator deposit, splits winning bid (20% vault, 80% creator).
     *      Auto-advances line to next queued piece.
     * @param tokenId The token ID to settle
     */
    function settleAuction(uint24 tokenId) external nonReentrant {
        Auction storage auction = auctions[tokenId];
        require(auction.tokenId != 0, "Auction does not exist");
        require(auction.startTime != 0, "Auction not started");
        require(!auction.settled, "Already settled");
        require(block.timestamp >= auction.endTime, "Auction not ended");
        require(auction.highBidder != address(0), "No bids");

        auction.settled = true;

        // Mint NFT to winner
        _mint(auction.highBidder, tokenId);

        // Refund creator's deposit
        SafeTransferLib.safeTransferETH(owner(), auction.minBid);

        // Split winning bid: 20% to vault, 80% to creator
        uint256 vaultCut = (auction.highBid * 20) / 100;
        uint256 creatorCut = auction.highBid - vaultCut;

        _vault.receiveContribution{value: vaultCut}(
            Currency.wrap(address(0)),
            vaultCut,
            address(this)
        );
        SafeTransferLib.safeTransferETH(owner(), creatorCut);

        emit AuctionSettled(tokenId, auction.highBidder, auction.highBid);

        // Advance line to next queued piece
        _advanceLine(tokenId);
    }

    // ┌─────────────────────────┐
    // │    Unsold Reclaim       │
    // └─────────────────────────┘

    /**
     * @notice Reclaim an unsold piece (auction expired with no bids)
     * @dev NFT is never minted. Creator deposit is forfeited to protocol treasury.
     *      Line advances to next queued piece.
     * @param tokenId The token ID to reclaim
     */
    function reclaimUnsold(uint24 tokenId) external onlyOwner nonReentrant {
        Auction storage auction = auctions[tokenId];
        require(auction.tokenId != 0, "Auction does not exist");
        require(auction.startTime != 0, "Auction not started");
        require(!auction.settled, "Already settled");
        require(block.timestamp >= auction.endTime, "Auction not ended");
        require(auction.highBidder == address(0), "Has bids - use settleAuction");

        auction.settled = true;

        // Forfeit deposit to protocol treasury
        uint256 deposit = auction.minBid;
        SafeTransferLib.safeTransferETH(_protocolTreasury, deposit);

        emit UnsoldReclaimed(tokenId, deposit);

        // Advance line to next queued piece
        _advanceLine(tokenId);
    }

    // ┌─────────────────────────┐
    // │   Vault Fee Claiming    │
    // └─────────────────────────┘

    /**
     * @notice Claim accumulated vault fees and forward to creator
     * @return totalClaimed Amount of ETH claimed
     */
    function claimVaultFees() external onlyOwner nonReentrant returns (uint256 totalClaimed) {
        totalClaimed = _vault.claimFees();
        require(totalClaimed > 0, "No fees to claim");
        SafeTransferLib.safeTransferETH(owner(), totalClaimed);
    }

    // ┌─────────────────────────┐
    // │    Internal Helpers     │
    // └─────────────────────────┘

    function _startAuction(uint24 tokenId) internal {
        Auction storage auction = auctions[tokenId];
        auction.startTime = uint40(block.timestamp);
        auction.endTime = uint40(block.timestamp) + baseDuration;

        emit AuctionStarted(tokenId, auction.startTime, auction.endTime);
    }

    function _advanceLine(uint24 tokenId) internal {
        uint8 line = uint8((tokenId - 1) % lines);
        lineQueueHead[line]++;

        // Start next auction if queue has more pieces
        if (lineQueueHead[line] < lineQueues[line].length) {
            uint24 nextId = lineQueues[line][lineQueueHead[line]];
            _startAuction(nextId);
        }
    }

    // ┌─────────────────────────┐
    // │      View Functions     │
    // └─────────────────────────┘

    /**
     * @notice Get the currently active auction for a line
     * @param line Line index (0-based)
     * @return tokenId Active token ID (0 if no active auction)
     */
    function getActiveAuction(uint8 line) external view returns (uint24 tokenId) {
        require(line < lines, "Invalid line");
        uint256 head = lineQueueHead[line];
        if (head >= lineQueues[line].length) return 0;
        uint24 id = lineQueues[line][head];
        if (auctions[id].settled) return 0;
        return id;
    }

    /**
     * @notice Get queue length for a line (pending + active)
     * @param line Line index (0-based)
     * @return remaining Number of unprocessed pieces in queue
     */
    function getQueueLength(uint8 line) external view returns (uint256 remaining) {
        require(line < lines, "Invalid line");
        return lineQueues[line].length - lineQueueHead[line];
    }

    /**
     * @notice Get auction details
     * @param tokenId Token ID
     */
    function getAuction(uint24 tokenId) external view returns (Auction memory) {
        require(auctions[tokenId].tokenId != 0, "Auction does not exist");
        return auctions[tokenId];
    }

    // Allow receiving ETH (for vault refunds etc.)
    receive() external payable {}
}
