# Bonding Curve Arithmetic Specification

**Scope**: `BondingCurveMath.sol`, `CurveParamsComputer.sol`, `LiquidityDeployerModule.sol`, `RevenueSplitLib.sol`

---

## 1. Price Function

The bonding curve uses a degree-4 polynomial price function over **scaled supply**:

```
P(S) = q₄·S⁴ + q₃·S³ + q₂·S² + p₀
```

| Symbol | Param field      | Meaning                     |
|--------|------------------|-----------------------------|
| `q₄`  | `quarticCoeff`   | Quartic coefficient         |
| `q₃`  | `cubicCoeff`     | Cubic coefficient           |
| `q₂`  | `quadraticCoeff` | Quadratic coefficient       |
| `p₀`  | `initialPrice`   | Base price (constant term)  |
| `N`   | `normalizationFactor` | Supply scaling divisor |

**Scaled supply** `S = supply / N` — raw token supply divided by the normalization factor, producing a value in the low range (~1–1000) to keep exponentiation safe in uint256.

---

## 2. Cost & Refund (Definite Integral)

Cost to move supply from `a` to `b` (`b ≥ a`) is the definite integral of P(S):

```
Cost(a, b) = F(b) − F(a)
```

where `F` is the antiderivative evaluated at scaled supply:

```
F(x) = p₀·x + q₂·x² + q₃·x³ + q₄·x⁴     (all in WAD arithmetic)
```

Note: the stored coefficients already incorporate the integration constants (1/n divisors). The reference weights are chosen so that integrating the *price* polynomial yields exactly the stored coefficient times S^n. See §4 for how reference weights encode this.

### Implementation (`BondingCurveMath._calculateIntegralFromZero`)

```
scaledSupply = supply / normalizationFactor        // integer division, rounds down
basePart     = initialPrice ×_wad scaledSupply
quarticTerm  = quarticCoeff ×_wad (S ×_wad (S ×_wad (S ×_wad S)))
cubicTerm    = cubicCoeff   ×_wad (S ×_wad (S ×_wad S))
quadraticTerm = quadraticCoeff ×_wad (S ×_wad S)

F(supply) = basePart + quarticTerm + cubicTerm + quadraticTerm
```

Where `×_wad` is Solady's `mulWad` (multiply then divide by 1e18, rounding down).

### Buy / Sell

```
buyCost(currentSupply, amount)  = Cost(currentSupply, currentSupply + amount)
sellRefund(currentSupply, amount) = Cost(currentSupply − amount, currentSupply)
```

Sell requires `amount ≤ currentSupply`.

---

## 3. Rounding Behavior

Every `mulWad` rounds **down** (truncation). Multiple chained `mulWad` calls compound this:

| Term      | mulWad calls | Max rounding loss per evaluation |
|-----------|:------------:|----------------------------------|
| basePart  | 1            | 1 wei                            |
| quadratic | 2            | 2 wei                            |
| cubic     | 3            | 3 wei                            |
| quartic   | 4            | 4 wei                            |

Total worst-case rounding loss per `F(x)` evaluation: **≤ 10 wei**.

Since `Cost(a,b) = F(b) − F(a)`, and both terms round down, the **net direction is indeterminate** (could over- or under-charge by up to ~20 wei). For any realistic token amount this is negligible.

The initial `supply / normalizationFactor` integer division also rounds down, losing up to `normalizationFactor − 1` tokens of granularity. With typical `N ≈ 10⁷`, price resolution is per ~10M tokens — acceptable given tokens have 18 decimals (10M tokens = 10⁷ × 10¹⁸ wei units, but the *scaled* value changes by 1 wad per 10M raw tokens).

---

## 4. Parameter Computation

`CurveParamsComputer.computeCurveParams` converts a graduation profile into concrete `Params`.

### Inputs

| Input               | Example         | Meaning                                  |
|---------------------|-----------------|------------------------------------------|
| `nftCount`          | 10000           | Number of NFTs                           |
| `targetETH`         | 100 ether       | Total ETH the curve should raise         |
| `unitPerNFT`        | 1e6             | Fungible tokens per NFT                  |
| `liquidityReserveBps` | 2000          | % of total supply held for post-grad LP  |

### Steps

```
totalSupply      = nftCount × unitPerNFT × 1e18
liquidityReserve = totalSupply × liquidityReserveBps / 10000   (round down)
maxBondingSupply = totalSupply − liquidityReserve
normFactor       = maxBondingSupply / 1e18                      (round down, min 1)
```

### Reference Weights

The protocol stores four **reference weights** that define the curve *shape*:

| Weight           | Default value     | Derivation                               |
|------------------|-------------------|------------------------------------------|
| `quarticWeight`  | 3 gwei (3×10⁹)   | Integral coefficient for x⁴ term = 12/4  |
| `cubicWeight`    | 1333333333        | Integral coefficient for x³ term ≈ 4/3   |
| `quadraticWeight`| 2 gwei (2×10⁹)   | Integral coefficient for x² term = 4/2   |
| `baseWeight`     | 0.025 ether       | Base price per scaled unit                |

These weights define the *shape*. The *amplitude* is then scaled to hit `targetETH`:

