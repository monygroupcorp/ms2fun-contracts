// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {UltraAlignmentV4Hook} from "./UltraAlignmentV4Hook.sol";
import {UltraAlignmentVault} from "../../../vaults/UltraAlignmentVault.sol";

/**
 * @title UltraAlignmentHookFactory
 * @notice Factory for deploying UltraAlignment vaults and hooks together
 * @dev Enforces vault+hook creation as atomic operation for ultraalignment protocol
 */
contract UltraAlignmentHookFactory is Ownable, ReentrancyGuard {
    address public hookTemplate;
    uint256 public hookCreationFee;
    uint256 public vaultCreationFee;
    address public weth;
    address public poolManager;
    address public v3Router;
    address public v2Router;
    address public v2Factory;
    address public v3Factory;

    mapping(address => bool) public authorizedFactories;
    mapping(address => address[]) public factoryHooks; // Factory -> hook instances
    mapping(address => address) public vaultToHook; // Vault -> associated hook
    mapping(address => address) public hookToVault; // Hook -> associated vault

    event HookCreated(
        address indexed hook,
        address indexed poolManager,
        address indexed vault,
        address creator
    );

    event VaultWithHookCreated(
        address indexed vault,
        address indexed hook,
        address indexed creator,
        address alignmentToken
    );

    event FactoryAuthorized(address indexed factory);
    event FactoryDeauthorized(address indexed factory);

    constructor(
        address _hookTemplate,
        address _weth,
        address _poolManager,
        address _v3Router,
        address _v2Router,
        address _v2Factory,
        address _v3Factory
    ) {
        _initializeOwner(msg.sender);
        hookTemplate = _hookTemplate;
        weth = _weth;
        poolManager = _poolManager;
        v3Router = _v3Router;
        v2Router = _v2Router;
        v2Factory = _v2Factory;
        v3Factory = _v3Factory;
        hookCreationFee = 0.001 ether;
        vaultCreationFee = 0.01 ether;
    }

    /**
     * @notice Create a new hook instance for a Uniswap v4 pool
     * @param poolManager Address of the Uniswap v4 PoolManager
     * @param vault Address of the vault to receive accumulated tokens
     * @param wethAddr Address of WETH for validation
     * @param creator Address of the hook creator/owner
     * @param isCanonical Whether this is a canonical vault hook (true) or independent hook (false)
     * @param salt Salt for CREATE2 deployment (frontend computes valid salt for hook permissions)
     * @return hook Address of the created hook instance
     */
    function createHook(
        address poolManager,
        address vault,
        address wethAddr,
        address creator,
        bool isCanonical,
        bytes32 salt
    ) external payable nonReentrant returns (address hook) {
        require(msg.value >= hookCreationFee, "Insufficient fee");
        require(poolManager != address(0), "Invalid pool manager");
        require(vault != address(0), "Invalid vault");
        require(wethAddr != address(0), "Invalid WETH");
        require(creator != address(0), "Invalid creator");

        // Deploy new hook instance using CREATE2 for deterministic address
        hook = address(new UltraAlignmentV4Hook{salt: salt}(
            IPoolManager(poolManager),
            UltraAlignmentVault(payable(vault)),
            wethAddr,
            creator
        ));

        // Register hook (vault is trustless and doesn't require authorization)
        factoryHooks[msg.sender].push(hook);

        // Refund excess
        if (msg.value > hookCreationFee) {
            payable(msg.sender).transfer(msg.value - hookCreationFee);
        }

        emit HookCreated(hook, poolManager, vault, msg.sender);
    }

    /**
     * @notice Create a new vault with its associated hook atomically
     * @dev This is the preferred method for ultraalignment - ensures vault+hook are created together
     * @param alignmentToken Token that the vault will accumulate and LP with
     * @param creator Address of the vault creator (will receive ownership)
     * @param hookSalt Salt for CREATE2 hook deployment (frontend computes valid salt for hook permissions)
     * @return vault Address of the created vault
     * @return hook Address of the created hook
     */
    function createVaultWithHook(
        address alignmentToken,
        address creator,
        bytes32 hookSalt
    ) external payable nonReentrant returns (address vault, address hook) {
        uint256 totalFee = vaultCreationFee + hookCreationFee;
        require(msg.value >= totalFee, "Insufficient fee");
        require(alignmentToken != address(0), "Invalid alignment token");
        require(creator != address(0), "Invalid creator");
        require(poolManager != address(0), "Pool manager not set");

        // Step 1: Deploy vault (factory is initial owner)
        vault = address(new UltraAlignmentVault(
            weth,
            poolManager,
            v3Router,
            v2Router,
            v2Factory,
            v3Factory,
            alignmentToken
        ));

        // Step 2: Deploy hook with vault address
        hook = address(new UltraAlignmentV4Hook{salt: hookSalt}(
            IPoolManager(poolManager),
            UltraAlignmentVault(payable(vault)),
            weth,
            creator
        ));

        // Step 3: Set hook in vault (factory is owner at this point)
        UltraAlignmentVault(payable(vault)).setHook(hook);

        // Step 4: Transfer vault ownership to creator
        UltraAlignmentVault(payable(vault)).transferOwnership(creator);

        // Track relationships
        vaultToHook[vault] = hook;
        hookToVault[hook] = vault;
        factoryHooks[msg.sender].push(hook);

        // Refund excess
        if (msg.value > totalFee) {
            payable(msg.sender).transfer(msg.value - totalFee);
        }

        emit VaultWithHookCreated(vault, hook, creator, alignmentToken);
    }

    /**
     * @notice Get the hook associated with a vault
     * @param vault Address of the vault
     * @return hook Address of the hook (address(0) if not found)
     */
    function getHookForVault(address vault) external view returns (address hook) {
        return vaultToHook[vault];
    }

    /**
     * @notice Get the vault associated with a hook
     * @param hook Address of the hook
     * @return vault Address of the vault (address(0) if not found)
     */
    function getVaultForHook(address hook) external view returns (address vault) {
        return hookToVault[hook];
    }

    /**
     * @notice Get all hooks created by a factory
     * @param factory Address of the factory
     * @return hooks Array of hook addresses
     */
    function getHooksByFactory(address factory) external view returns (address[] memory hooks) {
        return factoryHooks[factory];
    }

    /**
     * @notice Authorize a factory to create hooks (owner only)
     * @param factory Address of the factory to authorize
     */
    function authorizeFactory(address factory) external onlyOwner {
        require(factory != address(0), "Invalid factory");
        authorizedFactories[factory] = true;
        emit FactoryAuthorized(factory);
    }

    /**
     * @notice Deauthorize a factory (owner only)
     * @param factory Address of the factory to deauthorize
     */
    function deauthorizeFactory(address factory) external onlyOwner {
        authorizedFactories[factory] = false;
        emit FactoryDeauthorized(factory);
    }

    /**
     * @notice Set hook creation fee (owner only)
     * @param _fee New fee amount
     */
    function setHookCreationFee(uint256 _fee) external onlyOwner {
        hookCreationFee = _fee;
    }

    /**
     * @notice Set vault creation fee (owner only)
     * @param _fee New fee amount
     */
    function setVaultCreationFee(uint256 _fee) external onlyOwner {
        vaultCreationFee = _fee;
    }

    /**
     * @notice Set hook template address (owner only)
     * @param _template New template address
     */
    function setHookTemplate(address _template) external onlyOwner {
        require(_template != address(0), "Invalid template");
        hookTemplate = _template;
    }

    /**
     * @notice Get total fee for creating a vault with hook
     * @return Total fee in wei
     */
    function getVaultWithHookFee() external view returns (uint256) {
        return vaultCreationFee + hookCreationFee;
    }
}

