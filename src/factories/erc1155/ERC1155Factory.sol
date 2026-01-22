// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IMasterRegistry} from "../../master/interfaces/IMasterRegistry.sol";
import {ERC1155Instance} from "./ERC1155Instance.sol";
import {UltraAlignmentVault} from "../../vaults/UltraAlignmentVault.sol";

/**
 * @title ERC1155Factory
 * @notice Factory contract for deploying ERC1155 token instances for open edition artists
 */
contract ERC1155Factory is Ownable, ReentrancyGuard {
    IMasterRegistry public masterRegistry;
    address public instanceTemplate;
    uint256 public instanceCreationFee;

    // Mapping from instance to vault
    mapping(address => address) public instanceToVault;

    // Trusted agents that can add editions on behalf of users
    mapping(address => bool) public isAgent;

    event InstanceCreated(
        address indexed instance,
        address indexed creator,
        string name,
        address indexed vault
    );

    event EditionAdded(
        address indexed instance,
        uint256 indexed editionId,
        string pieceTitle,
        uint256 basePrice,
        uint256 supply,
        ERC1155Instance.PricingModel pricingModel
    );

    constructor(
        address _masterRegistry,
        address _instanceTemplate
    ) {
        _initializeOwner(msg.sender);
        masterRegistry = IMasterRegistry(_masterRegistry);
        instanceTemplate = _instanceTemplate;
        instanceCreationFee = 0.01 ether;
    }

    /**
     * @notice Create a new ERC1155 instance
     * @param name Collection name
     * @param metadataURI Base metadata URI
     * @param creator Creator address
     * @param vault UltraAlignmentVault address for tax collection
     * @param styleUri Style URI (ipfs://, ar://, https://, or inline:css:/inline:js:)
     * @return instance Address of the created instance
     */
    function createInstance(
        string memory name,
        string memory metadataURI,
        address creator,
        address vault,
        string memory styleUri
    ) external payable nonReentrant returns (address instance) {
        require(msg.value >= instanceCreationFee, "Insufficient fee");
        require(bytes(name).length > 0, "Invalid name");
        require(creator != address(0), "Invalid creator");
        require(vault != address(0), "Invalid vault");
        require(vault.code.length > 0, "Vault must be a contract");

        // Check namespace availability before deploying (saves gas on collision)
        require(!masterRegistry.isNameTaken(name), "Name already taken");

        // Deploy new instance
        instance = address(new ERC1155Instance(
            name,
            metadataURI,
            creator,
            address(this),
            vault,
            styleUri,
            address(masterRegistry)
        ));

        // Store vault mapping
        instanceToVault[instance] = vault;

        // Register with master registry (track vault usage)
        masterRegistry.registerInstance(
            instance,
            address(this),
            creator,
            name,
            metadataURI,
            vault // Pass vault for instance count tracking
        );

        // Refund excess
        require(msg.value >= instanceCreationFee, "Insufficient payment");
        if (msg.value > instanceCreationFee) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - instanceCreationFee);
        }

        emit InstanceCreated(instance, creator, name, vault);
    }

    /**
     * @notice Add an edition to an instance
     * @param instance Instance address
     * @param pieceTitle Title of the piece
     * @param basePrice Base price (for fixed) or starting price (for dynamic)
     * @param supply Supply limit (0 = unlimited)
     * @param metadataURI Metadata URI for the edition
     * @param pricingModel Pricing model (UNLIMITED, LIMITED_FIXED, LIMITED_DYNAMIC)
     * @param priceIncreaseRate Price increase rate in basis points (for dynamic pricing)
     * @return editionId The ID of the created edition
     */
    function addEdition(
        address instance,
        string memory pieceTitle,
        uint256 basePrice,
        uint256 supply,
        string memory metadataURI,
        ERC1155Instance.PricingModel pricingModel,
        uint256 priceIncreaseRate
    ) external returns (uint256 editionId) {
        require(isAgent[msg.sender], "Not authorized agent");
        ERC1155Instance instanceContract = ERC1155Instance(instance);

        // Call addEdition on instance
        instanceContract.addEdition(
            pieceTitle,
            basePrice,
            supply,
            metadataURI,
            pricingModel,
            priceIncreaseRate
        );

        // Get the edition ID (it's the nextEditionId - 1 after adding)
        editionId = instanceContract.nextEditionId() - 1;

        // Register edition metadata with master registry if needed
        // Note: Master registry may need to be updated to support edition-level metadata
        // For now, we emit the event which can be indexed off-chain

        emit EditionAdded(instance, editionId, pieceTitle, basePrice, supply, pricingModel);
    }

    /**
     * @notice Get vault address for an instance
     * @param instance Instance address
     * @return vault Vault address
     */
    function getVaultForInstance(address instance) external view returns (address vault) {
        return instanceToVault[instance];
    }

    /**
     * @notice Set instance creation fee (owner only)
     */
    function setInstanceCreationFee(uint256 _fee) external onlyOwner {
        instanceCreationFee = _fee;
    }

    /**
     * @notice Set agent authorization (owner only)
     * @param agent Address to authorize/deauthorize
     * @param authorized Whether the agent is authorized
     */
    function setAgent(address agent, bool authorized) external onlyOwner {
        isAgent[agent] = authorized;
    }
}
