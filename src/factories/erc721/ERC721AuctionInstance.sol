// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "solady/tokens/ERC721.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IAlignmentVault} from "../../interfaces/IAlignmentVault.sol";
import {IMasterRegistry} from "../../master/interfaces/IMasterRegistry.sol";

import {IGlobalMessageRegistry} from "../../registry/interfaces/IGlobalMessageRegistry.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {RevenueSplitLib} from "../../shared/libraries/RevenueSplitLib.sol";
import {IInstanceLifecycle, TYPE_ERC721, STATE_ACTIVE} from "../../interfaces/IInstanceLifecycle.sol";

// ── ERC721AuctionInstance errors ──────────────────────────────────────────────
error InvalidAddress();
error InvalidName();
error InvalidSymbol();
error InvalidLines();
error InvalidDuration();
error InvalidTimeBuffer();
error InvalidBidIncrement();
error DepositRequired();
error URIRequired();
error AuctionDoesNotExist();
error AuctionNotStarted();
error AuctionAlreadySettled();
error AuctionNotEnded();
error AuctionExpired();
error BidBelowMinimum();
error BidTooLow();
error NoBids();
error HasBids();
error NoFeesToClaim();
error TokenDoesNotExist();
error InvalidLine();
error Unauthorized();

/**
 * @title ERC721AuctionInstance
 * @notice ERC721 contract with built-in English auction mechanics for 1/1 artists.
 *         Artists queue pieces with metadata and ETH deposits, buyers bid in English auctions.
 * @dev Implements parallel auction lines (1-3 concurrent slots) with round-robin token assignment.
 *      All auction parameters are immutable after creation for predictability.
 */
