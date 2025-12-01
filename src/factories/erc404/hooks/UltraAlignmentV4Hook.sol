// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BaseTestHooks} from "v4-core/test/BaseTestHooks.sol";
import {UltraAlignmentVault} from "../../../vaults/UltraAlignmentVault.sol";

/**
 * @title UltraAlignmentV4Hook
 * @notice Uniswap v4 hook that taxes swaps and sends taxes to alignment vault
 * @dev Taxes are sent directly to vault with project instance tracking for contribution metrics
 */
contract UltraAlignmentV4Hook is BaseTestHooks, ReentrancyGuard, Ownable {
    using Hooks for IHooks;
    using SafeCast for uint256;
    using SafeCast for int128;

    IPoolManager public immutable poolManager;
    UltraAlignmentVault public immutable vault;
    address public immutable weth; // WETH address for validation
    
    // Tax rate in basis points (e.g., 100 = 1%)
    uint256 public taxRateBips;
    
    // Events
    event SwapTaxed(
        address indexed sender,
        Currency indexed currency,
        uint256 taxAmount,
        address indexed projectInstance
    );
    
    event TaxRateUpdated(uint256 newRate);

    constructor(
        IPoolManager _poolManager,
        UltraAlignmentVault _vault,
        address _weth,
        address _owner
    ) {
        require(address(_poolManager) != address(0), "Invalid pool manager");
        require(address(_vault) != address(0), "Invalid vault");
        require(_weth != address(0), "Invalid WETH");
        require(_owner != address(0), "Invalid owner");

        _initializeOwner(_owner);
        poolManager = _poolManager;
        vault = _vault;
        weth = _weth;
        taxRateBips = 100; // 1% default
        
        // Validate hook permissions - we need afterSwap with return delta
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "Unauthorized");
        _;
    }

    /**
     * @notice Hook called after a swap - taxes the swap and accumulates tokens
     * @param sender The address that initiated the swap
     * @param key The pool key for the pool being swapped
     * @param params The swap parameters
     * @param delta The balance delta from the swap
     * @param hookData Arbitrary data passed to the hook
     * @return selector The function selector
     * @return hookDelta The hook's delta (positive means hook took tokens)
     */
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        // Calculate which currency is being swapped out (the unspecified currency)
        bool specifiedTokenIs0 = (params.amountSpecified < 0 == params.zeroForOne);
        Currency taxCurrency;
        int128 swapAmount;
        
        if (specifiedTokenIs0) {
            // Swapping token0 for token1, tax is on token1 (output)
            taxCurrency = key.currency1;
            swapAmount = delta.amount1();
        } else {
            // Swapping token1 for token0, tax is on token0 (output)
            taxCurrency = key.currency0;
            swapAmount = delta.amount0();
        }
        
        // Get absolute value of swap amount
        if (swapAmount < 0) swapAmount = -swapAmount;
        
        // Calculate tax amount
        uint256 taxAmount = (uint128(swapAmount) * taxRateBips) / 10000;
        
        if (taxAmount > 0) {
            // ENFORCE: Only accept ETH/WETH taxes (pools must be ETH/WETH paired)
            address token = Currency.unwrap(taxCurrency);
            require(
                token == weth || token == address(0),
                "Hook only accepts ETH/WETH taxes - pool must be ETH/WETH paired"
            );
            
            // Take tokens from the pool manager
            poolManager.take(taxCurrency, address(this), taxAmount);

            // Send tax directly to vault with sender as benefactor
            // Vault will accumulate and track ETH from the instance/benefactor
            vault.receiveERC404Tax(taxCurrency, taxAmount, sender);

            emit SwapTaxed(sender, taxCurrency, taxAmount, sender);
            
            // Return the tax amount as positive delta (hook took tokens)
            return (IHooks.afterSwap.selector, taxAmount.toInt128());
        }
        
        return (IHooks.afterSwap.selector, 0);
    }


    /**
     * @notice Set tax rate (owner only)
     * @param _rate New tax rate in basis points (max 10000 = 100%)
     */
    function setTaxRate(uint256 _rate) external onlyOwner {
        require(_rate <= 10000, "Rate too high");
        taxRateBips = _rate;
        emit TaxRateUpdated(_rate);
    }
}

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
