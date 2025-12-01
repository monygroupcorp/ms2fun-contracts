// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {UltraAlignmentV4Hook} from "./UltraAlignmentV4Hook.sol";
import {UltraAlignmentVault} from "../../../vaults/UltraAlignmentVault.sol";

/**
 * @title UltraAlignmentHookFactory
 * @notice Factory for deploying UltraAlignment hook instances
 * @dev Each hook instance can accumulate different tokens and payout to different vaults
 */
contract UltraAlignmentHookFactory is Ownable, ReentrancyGuard {
    address public hookTemplate;
    uint256 public hookCreationFee;
    address public weth; // WETH address for hook validation
    
    mapping(address => bool) public authorizedFactories;
    mapping(address => address[]) public factoryHooks; // Factory -> hook instances

    event HookCreated(
        address indexed hook,
        address indexed poolManager,
        address indexed vault,
        address creator
    );

    event FactoryAuthorized(address indexed factory);
    event FactoryDeauthorized(address indexed factory);

    constructor(address _hookTemplate, address _weth) {
        _initializeOwner(msg.sender);
        hookTemplate = _hookTemplate;
        weth = _weth;
        hookCreationFee = 0.001 ether;
    }

    /**
     * @notice Create a new hook instance for a Uniswap v4 pool
     * @param poolManager Address of the Uniswap v4 PoolManager
     * @param vault Address of the vault to receive accumulated tokens
     * @param wethAddr Address of WETH for validation
     * @param creator Address of the hook creator/owner
     * @param isCanonical Whether this is a canonical vault hook (true) or independent hook (false)
     * @return hook Address of the created hook instance
     */
    function createHook(
        address poolManager,
        address vault,
        address wethAddr,
        address creator,
        bool isCanonical
    ) external payable nonReentrant returns (address hook) {
        require(msg.value >= hookCreationFee, "Insufficient fee");
        require(poolManager != address(0), "Invalid pool manager");
        require(vault != address(0), "Invalid vault");
        require(wethAddr != address(0), "Invalid WETH");
        require(creator != address(0), "Invalid creator");

        // Deploy new hook instance
        hook = address(new UltraAlignmentV4Hook(
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
     * @notice Set hook template address (owner only)
     * @param _template New template address
     */
    function setHookTemplate(address _template) external onlyOwner {
        require(_template != address(0), "Invalid template");
        hookTemplate = _template;
    }
}

