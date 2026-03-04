// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "solady/auth/Ownable.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { EditionPricing } from "./libraries/EditionPricing.sol";
import { IAlignmentVault } from "../../interfaces/IAlignmentVault.sol";
import {IMasterRegistry} from "../../master/interfaces/IMasterRegistry.sol";
import { IGlobalMessageRegistry } from "../../registry/interfaces/IGlobalMessageRegistry.sol";
import {IGatingModule, GatingScope} from "../../gating/IGatingModule.sol";

// ── Free mint errors ─────────────────────────────────────────────────────────
error FreeMintDisabled();
error FreeMintAlreadyClaimed();
error FreeMintExhausted();

// ── ERC1155Instance errors ───────────────────────────────────────────────────
error InvalidName();
error InvalidAddress();
error Unauthorized();
error AmountMustBePositive();
error EditionNotFound();
error EditionNotOpen();
error EditionSoldOut();
error ExceedsSupply();
error ExceedsMaxCost();
error InsufficientPayment();
error InsufficientBalance();
error InvalidTitle();
error InvalidPrice();
error UnlimitedMustHaveZeroSupply();
error LimitedMustHavePositiveSupply();
error DynamicPricingRequiresIncreaseRate();
error EditionLimitReached();
error NoFeesToClaim();
error LengthMismatch();
error InvalidEditionRange();
error GatingCheckFailed();
error ERC1155RejectedTokens();
error ERC1155TransferToNonReceiver();
error OnlyFactory();
error AlreadyInitialized();
import { Currency } from "v4-core/types/Currency.sol";
import { RevenueSplitLib } from "../../shared/libraries/RevenueSplitLib.sol";
import { IInstanceLifecycle, TYPE_ERC1155, STATE_MINTING } from "../../interfaces/IInstanceLifecycle.sol";

/**
 * @title ERC1155Instance
 * @notice ERC1155 token instance for open edition artists
 * @dev Supports unlimited/limited editions with fixed or dynamic pricing, message system, and withdraw tax
 */
