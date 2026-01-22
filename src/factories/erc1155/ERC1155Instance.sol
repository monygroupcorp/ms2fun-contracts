// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "solady/auth/Ownable.sol";
import { ReentrancyGuard } from "solady/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { EditionPricing } from "./libraries/EditionPricing.sol";
import { UltraAlignmentVault } from "../../vaults/UltraAlignmentVault.sol";
import { GlobalMessageRegistry } from "../../registry/GlobalMessageRegistry.sol";
import { GlobalMessagePacking } from "../../libraries/GlobalMessagePacking.sol";
import { GlobalMessageTypes } from "../../libraries/GlobalMessageTypes.sol";
import { IMasterRegistry } from "../../master/interfaces/IMasterRegistry.sol";

/**
 * @title ERC1155Instance
 * @notice ERC1155 token instance for open edition artists
 * @dev Supports unlimited/limited editions with fixed or dynamic pricing, message system, and withdraw tax
 */
contract ERC1155Instance is Ownable, ReentrancyGuard {
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
    }

    // ┌─────────────────────────┐
    // │      State Variables     │
    // └─────────────────────────┘

    string public name;
    address public creator;
    address public factory;
    UltraAlignmentVault public vault;
    IMasterRegistry public immutable masterRegistry;
    GlobalMessageRegistry private cachedGlobalRegistry; // Lazy-loaded from masterRegistry

    // Customization
    string public styleUri;
    mapping(uint256 => string) public editionStyleUri;

    mapping(uint256 => Edition) public editions;
    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

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
        uint256 amount,
        uint256 taxAmount
    );

    event EditionMetadataUpdated(uint256 indexed editionId, string metadataURI);

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
        address _masterRegistry
    ) {
        require(bytes(_name).length > 0, "Invalid name");
        require(_creator != address(0), "Invalid creator");
        require(_factory != address(0), "Invalid factory");
        require(_vault != address(0), "Invalid vault");
        require(_masterRegistry != address(0), "Invalid master registry");

        _initializeOwner(_creator);
        name = _name;
        creator = _creator;
        factory = _factory;
        vault = UltraAlignmentVault(payable(_vault));
        masterRegistry = IMasterRegistry(_masterRegistry);
        styleUri = _styleUri;
        nextEditionId = 1;
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
        uint256 priceIncreaseRate
    ) external {
        require(msg.sender == factory || msg.sender == owner(), "Not authorized");
        require(bytes(pieceTitle).length > 0, "Invalid title");
        require(basePrice > 0, "Invalid price");
        
        if (pricingModel == PricingModel.UNLIMITED) {
            require(supply == 0, "Unlimited must have supply 0");
        } else {
            require(supply > 0, "Limited must have supply > 0");
        }

        if (pricingModel == PricingModel.LIMITED_DYNAMIC) {
            require(priceIncreaseRate > 0, "Dynamic pricing requires increase rate");
        }

        /// @dev Edition ID bounds check for GlobalMessagePacking compatibility
        /// GlobalMessagePacking requires editionId to fit in uint32 for efficient packing
        require(nextEditionId <= type(uint32).max, "Edition limit reached (max 4.29 billion)");

        uint256 editionId = nextEditionId++;
        editions[editionId] = Edition({
            id: editionId,
            pieceTitle: pieceTitle,
            basePrice: basePrice,
            supply: supply,
            minted: 0,
            metadataURI: metadataURI,
            pricingModel: pricingModel,
            priceIncreaseRate: priceIncreaseRate
        });

        emit EditionAdded(editionId, pieceTitle, basePrice, supply, pricingModel);
    }

    /**
     * @notice Update edition metadata
     * @param editionId Edition ID
     * @param metadataURI New metadata URI
     */
    function updateEditionMetadata(uint256 editionId, string memory metadataURI) external {
        require(msg.sender == owner(), "Not owner");
        require(editions[editionId].id != 0, "Edition not found");

        editions[editionId].metadataURI = metadataURI;
        emit EditionMetadataUpdated(editionId, metadataURI);
    }

    // ┌─────────────────────────┐
    // │  Global Message Helpers │
    // └─────────────────────────┘

    /**
     * @notice Internal helper to lazy-load global message registry
     * @dev Caches registry address to avoid repeated external calls
     * @return GlobalMessageRegistry instance
     */
    function _getGlobalMessageRegistry() private returns (GlobalMessageRegistry) {
        if (address(cachedGlobalRegistry) == address(0)) {
            address registryAddr = masterRegistry.getGlobalMessageRegistry();
            require(registryAddr != address(0), "Global registry not set");
            cachedGlobalRegistry = GlobalMessageRegistry(registryAddr);
        }
        return cachedGlobalRegistry;
    }

    /**
     * @notice Get global message registry address (public getter for frontend)
     * @return Address of the GlobalMessageRegistry contract
     */
    function getGlobalMessageRegistry() external view returns (address) {
        return masterRegistry.getGlobalMessageRegistry();
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
        require(edition.id != 0, "Edition not found");

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
        require(edition.id != 0, "Edition not found");
        require(amount > 0, "Invalid amount");

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
     * @param message Optional message to store (empty string skips registry call, saves gas)
     */
    function mint(
        uint256 editionId,
        uint256 amount,
        string calldata message
    ) external payable nonReentrant {
        Edition storage edition = editions[editionId];
        require(edition.id != 0, "Edition not found");
        require(amount > 0, "Invalid amount");

        // Check supply limits
        if (edition.pricingModel != PricingModel.UNLIMITED) {
            require(edition.minted + amount <= edition.supply, "Exceeds supply");
        }

        // Calculate cost
        uint256 totalCost = calculateMintCost(editionId, amount);
        require(msg.value >= totalCost, "Insufficient payment");

        // Update edition state
        edition.minted += amount;
        balanceOf[msg.sender][editionId] += amount;
        totalProceeds += totalCost;

        // Store message in global registry if provided
        if (bytes(message).length > 0) {
            GlobalMessageRegistry registry = _getGlobalMessageRegistry();

            require(editionId <= type(uint32).max, "EditionId too large");
            require(amount <= type(uint96).max, "Amount too large");

            uint256 packedData = GlobalMessagePacking.pack(
                uint32(block.timestamp),
                GlobalMessageTypes.FACTORY_ERC1155,
                GlobalMessageTypes.ACTION_MINT,
                uint32(editionId), // contextId: edition being minted
                uint96(amount)
            );

            registry.addMessage(address(this), msg.sender, packedData, message);
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
     * @notice Withdraw proceeds (20% tithe to vault)
     * @dev Sends 20% tithe to vault for alignment target conversion and project tracking
     * @param amount Amount to withdraw
     */
    function withdraw(uint256 amount) external nonReentrant {
        require(msg.sender == owner(), "Not owner");
        require(amount > 0, "Invalid amount");
        require(amount <= address(this).balance, "Insufficient balance");

        // Calculate tithe (20%)
        uint256 taxAmount = (amount * 20) / 100;
        uint256 ownerAmount = amount - taxAmount;

        // Send tithe to vault (via receive fallback)
        // Vault will accumulate fees and track this instance as the benefactor
        SafeTransferLib.safeTransferETH(address(vault), taxAmount);

        // Transfer remainder to owner
        SafeTransferLib.safeTransferETH(owner(), ownerAmount);

        emit Withdrawn(owner(), ownerAmount, taxAmount);
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
        require(totalClaimed > 0, "No fees to claim");
        SafeTransferLib.safeTransferETH(owner(), totalClaimed);
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
        require(
            from == msg.sender || isApprovedForAll[from][msg.sender],
            "Not authorized"
        );
        require(balanceOf[from][id] >= amount, "Insufficient balance");

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
        require(
            from == msg.sender || isApprovedForAll[from][msg.sender],
            "Not authorized"
        );
        require(ids.length == amounts.length, "Length mismatch");

        for (uint256 i = 0; i < ids.length; i++) {
            require(balanceOf[from][ids[i]] >= amounts[i], "Insufficient balance");
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
        require(edition.id != 0, "Edition not found");
        
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
        require(startId > 0 && startId <= nextEditionId - 1, "Invalid start ID");
        require(endId >= startId && endId <= nextEditionId - 1, "Invalid end ID");
        
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
        require(edition.id != 0, "Edition not found");
        
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
        require(edition.id != 0, "Edition not found");
        
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
        require(edition.id != 0, "Edition not found");
        return edition.pieceTitle;
    }

    /**
     * @notice Get full edition details
     * @param editionId Edition ID
     * @return Edition struct containing all edition details
     */
    function getEdition(uint256 editionId) external view returns (Edition memory) {
        Edition storage edition = editions[editionId];
        require(edition.id != 0, "Edition not found");
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
        require(msg.sender == owner(), "Not owner");
        styleUri = uri;
    }

    /**
     * @notice Set edition-level styling (creator only)
     * @param editionId Edition ID
     * @param uri Style URI (overrides project-level)
     */
    function setEditionStyle(uint256 editionId, string memory uri) external {
        require(msg.sender == owner(), "Not owner");
        require(editions[editionId].id != 0, "Edition not found");
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
                    revert("ERC1155: rejected tokens");
                }
            } catch Error(string memory reason) {
                revert(reason);
            } catch {
                revert("ERC1155: transfer to non-receiver");
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
                    revert("ERC1155: rejected tokens");
                }
            } catch Error(string memory reason) {
                revert(reason);
            } catch {
                revert("ERC1155: transfer to non-receiver");
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

