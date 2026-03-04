// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {UniAlignmentV4Hook} from "./UniAlignmentV4Hook.sol";
import {IAlignmentVault} from "../../../interfaces/IAlignmentVault.sol";

/**
 * @title UniAlignmentHookFactory
 * @notice Factory for deploying UniAlignment V4 hooks
 * @dev Hooks are deployed via CREATE2 for deterministic addresses required by Uniswap V4
 */
contract UniAlignmentHookFactory is Ownable, ReentrancyGuard {
    error InsufficientFee();
    error InvalidPoolManager();
    error InvalidVault();
    error InvalidWETH();
    error InvalidCreator();
    error InvalidFactory();
    error InvalidTemplate();

    address public hookTemplate;
    uint256 public hookCreationFee;

    mapping(address => bool) public authorizedFactories;
    mapping(address => address[]) public factoryHooks; // Factory -> hook instances

    event HookCreated(
        address indexed hook,
        address indexed poolManager,
        address indexed vault,
        address creator,
        uint256 hookFeeBips
    );

    event FactoryAuthorized(address indexed factory);
    event FactoryDeauthorized(address indexed factory);
    event HookCreationFeeUpdated(uint256 newFee);
    event HookTemplateUpdated(address indexed oldTemplate, address indexed newTemplate);

    // slither-disable-next-line missing-zero-check
    constructor(address _hookTemplate) {
        _initializeOwner(msg.sender);
        hookTemplate = _hookTemplate;
        hookCreationFee = 0.001 ether;
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
    // slither-disable-next-line reentrancy-unlimited-gas
    function createHook(
        address poolManager,
        address vault,
        address wethAddr,
        address creator,
        bool isCanonical,
        bytes32 salt,
        uint256 hookFeeBips,
        uint24 initialLpFeeRate
    ) external payable nonReentrant returns (address hook) {
        if (msg.value < hookCreationFee) revert InsufficientFee();
        if (poolManager == address(0)) revert InvalidPoolManager();
        if (vault == address(0)) revert InvalidVault();
        if (wethAddr == address(0)) revert InvalidWETH();
        if (creator == address(0)) revert InvalidCreator();

        // Deploy new hook instance using CREATE2 for deterministic address
        // Hook owner is always the protocol (hook factory owner), not the artist
        hook = address(new UniAlignmentV4Hook{salt: salt}(
            IPoolManager(poolManager),
            IAlignmentVault(payable(vault)),
            wethAddr,
            owner(),
            hookFeeBips,
            initialLpFeeRate
        ));

        // Register hook (vault is trustless and doesn't require authorization)
        factoryHooks[msg.sender].push(hook);

        // Refund excess
        if (msg.value > hookCreationFee) {
            payable(msg.sender).transfer(msg.value - hookCreationFee);
        }

        emit HookCreated(hook, poolManager, vault, msg.sender, hookFeeBips);
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
        if (factory == address(0)) revert InvalidFactory();
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
        emit HookCreationFeeUpdated(_fee);
    }

    /**
     * @notice Set hook template address (owner only)
     * @param _template New template address
     */
    function setHookTemplate(address _template) external onlyOwner {
        if (_template == address(0)) revert InvalidTemplate();
        address oldTemplate = hookTemplate;
        hookTemplate = _template;
        emit HookTemplateUpdated(oldTemplate, _template);
    }
}

