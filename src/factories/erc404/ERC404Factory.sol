// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IMasterRegistry} from "../../master/interfaces/IMasterRegistry.sol";
import {FeatureUtils} from "../../master/libraries/FeatureUtils.sol";
import {UltraAlignmentVault} from "../../vaults/UltraAlignmentVault.sol";
import {ERC404BondingInstance} from "./ERC404BondingInstance.sol";

/**
 * @title ERC404Factory
 * @notice Factory contract for deploying ERC404 token instances with ultraalignment
 * @dev Requires vault to have its hook pre-configured (created via UltraAlignmentHookFactory.createVaultWithHook)
 */
contract ERC404Factory is Ownable, ReentrancyGuard {
    IMasterRegistry public masterRegistry;
    address public instanceTemplate;
    uint256 public instanceCreationFee;
    address public v4PoolManager;
    address public weth;

    // Feature matrix
    bytes32[] public features = [
        FeatureUtils.BONDING_CURVE,
        FeatureUtils.LIQUIDITY_POOL,
        FeatureUtils.CHAT,
        FeatureUtils.BALANCE_MINT,
        FeatureUtils.PORTFOLIO
    ];

    // Mapping from ERC404 instance to its vault
    mapping(address => address) public instanceToVault;
    // Mapping from ERC404 instance to its hook
    mapping(address => address) public instanceToHook;

    event InstanceCreated(
        address indexed instance,
        address indexed creator,
        string name,
        string symbol,
        address indexed vault,
        address hook
    );

    constructor(
        address _masterRegistry,
        address _instanceTemplate,
        address _v4PoolManager,
        address _weth
    ) {
        _initializeOwner(msg.sender);
        masterRegistry = IMasterRegistry(_masterRegistry);
        instanceTemplate = _instanceTemplate;
        v4PoolManager = _v4PoolManager;
        weth = _weth;
        instanceCreationFee = 0.01 ether;
    }

    /**
     * @notice Create a new ERC404 bonding instance with bonding curve and password-protected tiers
     * @dev Requires vault and hook to be created first via UltraAlignmentHookFactory
     * @param name Token name
     * @param symbol Token symbol
     * @param metadataURI Metadata URI
     * @param maxSupply Maximum token supply
     * @param liquidityReservePercent Percentage of supply reserved for liquidity (0-100)
     * @param curveParams Bonding curve parameters
     * @param tierConfig Tier configuration (password-protected tiers)
     * @param creator Creator address (will be owner)
     * @param vault Vault address for ultraalignment
     * @param hook Hook address (created via UltraAlignmentHookFactory.createHook)
     * @param styleUri Style URI (ipfs://, ar://, https://, or inline:css:/inline:js:)
     * @return instance Address of the created ERC404 instance
     */
    function createInstance(
        string memory name,
        string memory symbol,
        string memory metadataURI,
        uint256 maxSupply,
        uint256 liquidityReservePercent,
        ERC404BondingInstance.BondingCurveParams memory curveParams,
        ERC404BondingInstance.TierConfig memory tierConfig,
        address creator,
        address vault,
        address hook,
        string memory styleUri
    ) external payable nonReentrant returns (address instance) {
        require(msg.value >= instanceCreationFee, "Insufficient fee");
        require(bytes(name).length > 0, "Invalid name");
        require(bytes(symbol).length > 0, "Invalid symbol");
        require(maxSupply > 0, "Invalid supply");
        require(creator != address(0), "Invalid creator");
        require(v4PoolManager != address(0), "V4 pool manager not set");
        require(weth != address(0), "WETH not set");

        // Vault and hook are required for ultraalignment
        require(vault != address(0), "Vault required for ultraalignment");
        require(vault.code.length > 0, "Vault must be a contract");
        require(hook != address(0), "Hook required for ultraalignment");
        require(hook.code.length > 0, "Hook must be a contract");

        // Deploy new bonding instance WITH hook address (enforced alignment)
        instance = address(new ERC404BondingInstance(
            name,
            symbol,
            maxSupply,
            liquidityReservePercent,
            curveParams,
            tierConfig,
            v4PoolManager,
            hook, // Hook (mandatory for ultraalignment)
            weth,
            address(this),
            address(masterRegistry),
            creator,
            styleUri
        ));

        // Track instance mappings
        instanceToVault[instance] = vault;
        instanceToHook[instance] = hook;

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
        if (msg.value > instanceCreationFee) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - instanceCreationFee);
        }

        emit InstanceCreated(instance, creator, name, symbol, vault, hook);
    }

    /**
     * @notice Get vault address for an ERC404 instance
     * @param instance Address of the ERC404 instance
     * @return vault Address of the vault, or address(0) if none exists
     */
    function getVaultForInstance(address instance) external view returns (address vault) {
        return instanceToVault[instance];
    }

    /**
     * @notice Get hook address for an ERC404 instance
     * @param instance Address of the ERC404 instance
     * @return hook Address of the hook, or address(0) if none exists
     */
    function getHookForInstance(address instance) external view returns (address hook) {
        return instanceToHook[instance];
    }

    /**
     * @notice Get factory features
     */
    function getFeatures() external view returns (bytes32[] memory) {
        return features;
    }

    /**
     * @notice Set instance creation fee (owner only)
     */
    function setInstanceCreationFee(uint256 _fee) external onlyOwner {
        instanceCreationFee = _fee;
    }
}

/**
 * @title ERC404Instance
 * @notice Template ERC404 token instance
 * @dev Simplified implementation - full ERC404 would be more complex
 */
contract ERC404Instance {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    address public creator;
    address public factory;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(
        string memory _name,
        string memory _symbol,
        string memory /* metadataURI */,
        uint256 _initialSupply,
        address _creator,
        address _factory
    ) {
        name = _name;
        symbol = _symbol;
        creator = _creator;
        factory = _factory;
        totalSupply = _initialSupply;
        balanceOf[_creator] = _initialSupply;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }
}