contract ERC721AuctionInstance is ERC721, Ownable, ReentrancyGuard, IInstanceLifecycle {
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

    IAlignmentVault public vault;
    IMasterRegistry public masterRegistry;
    address public immutable protocolTreasury;
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
    address public factory;
    bool public agentDelegationEnabled;

    // ┌─────────────────────────┐
    // │         Events          │
    // └─────────────────────────┘

    event PieceQueued(uint24 indexed tokenId, uint8 indexed line, uint256 minBid, string tokenURI);
    event AuctionStarted(uint24 indexed tokenId, uint40 startTime, uint40 endTime);
    event BidPlaced(uint24 indexed tokenId, address indexed bidder, uint256 amount);
    event AuctionSettled(uint24 indexed tokenId, address indexed winner, uint256 amount);
    event UnsoldReclaimed(uint24 indexed tokenId, uint256 forfeitedDeposit);
    event AgentDelegationChanged(bool enabled);

    // ┌─────────────────────────┐
    // │      Constructor        │
    // └─────────────────────────┘

    struct ConstructorParams {
        address vault;
        address protocolTreasury;
        address owner;
        string name;
        string symbol;
        uint8 lines;
        uint40 baseDuration;
        uint40 timeBuffer;
        uint256 bidIncrement;
        address globalMessageRegistry;
        address masterRegistry;
        address factory;
    }

    constructor(ConstructorParams memory p) {
        if (p.vault == address(0)) revert InvalidAddress();
        if (p.protocolTreasury == address(0)) revert InvalidAddress();
        if (p.owner == address(0)) revert InvalidAddress();
        if (p.globalMessageRegistry == address(0)) revert InvalidAddress();
        if (bytes(p.name).length == 0) revert InvalidName();
        if (bytes(p.symbol).length == 0) revert InvalidSymbol();
        if (p.lines < 1 || p.lines > 3) revert InvalidLines();
        if (p.baseDuration == 0) revert InvalidDuration();
        if (p.timeBuffer == 0) revert InvalidTimeBuffer();
        if (p.bidIncrement == 0) revert InvalidBidIncrement();

        _initializeOwner(p.owner);
        vault = IAlignmentVault(payable(p.vault));
        masterRegistry = IMasterRegistry(p.masterRegistry);
        protocolTreasury = p.protocolTreasury;
        _name = p.name;
        _symbol = p.symbol;
        lines = p.lines;
        baseDuration = p.baseDuration;
        timeBuffer = p.timeBuffer;
        bidIncrement = p.bidIncrement;
        globalMessageRegistry = IGlobalMessageRegistry(p.globalMessageRegistry);
        factory = p.factory;
        nextTokenId = 1;
    }

    /// @notice Called by factory to enable delegation for agent-created instances
    function setAgentDelegationFromFactory() external {
        if (msg.sender != factory) revert Unauthorized();
        agentDelegationEnabled = true;
    }

    /// @notice Toggle agent delegation for this instance
    function setAgentDelegation(bool enabled) external onlyOwner {
        agentDelegationEnabled = enabled;
        emit AgentDelegationChanged(enabled);
    }

    function getGlobalMessageRegistry() external view returns (address) {
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
        if (!_exists(tokenId)) revert TokenDoesNotExist();
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
    function queuePiece(string calldata _tokenURI) external payable nonReentrant {
        if (msg.sender == owner()) {
            // Owner always allowed
        } else if (msg.sender == factory && agentDelegationEnabled) {
            // Factory forwarding agent call
        } else {
            revert Unauthorized();
        }
        if (msg.value == 0) revert DepositRequired();
        if (bytes(_tokenURI).length == 0) revert URIRequired();

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
        if (auction.tokenId == 0) revert AuctionDoesNotExist();
        if (auction.startTime == 0) revert AuctionNotStarted();
        if (auction.settled) revert AuctionAlreadySettled();
        if (block.timestamp >= auction.endTime) revert AuctionExpired();

        if (auction.highBidder == address(0)) {
            // First bid must meet minimum
            if (msg.value < auction.minBid) revert BidBelowMinimum();
        } else {
            // Subsequent bids must exceed current by increment
            if (msg.value < auction.highBid + bidIncrement) revert BidTooLow();
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
     * @dev Mints NFT to winner, refunds creator deposit, splits winning bid (1% protocol, 19% vault, 80% artist).
     *      Auto-advances line to next queued piece.
     * @param tokenId The token ID to settle
     */
    function settleAuction(uint24 tokenId) external nonReentrant {
        Auction storage auction = auctions[tokenId];
        if (auction.tokenId == 0) revert AuctionDoesNotExist();
        if (auction.startTime == 0) revert AuctionNotStarted();
        if (auction.settled) revert AuctionAlreadySettled();
        if (block.timestamp < auction.endTime) revert AuctionNotEnded();
        if (auction.highBidder == address(0)) revert NoBids();

        auction.settled = true;

        // Mint NFT to winner
        _mint(auction.highBidder, tokenId);

        // Refund creator's deposit
        SafeTransferLib.safeTransferETH(owner(), auction.minBid);

        // Split winning bid: 1/19/80
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(auction.highBid);

        if (s.protocolCut > 0 && protocolTreasury != address(0)) {
            SafeTransferLib.safeTransferETH(protocolTreasury, s.protocolCut);
        }

        vault.receiveContribution{value: s.vaultCut}(
            Currency.wrap(address(0)),
            s.vaultCut,
            address(this)
        );
        SafeTransferLib.safeTransferETH(owner(), s.remainder);

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
        if (auction.tokenId == 0) revert AuctionDoesNotExist();
        if (auction.startTime == 0) revert AuctionNotStarted();
        if (auction.settled) revert AuctionAlreadySettled();
        if (block.timestamp < auction.endTime) revert AuctionNotEnded();
        if (auction.highBidder != address(0)) revert HasBids();

        auction.settled = true;

        // Forfeit deposit to protocol treasury
        uint256 deposit = auction.minBid;
        SafeTransferLib.safeTransferETH(protocolTreasury, deposit);

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
        totalClaimed = vault.claimFees();
        if (totalClaimed == 0) revert NoFeesToClaim();
        SafeTransferLib.safeTransferETH(owner(), totalClaimed);
    }

    /// @notice Migrate to a new vault. New vault must share this instance's alignment target.
    /// @dev Updates local active vault and appends to registry vault array.
    function migrateVault(address newVault) external onlyOwner {
        vault = IAlignmentVault(payable(newVault));
        masterRegistry.migrateVault(address(this), newVault);
    }

    /// @notice Claim accumulated fees from all vault positions (current and historical).
    function claimAllFees() external onlyOwner {
        address[] memory allVaults = masterRegistry.getInstanceVaults(address(this));
        for (uint256 i = 0; i < allVaults.length; i++) {
            IAlignmentVault(payable(allVaults[i])).claimFees();
        }
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
        if (line >= lines) revert InvalidLine();
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
        if (line >= lines) revert InvalidLine();
        return lineQueues[line].length - lineQueueHead[line];
    }

    /**
     * @notice Get auction details
     * @param tokenId Token ID
     */
    function getAuction(uint24 tokenId) external view returns (Auction memory) {
        if (auctions[tokenId].tokenId == 0) revert AuctionDoesNotExist();
        return auctions[tokenId];
    }

    // Allow receiving ETH (for vault refunds etc.)
    receive() external payable {}
}
