# ERC404 Factory Family

Composable factory system for deploying ERC404 bonding curve instances with alignment vault integration.

## Architecture

```
ERC404Factory (12.6KB)
  |
  |-- clone --> ERC404BondingInstance (24.1KB implementation, 45-byte proxies)
  |
  |-- delegates to:
       |-- CurveParamsComputer    (2.5KB)  - bonding curve math + weight config
       |-- LaunchManager          (2.3KB)  - tier pricing + promotion badges
       |-- ERC404StakingModule    (3.6KB)  - Synthetix-style yield accounting
       |-- LiquidityDeployerModule (7.0KB) - V4 pool init + liquidity deployment
```

## Deployment Flow

1. Deploy companion contracts: `ERC404StakingModule`, `LiquidityDeployerModule`, `CurveParamsComputer`, `LaunchManager`
2. Deploy one `ERC404BondingInstance` as the implementation (locked, cannot be used directly)
3. Deploy `ERC404Factory` with all addresses wired in
4. Each `createInstance()` call deploys a minimal proxy (ERC-1167 clone) and calls `initialize()`

## Contract Responsibilities

### ERC404Factory
Thin orchestrator. Validates inputs, resolves tier fees via `LaunchManager`, computes curve params via `CurveParamsComputer`, deploys a clone of the implementation, initializes it, and registers with `MasterRegistry`.

### ERC404BondingInstance
The core token contract. DN404 (ERC404) hybrid with bonding curve buy/sell, NFT reroll with shielding, staking delegation, and V4 liquidity graduation. Uses `initialize()` pattern (no constructor) for clone compatibility.

Key design decisions:
- **`_skipNFTDefault = false`** -- holders automatically receive NFTs, no manual minting needed
- **Clone pattern** -- every instance is a minimal proxy; one implementation deployed once
- **No view aggregation** -- read functions live in `QueryAggregator`, not the instance
- **Custom errors** -- all reverts use custom errors to minimize bytecode

### CurveParamsComputer
Owns bonding curve weight configuration and the `computeCurveParams()` function. Also exposes `calculateCost()` and `calculateRefund()` for external callers (frontend, QueryAggregator). The instance calls out to this contract for buy/sell pricing instead of inlining the math library.

### LaunchManager
Owns tier configuration (STANDARD/PREMIUM/LAUNCH), promotion badge assignment, and featured queue placement. Called by the factory after instance creation to apply tier perks.

### ERC404StakingModule
Factory-scoped singleton for staking yield distribution. Pure accounting -- holds no funds. Tracks `rewardPerTokenStored` per instance using the Synthetix reward model. Instances delegate `stake/unstake/claimRewards` calls here. Authorization: only registered instances (via `MasterRegistry.isRegisteredInstance`).

### LiquidityDeployerModule
Handles the entire V4 liquidity deployment lifecycle: fee splitting, sqrtPrice computation, pool initialization, `unlock()` + `unlockCallback()`, and POL (protocol-owned liquidity) deployment. The instance sends ETH + tokens and gets back a liquidity position. This keeps all V4 imports (`TickMath`, `LiquidityAmounts`, `StateLibrary`, `CurrencySettler`) out of the instance bytecode.

## Size Budget

All contracts are under the EIP-170 deployment limit (24,576 bytes) with `optimizer_runs = 100` and `via_ir = true`.

| Contract | Deployed Size | Headroom |
|---|---|---|
| ERC404BondingInstance | 24,113 | 463 bytes |
| ERC404Factory | 12,686 | 11,890 bytes |
| CurveParamsComputer | 2,481 | 22,095 bytes |
| LaunchManager | 2,336 | 22,240 bytes |
| ERC404StakingModule | 3,569 | 21,007 bytes |
| LiquidityDeployerModule | 6,980 | 17,596 bytes |

## Instance Lifecycle

```
createInstance() --> [BONDING] --> buyBonding/sellBonding
                                     |
                         (curve full or matured)
                                     |
                     deployLiquidity() --> [GRADUATED]
                                              |
                                     V4 pool + LP active
                                     staking + vault yield
```

## Staking Model

Instances optionally enable staking (irreversible). Once enabled:
- Holders stake ERC404 tokens to earn proportional vault fee yield
- Uses `rewardPerTokenStored` accumulator (Synthetix pattern)
- Late joiners cannot dilute prior stakers' earned rewards
- Owner must stake to earn -- enabling staking alone forfeits direct vault yield