// slither-disable-next-line missing-inheritance
contract ERC1155Instance is Ownable, ReentrancyGuard, IInstanceLifecycle {
    using EditionPricing for uint256;

    // ┌─────────────────────────┐
    // │         Types           │
    // └─────────────────────────┘

    enum PricingModel {
        UNLIMITED,      // Unlimited supply, fixed price
        LIMITED_FIXED,  // Limited supply, fixed price
        LIMITED_DYNAMIC // Limited supply, exponential price increase
    }

    struct Edition {
        uint256 id;
        string pieceTitle;
        uint256 basePrice;        // Base price for dynamic pricing
        uint256 supply;           // 0 = unlimited
        uint256 minted;
        string metadataURI;
        PricingModel pricingModel;
        uint256 priceIncreaseRate; // For dynamic pricing (basis points, e.g., 100 = 1%)
        uint256 openTime;          // Unix timestamp; 0 = open immediately
    }

    // ┌─────────────────────────┐
    // │      State Variables     │
    // └─────────────────────────┘

    string public name;
    // slither-disable-next-line immutable-states
    address public creator;
    // slither-disable-next-line immutable-states
    address public factory;
    IAlignmentVault public vault;
    // slither-disable-next-line immutable-states
    IMasterRegistry public masterRegistry;
    IGlobalMessageRegistry public immutable globalMessageRegistry;
    address public immutable protocolTreasury;

    // Customization
    string public styleUri;
    mapping(uint256 => string) public editionStyleUri;

    mapping(uint256 => Edition) public editions;
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    // slither-disable-next-line immutable-states
    IGatingModule public gatingModule;

    // Free mint
    uint256 public freeMintAllocation;
    uint256 public freeMintsClaimed;
    mapping(address => bool) public freeMintClaimed;
    GatingScope public gatingScope;
    bool private _freeMintInitialized;
    bool public agentDelegationEnabled;

    uint256 public nextEditionId;
    uint256 public totalProceeds; // Total ETH collected from mints

    // Events
    event TransferSingle(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256 id,
        uint256 value
    );

    event TransferBatch(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256[] ids,
        uint256[] values
    );

    event ApprovalForAll(
        address indexed account,
        address indexed operator,
        bool approved
    );

    event EditionAdded(
        uint256 indexed editionId,
        string pieceTitle,
        uint256 basePrice,
        uint256 supply,
        PricingModel pricingModel
    );

    event Minted(
        address indexed to,
        uint256 indexed editionId,
        uint256 amount,
        uint256 totalCost
    );

    event Withdrawn(
        address indexed creator,
        uint256 artistAmount,
        uint256 vaultCut,
        uint256 protocolCut
    );

    event EditionMetadataUpdated(uint256 indexed editionId, string metadataURI);
    event FreeMintClaimed(address indexed user, uint256 indexed editionId);
    event AgentDelegationChanged(bool enabled);

    // ┌─────────────────────────┐
    // │      Constructor        │
    // └─────────────────────────┘

    constructor(
        string memory _name,
        string memory /* metadataURI */,
        address _creator,
        address _factory,
        address _vault,
        string memory _styleUri,
        address _globalMessageRegistry,
        // slither-disable-next-line missing-zero-check
        address _protocolTreasury,
        address _masterRegistry,
        address _gatingModule,
        bool _agentCreated
    ) {
        if (bytes(_name).length == 0) revert InvalidName();
        if (_creator == address(0)) revert InvalidAddress();
        if (_factory == address(0)) revert InvalidAddress();
        if (_vault == address(0)) revert InvalidAddress();
        if (_globalMessageRegistry == address(0)) revert InvalidAddress();

        _initializeOwner(_creator);
        name = _name;
        creator = _creator;
        factory = _factory;
        vault = IAlignmentVault(payable(_vault));
        masterRegistry = IMasterRegistry(_masterRegistry);
        globalMessageRegistry = IGlobalMessageRegistry(_globalMessageRegistry);
        protocolTreasury = _protocolTreasury;
        styleUri = _styleUri;
        nextEditionId = 1;
        if (_gatingModule != address(0)) {
            gatingModule = IGatingModule(_gatingModule);
        }
        emit StateChanged(STATE_MINTING);
        agentDelegationEnabled = _agentCreated;
    }

    // ── IInstanceLifecycle ─────────────────────────────────────────────────────

    function instanceType() external pure override returns (bytes32) {
        return TYPE_ERC1155;
    }

    // ── Free mint ─────────────────────────────────────────────────────────────

    /// @notice Set free mint params. Called by factory once after construction.
    // slither-disable-next-line events-maths
    function initializeFreeMint(uint256 allocation, GatingScope scope) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (_freeMintInitialized) revert AlreadyInitialized();
        _freeMintInitialized = true;
        freeMintAllocation = allocation;
        gatingScope = scope;
    }

    /// @notice Toggle agent delegation for this instance
    function setAgentDelegation(bool enabled) external {
        if (msg.sender != owner()) revert Unauthorized();
        agentDelegationEnabled = enabled;
        emit AgentDelegationChanged(enabled);
    }

    /// @notice Claim one free token of a specified edition at zero ETH cost.
    /// @param editionId  The edition to claim from. Must exist.
    /// @param gatingData Passed to gatingModule.canMint if scope requires it.
    // slither-disable-next-line reentrancy-benign,reentrancy-no-eth,unused-return
    function claimFreeMint(uint256 editionId, bytes calldata gatingData) external nonReentrant {
        if (freeMintAllocation == 0) revert FreeMintDisabled();
        if (freeMintClaimed[msg.sender]) revert FreeMintAlreadyClaimed();
        if (freeMintsClaimed >= freeMintAllocation) revert FreeMintExhausted();

        Edition storage edition = editions[editionId];
        if (bytes(edition.pieceTitle).length == 0) revert EditionNotFound();
        if (edition.supply > 0) {
            if (edition.minted >= edition.supply) revert EditionSoldOut();
        }

        if (address(gatingModule) != address(0) && gatingScope != GatingScope.PAID_ONLY) {
            (bool allowed,) = gatingModule.canMint(msg.sender, 1, gatingData);
            if (!allowed) revert GatingCheckFailed();
            gatingModule.onMint(msg.sender, 1);
        }

        freeMintClaimed[msg.sender] = true;
        freeMintsClaimed++;
        edition.minted++;
        balanceOf[msg.sender][editionId]++;

        emit FreeMintClaimed(msg.sender, editionId);
        emit TransferSingle(msg.sender, address(0), msg.sender, editionId, 1);
    }

    // ┌─────────────────────────┐
    // │   Edition Management    │
    // └─────────────────────────┘

    /**
     * @notice Add a new edition
     * @param pieceTitle Title of the piece
     * @param basePrice Base price (for fixed) or starting price (for dynamic)
     * @param supply Supply limit (0 = unlimited)
     * @param metadataURI Metadata URI for the edition
     * @param pricingModel Pricing model (UNLIMITED, LIMITED_FIXED, LIMITED_DYNAMIC)
     * @param priceIncreaseRate Price increase rate in basis points (for dynamic pricing)
     */
    function addEdition(
        string memory pieceTitle,
        uint256 basePrice,
        uint256 supply,
        string memory metadataURI,
        PricingModel pricingModel,
        uint256 priceIncreaseRate,
        uint256 openTime           // NEW: Unix timestamp; 0 = open immediately
    ) external {
        if (msg.sender == owner()) {
            // Owner always allowed
        } else if (msg.sender == factory && agentDelegationEnabled) {
            // Factory forwarding agent call, delegation is on
        } else {
            revert Unauthorized();
        }
        if (bytes(pieceTitle).length == 0) revert InvalidTitle();
        if (basePrice == 0) revert InvalidPrice();

        if (pricingModel == PricingModel.UNLIMITED) {
            if (supply != 0) revert UnlimitedMustHaveZeroSupply();
        } else {
            if (supply == 0) revert LimitedMustHavePositiveSupply();
        }

        if (pricingModel == PricingModel.LIMITED_DYNAMIC) {
            if (priceIncreaseRate == 0) revert DynamicPricingRequiresIncreaseRate();
        }

        if (nextEditionId > type(uint32).max) revert EditionLimitReached();

        uint256 editionId = nextEditionId++;
        editions[editionId] = Edition({
            id: editionId,
            pieceTitle: pieceTitle,
            basePrice: basePrice,
            supply: supply,
            minted: 0,
            metadataURI: metadataURI,
            pricingModel: pricingModel,
            priceIncreaseRate: priceIncreaseRate,
            openTime: openTime      // NEW
        });

        emit EditionAdded(editionId, pieceTitle, basePrice, supply, pricingModel);
    }

    /**
     * @notice Update edition metadata
     * @param editionId Edition ID
     * @param metadataURI New metadata URI
     */
    function updateEditionMetadata(uint256 editionId, string memory metadataURI) external {
        if (msg.sender != owner()) revert Unauthorized();
        if (editions[editionId].id == 0) revert EditionNotFound();

        editions[editionId].metadataURI = metadataURI;
        emit EditionMetadataUpdated(editionId, metadataURI);
    }

    /**
     * @notice Get global message registry address (public getter for frontend)
     * @return Address of the GlobalMessageRegistry contract
     */
    function getGlobalMessageRegistry() external view returns (address) {
        return address(globalMessageRegistry);
    }

    // ┌─────────────────────────┐
    // │   Pricing Functions    │
    // └─────────────────────────┘

    /**
     * @notice Get current price for an edition
     * @param editionId Edition ID
     * @return price Current price for the next mint
     */
    function getCurrentPrice(uint256 editionId) public view returns (uint256 price) {
        Edition storage edition = editions[editionId];
        if (edition.id == 0) revert EditionNotFound();

        if (edition.pricingModel == PricingModel.UNLIMITED || edition.pricingModel == PricingModel.LIMITED_FIXED) {
            return edition.basePrice;
        } else {
            // LIMITED_DYNAMIC
            return EditionPricing.calculateDynamicPrice(
                edition.basePrice,
                edition.priceIncreaseRate,
                edition.minted
            );
        }
    }

    /**
     * @notice Calculate total cost for minting multiple tokens
     * @param editionId Edition ID
     * @param amount Number of tokens to mint
     * @return totalCost Total cost for minting the amount
     */
    function calculateMintCost(uint256 editionId, uint256 amount) public view returns (uint256 totalCost) {
        Edition storage edition = editions[editionId];
        if (edition.id == 0) revert EditionNotFound();
        if (amount == 0) revert AmountMustBePositive();

        if (edition.pricingModel == PricingModel.UNLIMITED || edition.pricingModel == PricingModel.LIMITED_FIXED) {
            return edition.basePrice * amount;
        } else {
            // LIMITED_DYNAMIC
            return EditionPricing.calculateBatchCost(
                edition.basePrice,
                edition.priceIncreaseRate,
                edition.minted,
                amount
            );
        }
    }

    // ┌─────────────────────────┐
    // │    Minting Functions    │
    // └─────────────────────────┘

    /**
     * @notice Mint tokens with optional message
     * @param editionId Edition ID
     * @param amount Number of tokens to mint
     * @param messageData Optional encoded message data (empty bytes skips registry call, saves gas)
     * @param maxCost Maximum acceptable total cost (0 = no limit, uses msg.value as implicit cap)
     */
    // slither-disable-next-line reentrancy-benign,reentrancy-no-eth,timestamp,unused-return
    function mint(
        uint256 editionId,
        uint256 amount,
        bytes32 gatingData,        // NEW: password hash (bytes32(0) = open tier)
        bytes calldata messageData,
        uint256 maxCost
    ) external payable nonReentrant {
        Edition storage edition = editions[editionId];
        if (edition.id == 0) revert EditionNotFound();
        if (amount == 0) revert AmountMustBePositive();

        // Time gate check
        if (edition.openTime != 0) {
            if (block.timestamp < edition.openTime) revert EditionNotOpen();
        }

        // Gating check — forwards edition's openTime as the time reference
        if (address(gatingModule) != address(0)) {
            bytes memory encoded = abi.encode(gatingData, edition.openTime);
            (bool allowed,) = gatingModule.canMint(msg.sender, amount, encoded);
            if (!allowed) revert GatingCheckFailed();
            gatingModule.onMint(msg.sender, amount);
        }

        // Check supply limits
        if (edition.pricingModel != PricingModel.UNLIMITED) {
            if (edition.minted + amount > edition.supply) revert ExceedsSupply();
        }

        // Calculate cost
        uint256 totalCost = calculateMintCost(editionId, amount);
        if (maxCost != 0 && totalCost > maxCost) revert ExceedsMaxCost();
        if (msg.value < totalCost) revert InsufficientPayment();

        // Update edition state
        edition.minted += amount;
        balanceOf[msg.sender][editionId] += amount;
        totalProceeds += totalCost;

        // Forward message to global registry
        if (messageData.length > 0) {
            globalMessageRegistry.postForAction(msg.sender, address(this), messageData);
        }

        // Refund excess
        if (msg.value > totalCost) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - totalCost);
        }

        emit TransferSingle(msg.sender, address(0), msg.sender, editionId, amount);
        emit Minted(msg.sender, editionId, amount, totalCost);
    }

    // ┌─────────────────────────┐
    // │   Withdraw Functions    │
    // └─────────────────────────┘

    /**
     * @notice Withdraw proceeds (1% protocol, 19% vault, 80% artist)
     * @dev Applies 1/19/80 split: protocol treasury, alignment vault, artist
     * @param amount Amount to withdraw
     */
    function withdraw(uint256 amount) external nonReentrant {
        if (msg.sender != owner()) revert Unauthorized();
        if (amount == 0) revert AmountMustBePositive();
        if (amount > address(this).balance) revert InsufficientBalance();

        // 1/19/80 split
        RevenueSplitLib.Split memory s = RevenueSplitLib.split(amount);

        // Protocol cut to treasury
        if (s.protocolCut > 0 && protocolTreasury != address(0)) {
            SafeTransferLib.safeTransferETH(protocolTreasury, s.protocolCut);
        }

        // Vault cut — tracks this instance as benefactor
        vault.receiveContribution{value: s.vaultCut}(Currency.wrap(address(0)), s.vaultCut, address(this));

        // Transfer remainder to artist
        SafeTransferLib.safeTransferETH(owner(), s.remainder);

        emit Withdrawn(owner(), s.remainder, s.vaultCut, s.protocolCut);
    }

    /**
     * @notice Get total proceeds collected
     * @return Total proceeds in wei
     */
    function getTotalProceeds() external view returns (uint256) {
        return totalProceeds;
    }

    /**
     * @notice Claim accumulated vault fees on behalf of this project and distribute to creator
     * @dev Only callable by the project creator
     *      This instance was registered as the benefactor when tithes were sent to the vault
     *      The creator calls this to claim fees and keep the rewards
     * @dev Fee claiming uses intentional "dragnet" pattern. Vault contributions
     *      (via withdraw tithe) go to pendingETH and only convert to benefactorShares
     *      when convertAndAddLiquidity() is called. Creators must wait for conversion
     *      before claiming fees. Frontend handles dragnet activation to ensure
     *      contributions are included in conversions.
     * @return totalClaimed Amount of ETH claimed from vault
     */
    function claimVaultFees() external onlyOwner nonReentrant returns (uint256 totalClaimed) {
        // Call vault's claimFees, which uses msg.sender (this contract) as the benefactor
        totalClaimed = vault.claimFees();

        // Route all claimed fees to the owner
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
    // slither-disable-next-line calls-loop,unused-return
    function claimAllFees() external onlyOwner {
        address[] memory allVaults = masterRegistry.getInstanceVaults(address(this));
        for (uint256 i = 0; i < allVaults.length; i++) {
            IAlignmentVault(payable(allVaults[i])).claimFees();
        }
    }

    // ┌─────────────────────────┐
    // │   ERC1155 Functions    │
    // └─────────────────────────┘

    /**
     * @notice Transfer tokens
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) external {
        if (from != msg.sender && !isApprovedForAll[from][msg.sender]) revert Unauthorized();
        if (balanceOf[from][id] < amount) revert InsufficientBalance();

        balanceOf[from][id] -= amount;
        balanceOf[to][id] += amount;

        emit TransferSingle(msg.sender, from, to, id, amount);

        /// @dev ERC1155 compliance: Check if recipient is a contract and call receiver hook
        _doSafeTransferAcceptanceCheck(msg.sender, from, to, id, amount, data);
    }

    /**
     * @notice Batch transfer tokens
     */
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) external {
        if (from != msg.sender && !isApprovedForAll[from][msg.sender]) revert Unauthorized();
        if (ids.length != amounts.length) revert LengthMismatch();

        for (uint256 i = 0; i < ids.length; i++) {
            if (balanceOf[from][ids[i]] < amounts[i]) revert InsufficientBalance();
            balanceOf[from][ids[i]] -= amounts[i];
            balanceOf[to][ids[i]] += amounts[i];
        }

        emit TransferBatch(msg.sender, from, to, ids, amounts);

        /// @dev ERC1155 compliance: Check if recipient is a contract and call receiver hook
        _doSafeBatchTransferAcceptanceCheck(msg.sender, from, to, ids, amounts, data);
    }

    /**
     * @notice Set approval for all
     */
    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    /**
     * @notice Get balance of multiple tokens for an account
     */
    function balanceOfBatch(address account, uint256[] memory ids) external view returns (uint256[] memory balances) {
        balances = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            balances[i] = balanceOf[account][ids[i]];
        }
    }

    // ┌─────────────────────────┐
    // │   Metadata Functions    │
    // └─────────────────────────┘

    /// @notice Returns data needed for project card display
    /// @dev Implements IInstance interface for QueryAggregator compatibility
    ///      Iterates all editions to compute aggregate values
    /// @return floorPrice Lowest base price across all editions
    /// @return totalMinted Sum of minted counts across all editions
    /// @return maxSupply Sum of limited supplies (0 if any edition is unlimited)
    /// @return isActive True if any edition has remaining supply
    /// @return extraData Reserved for future use (empty for now)
    function getCardData() external view returns (
        uint256 floorPrice,
        uint256 totalMinted,
        uint256 maxSupply,
        bool isActive,
        bytes memory extraData
    ) {
        uint256 editionCount = nextEditionId - 1;

        // Handle no editions case
        if (editionCount == 0) {
            return (0, 0, 0, false, "");
        }

        floorPrice = type(uint256).max;
        totalMinted = 0;
        maxSupply = 0;
        isActive = false;
        bool hasUnlimited = false;

        for (uint256 i = 1; i <= editionCount; i++) {
            Edition storage ed = editions[i];

            // Track lowest price
            if (ed.basePrice < floorPrice) {
                floorPrice = ed.basePrice;
            }

            // Sum minted
            totalMinted += ed.minted;

            // Track supply
            if (ed.supply == 0) {
                hasUnlimited = true;
            } else {
                maxSupply += ed.supply;
                if (ed.minted < ed.supply) {
                    isActive = true;
                }
            }
        }

        // Handle unlimited editions
        if (hasUnlimited) {
            maxSupply = 0; // 0 signals unlimited
            isActive = true;
        }

        // Handle edge case where floorPrice wasn't set
        if (floorPrice == type(uint256).max) {
            floorPrice = 0;
        }

        extraData = "";
    }

    /**
     * @notice Get edition metadata
     * @param editionId Edition ID
     * @return id Edition ID
     * @return pieceTitle Title of the piece
     * @return basePrice Base price
     * @return currentPrice Current price for next mint
     * @return supply Supply limit (0 = unlimited)
     * @return minted Number minted
     * @return metadataURI Metadata URI
     * @return pricingModel Pricing model
     * @return priceIncreaseRate Price increase rate (for dynamic)
     */
    function getEditionMetadata(uint256 editionId) external view returns (
        uint256 id,
        string memory pieceTitle,
        uint256 basePrice,
        uint256 currentPrice,
        uint256 supply,
        uint256 minted,
        string memory metadataURI,
        PricingModel pricingModel,
        uint256 priceIncreaseRate
    ) {
        Edition storage edition = editions[editionId];
        if (edition.id == 0) revert EditionNotFound();
        
        return (
            edition.id,
            edition.pieceTitle,
            edition.basePrice,
            getCurrentPrice(editionId),
            edition.supply,
            edition.minted,
            edition.metadataURI,
            edition.pricingModel,
            edition.priceIncreaseRate
        );
    }

    /**
     * @notice Get all edition IDs
     * @return editionIds Array of all edition IDs
     */
    function getAllEditionIds() external view returns (uint256[] memory editionIds) {
        uint256 count = nextEditionId - 1;
        editionIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            editionIds[i] = i + 1;
        }
    }

    /**
     * @notice Get edition count
     * @return count Total number of editions
     */
    function getEditionCount() external view returns (uint256 count) {
        return nextEditionId - 1;
    }

    /**
     * @notice Get batch of edition metadata
     * @param startId Starting edition ID (1-indexed)
     * @param endId Ending edition ID (inclusive, 1-indexed)
     * @return ids Array of edition IDs
     * @return pieceTitles Array of piece titles
     * @return basePrices Array of base prices
     * @return currentPrices Array of current prices
     * @return supplies Array of supplies
     * @return mintedCounts Array of minted counts
     * @return metadataURIs Array of metadata URIs
     * @return pricingModels Array of pricing models
     * @return priceIncreaseRates Array of price increase rates
     */
    function getEditionsBatch(
        uint256 startId,
        uint256 endId
    ) external view returns (
        uint256[] memory ids,
        string[] memory pieceTitles,
        uint256[] memory basePrices,
        uint256[] memory currentPrices,
        uint256[] memory supplies,
        uint256[] memory mintedCounts,
        string[] memory metadataURIs,
        PricingModel[] memory pricingModels,
        uint256[] memory priceIncreaseRates
    ) {
        if (startId == 0 || startId > nextEditionId - 1) revert InvalidEditionRange();
        if (endId < startId || endId > nextEditionId - 1) revert InvalidEditionRange();
        
        uint256 size = endId - startId + 1;
        ids = new uint256[](size);
        pieceTitles = new string[](size);
        basePrices = new uint256[](size);
        currentPrices = new uint256[](size);
        supplies = new uint256[](size);
        mintedCounts = new uint256[](size);
        metadataURIs = new string[](size);
        pricingModels = new PricingModel[](size);
        priceIncreaseRates = new uint256[](size);
        
        for (uint256 i = 0; i < size; i++) {
            uint256 editionId = startId + i;
            Edition storage edition = editions[editionId];
            
            ids[i] = edition.id;
            pieceTitles[i] = edition.pieceTitle;
            basePrices[i] = edition.basePrice;
            currentPrices[i] = getCurrentPrice(editionId);
            supplies[i] = edition.supply;
            mintedCounts[i] = edition.minted;
            metadataURIs[i] = edition.metadataURI;
            pricingModels[i] = edition.pricingModel;
            priceIncreaseRates[i] = edition.priceIncreaseRate;
        }
    }

    /**
     * @notice Get instance metadata
     * @return instanceName Collection name
     * @return instanceCreator Creator address
     * @return instanceFactory Factory address
     * @return instanceVault Vault address
     * @return totalEditions Total number of editions
     * @return totalProceeds Total proceeds collected
     * @return contractBalance Current contract balance
     * @return instanceStyleUri Style URI for customization
     */
    function getInstanceMetadata() external view returns (
        string memory instanceName,
        address instanceCreator,
        address instanceFactory,
        address instanceVault,
        uint256 totalEditions,
        // slither-disable-next-line shadowing-local
        uint256 totalProceeds,
        uint256 contractBalance,
        string memory instanceStyleUri
    ) {
        return (
            name,
            creator,
            factory,
            address(vault),
            nextEditionId - 1,
            totalProceeds,
            address(this).balance,
            styleUri
        );
    }

    /**
     * @notice Get pricing information for an edition
     * @param editionId Edition ID
     * @return basePrice Base price
     * @return currentPrice Current price for next mint
     * @return pricingModel Pricing model
     * @return priceIncreaseRate Price increase rate (for dynamic)
     * @return minted Number minted
     * @return supply Supply limit (0 = unlimited)
     * @return available Available mints remaining (type(uint256).max if unlimited)
     */
    function getPricingInfo(uint256 editionId) external view returns (
        uint256 basePrice,
        uint256 currentPrice,
        PricingModel pricingModel,
        uint256 priceIncreaseRate,
        uint256 minted,
        uint256 supply,
        uint256 available
    ) {
        Edition storage edition = editions[editionId];
        if (edition.id == 0) revert EditionNotFound();
        
        basePrice = edition.basePrice;
        currentPrice = getCurrentPrice(editionId);
        pricingModel = edition.pricingModel;
        priceIncreaseRate = edition.priceIncreaseRate;
        minted = edition.minted;
        supply = edition.supply;
        available = supply == 0 ? type(uint256).max : (supply > minted ? supply - minted : 0);
    }

    /**
     * @notice Get mint statistics for an edition
     * @param editionId Edition ID
     * @return minted Number minted
     * @return supply Supply limit (0 = unlimited)
     * @return available Available mints remaining
     * @return isSoldOut Whether edition is sold out
     */
    function getMintStats(uint256 editionId) external view returns (
        uint256 minted,
        uint256 supply,
        uint256 available,
        bool isSoldOut
    ) {
        Edition storage edition = editions[editionId];
        if (edition.id == 0) revert EditionNotFound();
        
        minted = edition.minted;
        supply = edition.supply;
        
        if (supply == 0) {
            // Unlimited
            available = type(uint256).max;
            isSoldOut = false;
        } else {
            available = supply > minted ? supply - minted : 0;
            isSoldOut = minted >= supply;
        }
    }

    /**
     * @notice Check if edition exists
     * @param editionId Edition ID
     * @return exists Whether edition exists
     */
    function editionExists(uint256 editionId) external view returns (bool exists) {
        return editions[editionId].id != 0;
    }

    /**
     * @notice Get project/collection name
     * @return projectName The name of the project/collection
     * @dev This is the same as the public `name` variable, provided for clarity
     */
    function getProjectName() external view returns (string memory projectName) {
        return name;
    }

    /**
     * @notice Get piece title for an edition
     * @param editionId Edition ID
     * @return pieceTitle The title of the piece
     */
    function getPieceTitle(uint256 editionId) external view returns (string memory pieceTitle) {
        Edition storage edition = editions[editionId];
        if (edition.id == 0) revert EditionNotFound();
        return edition.pieceTitle;
    }

    /**
     * @notice Get full edition details
     * @param editionId Edition ID
     * @return Edition struct containing all edition details
     */
    function getEdition(uint256 editionId) external view returns (Edition memory) {
        Edition storage edition = editions[editionId];
        if (edition.id == 0) revert EditionNotFound();
        return edition;
    }

    // ┌─────────────────────────┐
    // │   Style Management      │
    // └─────────────────────────┘

    /**
     * @notice Set project-level styling (creator only)
     * @param uri Style URI (ipfs://, ar://, https://, or inline:css:... / inline:js:...)
     */
    function setStyle(string memory uri) external {
        if (msg.sender != owner()) revert Unauthorized();
        styleUri = uri;
    }

    /**
     * @notice Set edition-level styling (creator only)
     * @param editionId Edition ID
     * @param uri Style URI (overrides project-level)
     */
    function setEditionStyle(uint256 editionId, string memory uri) external {
        if (msg.sender != owner()) revert Unauthorized();
        if (editions[editionId].id == 0) revert EditionNotFound();
        editionStyleUri[editionId] = uri;
    }

    /**
     * @notice Get style URI for edition (returns edition style if set, else project style)
     * @param editionId Edition ID
     * @return uri Style URI
     */
    function getStyle(uint256 editionId) external view returns (string memory uri) {
        string memory editionStyle = editionStyleUri[editionId];
        return bytes(editionStyle).length > 0 ? editionStyle : styleUri;
    }

    // ┌─────────────────────────────────────┐
    // │   ERC1155 Receiver Safety Checks    │
    // └─────────────────────────────────────┘

    /**
     * @dev Internal function to invoke onERC1155Received on a target address
     * @param operator The address which initiated the transfer
     * @param from The address which previously owned the token
     * @param to The address which will own the token
     * @param id The token ID being transferred
     * @param amount The amount of tokens being transferred
     * @param data Additional data with no specified format
     */
    function _doSafeTransferAcceptanceCheck(
        address operator,
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) private {
        if (to.code.length > 0) {
            try IERC1155Receiver(to).onERC1155Received(operator, from, id, amount, data) returns (bytes4 response) {
                if (response != IERC1155Receiver.onERC1155Received.selector) {
                    revert ERC1155RejectedTokens();
                }
            } catch Error(string memory) {
                revert ERC1155RejectedTokens();
            } catch {
                revert ERC1155TransferToNonReceiver();
            }
        }
    }

    /**
     * @dev Internal function to invoke onERC1155BatchReceived on a target address
     * @param operator The address which initiated the batch transfer
     * @param from The address which previously owned the tokens
     * @param to The address which will own the tokens
     * @param ids Array of token IDs being transferred
     * @param amounts Array of amounts being transferred
     * @param data Additional data with no specified format
     */
    function _doSafeBatchTransferAcceptanceCheck(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) private {
        if (to.code.length > 0) {
            try IERC1155Receiver(to).onERC1155BatchReceived(operator, from, ids, amounts, data) returns (bytes4 response) {
                if (response != IERC1155Receiver.onERC1155BatchReceived.selector) {
                    revert ERC1155RejectedTokens();
                }
            } catch Error(string memory) {
                revert ERC1155RejectedTokens();
            } catch {
                revert ERC1155TransferToNonReceiver();
            }
        }
    }
}

/**
 * @title IERC1155Receiver
 * @dev Interface for contracts that want to support safe transfers from ERC1155 token contracts
 */
interface IERC1155Receiver {
    /**
     * @notice Handle the receipt of a single ERC1155 token type
     * @param operator The address which initiated the transfer
     * @param from The address which previously owned the token
     * @param id The ID of the token being transferred
     * @param value The amount of tokens being transferred
     * @param data Additional data with no specified format
     * @return bytes4 `bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"))`
     */
    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) external returns (bytes4);

    /**
     * @notice Handle the receipt of multiple ERC1155 token types
     * @param operator The address which initiated the batch transfer
     * @param from The address which previously owned the tokens
     * @param ids An array containing ids of each token being transferred
     * @param values An array containing amounts of each token being transferred
     * @param data Additional data with no specified format
     * @return bytes4 `bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"))`
     */
    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external returns (bytes4);
}

