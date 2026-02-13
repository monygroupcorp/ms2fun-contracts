# Multi-Asset Vault Support Design Decision

## Status: Proposed

## Context

The `IAlignmentVault.receiveHookTax()` function already accepts a `Currency` parameter:

```solidity
function receiveHookTax(
    Currency currency,
    uint256 amount,
    address benefactor
) external payable;
```

This was well-designed — the interface is already multi-asset ready. However, the implementations are ETH-only:

- **UltraAlignmentV4Hook** (line 148): `require(token == address(0), "Hook only accepts native ETH taxes")`
- **UltraAlignmentVault.receiveHookTax**: Only processes `msg.value` (native ETH)
- **ERC1155Instance.withdraw**: Sends ETH via `safeTransferETH` to vault's `receive()` fallback

## Problem

Future vault types may want to accept ERC20 tokens:
- A stablecoin yield vault accepting USDC
- A multi-collateral vault accepting ETH + WETH + stETH
- Token-paired vaults where the alignment token IS the contribution asset

## Current Interface Readiness

The `Currency` parameter from Uniswap V4's type system already handles this. `Currency.wrap(address(0))` = native ETH, `Currency.wrap(tokenAddress)` = ERC20. The interface signature does NOT need to change.

## What Would Need to Change

### Hook Changes

Current hook uses `{value: taxAmount}` to forward ETH to the vault. For ERC20s:

```solidity
if (Currency.unwrap(taxCurrency) == address(0)) {
    vault.receiveHookTax{value: taxAmount}(taxCurrency, taxAmount, sender);
} else {
    IERC20(Currency.unwrap(taxCurrency)).approve(address(vault), taxAmount);
    vault.receiveHookTax(taxCurrency, taxAmount, sender);
}
```

### Vault Changes

`receiveHookTax` needs to handle the ERC20 pull:

```solidity
if (Currency.unwrap(currency) == address(0)) {
    require(msg.value >= amount, "Insufficient ETH");
} else {
    IERC20(Currency.unwrap(currency)).transferFrom(msg.sender, address(this), amount);
}
```

### Share Accounting

This is the hard part. Currently shares are proportional to ETH contributed. With multiple assets:

- **Option 1: Single-asset vaults.** Each vault accepts exactly one asset. Share accounting stays simple. Different projects use different vaults.
- **Option 2: Oracle-based conversion.** Multi-asset vault uses a price oracle to normalize all assets to a common unit. Adds oracle dependency and manipulation risk.
- **Option 3: Weighted shares.** Each asset has a manually-set weight. Simple but requires governance to set weights.

## Risks

- **Oracle manipulation:** If shares are issued based on oracle prices, flash loan attacks could manipulate the price to get outsized shares
- **Price staleness:** Stale oracle data could over/under-value contributions
- **Complexity:** Multi-asset accounting is significantly more complex
- **ERC20 approval patterns:** Pull-based transfers have reentrancy and approval race condition risks

## Recommendation

**Defer implementation, but the door is already open.**

The interface is ready — the `Currency` parameter was the right call. No interface changes needed. The path forward when multi-asset is needed:

1. Build **single-asset vaults** first. A USDC vault, an stETH vault, etc. Each accepts one asset, shares are 1:1 with that asset. Simple, no oracle needed.
2. Let the V4 hook decide which currency to tax based on the pool pair.
3. Only pursue multi-asset vaults if there's clear demand and oracle infrastructure is battle-tested.

**What NOT to change:** Do not add any asset-specific logic to `IAlignmentVault`. The interface is correctly abstract. Do not add `acceptedCurrencies()` or similar — that's an implementation detail for specific vault types.

## Interface Changes Required

None. The interface already supports multi-asset via the `Currency` parameter. This is purely an implementation concern for future vault types.