```
referenceParams = Params(baseWeight, quarticWeight, cubicWeight, quadraticWeight, normFactor)
referenceArea   = Cost(referenceParams, 0, maxBondingSupply)

scaleFactor = targetETH ÷_wad referenceArea

// Final coefficients:
initialPrice  = baseWeight    ×_wad scaleFactor
quarticCoeff  = quarticWeight ×_wad scaleFactor
cubicCoeff    = cubicWeight   ×_wad scaleFactor
quadraticCoeff = quadraticWeight ×_wad scaleFactor
normalizationFactor = normFactor
```

**Invariant**: `Cost(finalParams, 0, maxBondingSupply) ≈ targetETH` (equal up to WAD rounding).

---

## 5. Revenue Split

`RevenueSplitLib.split(amount)` applies the canonical 1/19/80 split:

```
protocolCut = amount / 100                    (floor — 1%)
vaultCut    = (amount × 19) / 100             (floor — 19%)
remainder   = amount − protocolCut − vaultCut (~80%, absorbs dust)
```

The remainder is always ≥ `amount × 80 / 100` because both other terms round down. Maximum dust absorbed: 1 wei from protocolCut + 1 wei from vaultCut = **2 wei** added to remainder.

### Where the split applies

| Context               | Input amount          | Protocol (1%) | Vault (19%) | Remainder (80%)      |
|-----------------------|-----------------------|---------------|-------------|----------------------|
| ERC404 graduation     | accumulated reserve   | treasury      | vault       | LP deployment        |
| ERC1155 withdrawal    | sale proceeds         | treasury      | vault       | artist               |
| ERC721 settlement     | winning bid           | treasury      | vault       | artist               |
| Vault LP yield        | yield amount          | 1% to treasury| —           | 99% to benefactors   |

---

## 6. Bonding Fee

During buy, a fee is applied on top of the curve cost:

```
totalCost    = BondingCurveMath.calculateCost(params, supply, amount)
bondingFee   = (totalCost × bondingFeeBps) / 10000    (round down)
totalWithFee = totalCost + bondingFee
```

- `bondingFee` is sent to the protocol treasury immediately during the buy
- Only `totalCost` (not the fee) is added to `reserve`
- Slippage check: `totalWithFee ≤ maxCost` (user-provided)
- On sell, no fee is charged — refund equals the raw curve integral

---

## 7. Liquidity Pool Initialization (Uniswap V4)

At graduation, the accumulated `reserve` is split and the remainder seeds a V4 pool.

### Sqrt Price Computation

Uniswap V4 pools are initialized with `sqrtPriceX96 = √(price) × 2⁹⁶`.

```
// price = token1_per_token0 = numerator / denominator
numerator   = token0IsThis ? ethForPool : tokensForPool
denominator = token0IsThis ? tokensForPool : ethForPool

priceX192   = fullMulDiv(numerator, 2¹⁹², denominator)
sqrtPriceX96 = √(priceX192)                              // integer sqrt

// Clamp to valid Uniswap range:
sqrtPriceX96 = max(sqrtPriceX96, MIN_SQRT_PRICE + 1)
sqrtPriceX96 = min(sqrtPriceX96, MAX_SQRT_PRICE − 1)
```

Full-range liquidity is provided (min/max usable ticks for the configured tick spacing).

---

## 8. Overflow Analysis

### Bonding curve integral

The highest-order operation is `S⁴` computed via 4 chained `mulWad`. Each `mulWad(a, b)` computes `a × b / 1e18`.

With `normFactor ≈ 10⁷` and `maxBondingSupply ≈ 8×10¹² × 10¹⁸`:
- `scaledSupply = 8×10¹² × 10¹⁸ / 10⁷ = 8×10²³`  (in WAD, this is `8×10⁵` scaled units)
- `S⁴` after mulWad chain: `(8×10²³)⁴ / (10¹⁸)³ = 4×10⁴¹` — well within uint256 (max ≈ 1.16×10⁷⁷)

The coefficient multiplication adds one more `mulWad`, keeping the result < 10⁶⁰. **No overflow risk** for any realistic supply.

### Revenue split

`amount × 19` can overflow if `amount > uint256.max / 19 ≈ 6.1×10⁷⁵`. Since amounts are ETH-denominated (max realistic ~10²⁵ wei), **no overflow risk**.

---

## 9. Numerical Example

**Profile**: 10,000 NFTs, 1M tokens/NFT, 20% liquidity reserve, target 100 ETH.

```
totalSupply      = 10000 × 10⁶ × 10¹⁸ = 10¹⁰ × 10¹⁸ = 10²⁸
liquidityReserve = 10²⁸ × 2000 / 10000 = 2×10²⁷
maxBondingSupply = 8×10²⁷
normFactor       = 8×10²⁷ / 10¹⁸ = 8×10⁹

// Reference integral with default weights → some referenceArea R
// scaleFactor = 100 ether / R
// All coefficients multiplied by scaleFactor
```

After scaling, buying the full `maxBondingSupply` costs exactly ~100 ETH. The curve starts near `initialPrice × scaleFactor` and rises with the quartic shape.

At graduation:
```
reserve ≈ 100 ETH (accumulated from buys minus any sells)
protocolCut = 100 ETH / 100 = 1 ETH
vaultCut    = 100 ETH × 19 / 100 = 19 ETH
ethForPool  = 100 − 1 − 19 = 80 ETH
tokensForPool = liquidityReserve = 2×10²⁷
```
