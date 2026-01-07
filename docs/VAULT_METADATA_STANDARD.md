# Vault Metadata Standard

**Version**: 1.0.0
**Status**: Draft
**Last Updated**: 2026-01-07

## Overview

This document defines the metadata standard for alignment vaults seeking approval through the VaultApprovalGovernance system. All vault applications **MUST** provide a metadata URI that resolves to a JSON document conforming to this standard.

## Why Metadata Matters

Metadata enables:
- **Transparency**: Voters can evaluate vault strategies and risks
- **Discoverability**: Frontends can display rich vault information
- **Interoperability**: Standard format enables tooling and analytics
- **Trust**: Detailed documentation reduces information asymmetry

## Metadata URI Structure

### Storage Requirements

Metadata **SHOULD** be stored on IPFS or another content-addressed storage system to ensure:
1. **Immutability**: Content cannot be changed after submission
2. **Availability**: Content remains accessible regardless of applicant status
3. **Verifiability**: Hash-based addressing proves content integrity

**Recommended URI formats:**
```
ipfs://Qm...     # IPFS CID v0
ipfs://bafy...   # IPFS CID v1
ar://...         # Arweave transaction ID
```

**NOT recommended (mutable, centralized):**
```
https://example.com/metadata.json  # Can be changed
```

### JSON Schema

All metadata documents **MUST** conform to the following JSON schema:

```json
{
  "$schema": "https://json-schema.org/draft-07/schema",
  "type": "object",
  "required": [
    "name",
    "vaultType",
    "description",
    "strategy",
    "risks",
    "contacts"
  ],
  "properties": {
    "name": {
      "type": "string",
      "description": "Human-readable vault name",
      "minLength": 3,
      "maxLength": 64
    },
    "vaultType": {
      "type": "string",
      "description": "Vault implementation type identifier",
      "pattern": "^[A-Za-z0-9]+$"
    },
    "description": {
      "type": "string",
      "description": "Short description (1-2 sentences)",
      "maxLength": 256
    },
    "strategy": {
      "type": "object",
      "description": "Detailed strategy information"
    },
    "risks": {
      "type": "object",
      "description": "Risk assessment and disclosures"
    },
    "contacts": {
      "type": "object",
      "description": "Maintainer contact information"
    },
    "features": {
      "type": "array",
      "description": "Feature identifiers",
      "items": {
        "type": "string"
      }
    },
    "audit": {
      "type": "object",
      "description": "Security audit information"
    },
    "links": {
      "type": "object",
      "description": "External resources"
    }
  }
}
```

## Required Fields

### 1. Basic Information

#### `name` (string, required)
Human-readable vault name.

**Constraints:**
- Length: 3-64 characters
- Must be unique across all approved vaults
- Should clearly identify the vault's purpose

**Examples:**
- "Ultra Alignment Vault"
- "Aave Yield Optimizer"
- "Curve LP Compounder"

#### `vaultType` (string, required)
Technical identifier for vault implementation type.

**Constraints:**
- Alphanumeric only (no spaces or special chars)
- Should match IAlignmentVault.vaultType()
- Used for filtering and categorization

**Examples:**
- `"UniswapV4LP"` - Full-range Uniswap V4 liquidity provision
- `"AaveYield"` - Aave lending protocol integration
- `"CompoundV3"` - Compound V3 yield strategy

#### `description` (string, required)
Short, user-friendly description of what the vault does.

**Constraints:**
- Max 256 characters
- Should be 1-2 sentences
- Must match IAlignmentVault.description()

**Example:**
```json
"description": "Full-range liquidity provision on Uniswap V4 with automated fee compounding and benefactor share distribution"
```

### 2. Strategy Information

#### `strategy` (object, required)
Detailed explanation of the vault's yield strategy.

**Required subfields:**
```json
{
  "strategy": {
    "overview": "High-level strategy description (2-3 paragraphs)",
    "mechanism": "Step-by-step explanation of how yields are generated",
    "assumptions": [
      "Key assumption 1 (e.g., 'Uniswap V4 pools remain liquid')",
      "Key assumption 2 (e.g., 'Gas prices stay below 100 gwei')"
    ],
    "dependencies": [
      {
        "protocol": "Uniswap V4",
        "address": "0x...",
        "risk": "Protocol risk description"
      }
    ],
    "expectedYield": {
      "min": "3% APY",
      "typical": "8% APY",
      "max": "15% APY",
      "disclaimer": "Past performance does not guarantee future results. Yields are variable."
    },
    "feeStructure": {
      "management": "0%",
      "performance": "0%",
      "withdrawal": "0%",
      "other": "All fees accrue to vault, no extraction"
    }
  }
}
```

### 3. Risk Assessment

#### `risks` (object, required)
Comprehensive risk disclosure.

**Required subfields:**
```json
{
  "risks": {
    "smartContractRisk": "Description of smart contract vulnerabilities",
    "liquidityRisk": "Description of liquidity/slippage risks",
    "protocolRisk": "Description of dependencies on external protocols",
    "marketRisk": "Description of market volatility exposure",
    "composabilityRisk": "Description of cross-protocol interaction risks",
    "additionalRisks": [
      "Any other material risks users should know about"
    ],
    "mitigations": [
      "Mitigation 1: Security audits by X",
      "Mitigation 2: Timelock on critical functions",
      "Mitigation 3: Emergency pause mechanism"
    ]
  }
}
```

### 4. Contact Information

#### `contacts` (object, required)
Maintainer and support contact information.

**Required subfields:**
```json
{
  "contacts": {
    "maintainer": {
      "name": "Team or individual name",
      "email": "contact@example.com",
      "github": "https://github.com/username",
      "twitter": "https://twitter.com/handle"
    },
    "support": {
      "discord": "https://discord.gg/...",
      "telegram": "https://t.me/...",
      "forum": "https://forum.example.com"
    },
    "emergency": {
      "email": "security@example.com",
      "disclosure": "Responsible disclosure policy URL"
    }
  }
}
```

## Optional Fields

### 5. Feature Identifiers

#### `features` (array of strings, optional but recommended)
Machine-readable feature tags for filtering and discovery.

**Standard feature identifiers:**

**Strategy Type:**
- `"full-range-lp"` - Full-range liquidity provision
- `"concentrated-lp"` - Concentrated liquidity (with active management)
- `"lending"` - Lending protocol integration
- `"staking"` - Staking rewards
- `"yield-aggregator"` - Aggregates multiple yield sources

**DeFi Protocol:**
- `"uniswap-v4"` - Uniswap V4 integration
- `"uniswap-v3"` - Uniswap V3 integration
- `"aave"` - Aave integration
- `"compound"` - Compound integration
- `"curve"` - Curve Finance integration

**Features:**
- `"auto-compound"` - Automatically compounds yields
- `"multi-token"` - Supports multiple tokens
- `"single-sided"` - Single-sided deposits
- `"emergency-pause"` - Has emergency pause mechanism
- `"upgradeable"` - Upgradeable implementation
- `"timelock"` - Admin actions have timelock

**Risk Level (self-assessed):**
- `"risk-low"` - Conservative strategy, minimal external dependencies
- `"risk-medium"` - Moderate complexity, some external dependencies
- `"risk-high"` - Complex strategy, multiple dependencies, novel mechanisms

**Example:**
```json
{
  "features": [
    "full-range-lp",
    "uniswap-v4",
    "auto-compound",
    "emergency-pause",
    "risk-medium"
  ]
}
```

### 6. Security Audit Information

#### `audit` (object, optional but strongly recommended)
Security audit reports and verification.

```json
{
  "audit": {
    "audited": true,
    "auditors": [
      {
        "name": "Trail of Bits",
        "date": "2025-12-15",
        "reportUrl": "ipfs://Qm...",
        "scope": "All vault contracts and hooks",
        "findings": {
          "critical": 0,
          "high": 0,
          "medium": 2,
          "low": 5,
          "informational": 8
        }
      }
    ],
    "contests": [
      {
        "platform": "Code4rena",
        "date": "2025-11-01",
        "prizePool": "$100,000",
        "reportUrl": "https://code4rena.com/reports/..."
      }
    ],
    "bugBounty": {
      "active": true,
      "platform": "Immunefi",
      "maxPayout": "Up to $500,000",
      "url": "https://immunefi.com/..."
    }
  }
}
```

### 7. External Links

#### `links` (object, optional)
Additional resources and documentation.

```json
{
  "links": {
    "website": "https://vault.example.com",
    "documentation": "https://docs.example.com",
    "github": "https://github.com/org/repo",
    "whitepaper": "ipfs://Qm...",
    "dashboard": "https://dashboard.example.com",
    "analytics": "https://dune.com/..."
  }
}
```

## Complete Example

```json
{
  "name": "Ultra Alignment Vault",
  "vaultType": "UniswapV4LP",
  "description": "Full-range liquidity provision on Uniswap V4 with automated fee compounding and benefactor share distribution",

  "strategy": {
    "overview": "The Ultra Alignment Vault provides full-range liquidity to Uniswap V4 pools, collecting trading fees and automatically reinvesting them to compound returns. Unlike traditional LP strategies, this vault allocates rewards to benefactors (token instances) rather than LPs directly, creating an alignment mechanism where protocol usage drives value to stakeholders.",

    "mechanism": "1. Vault receives ETH via receiveHookTax() from alignment hooks\n2. ETH is paired with ALIGNMENT tokens from treasury\n3. Liquidity is deposited into Uniswap V4 ALIGNMENT/ETH pool at full range\n4. Trading fees accrue to vault's LP position\n5. Fees are periodically claimed and reinvested\n6. Benefactors (instances) can claim proportional share of accumulated fees",

    "assumptions": [
      "Uniswap V4 pools maintain sufficient liquidity and trading volume",
      "ALIGNMENT token maintains reasonable price stability",
      "Gas costs remain economically viable for compounding",
      "V4 hook system remains operational and secure"
    ],

    "dependencies": [
      {
        "protocol": "Uniswap V4",
        "address": "0x0BaCCcCcCcCCcCCCCCCcCcCccCcCCCcCcccccccC",
        "risk": "Smart contract risk in Uniswap V4 core contracts and pool manager. Tested extensively but novel architecture."
      },
      {
        "protocol": "Uniswap V3 Router",
        "address": "0xE592427A0AEce92De3Edee1F18E0157C05861564",
        "risk": "Used for token swaps during rebalancing. Well-audited and battle-tested."
      }
    ],

    "expectedYield": {
      "min": "3% APY",
      "typical": "8% APY",
      "max": "15% APY",
      "disclaimer": "Yields are highly variable and depend on trading volume, pool volatility, and gas costs. Past performance does not guarantee future results. During low volatility or low volume periods, yields may approach 0%."
    },

    "feeStructure": {
      "management": "0%",
      "performance": "0%",
      "withdrawal": "0%",
      "other": "All LP fees and yields accrue directly to the vault. No extraction. Benefactors claim proportionally to their shares."
    }
  },

  "risks": {
    "smartContractRisk": "The vault interacts with Uniswap V4, a novel system with limited production history. While extensively tested, undiscovered vulnerabilities may exist. Vault code itself is unaudited (Phase 1).",

    "liquidityRisk": "Full-range liquidity provision exposes the vault to impermanent loss. During extreme price movements, vault value may decrease relative to holding assets. Withdrawals may face slippage if vault liquidity is concentrated.",

    "protocolRisk": "Vault depends on Uniswap V4 pool manager and hook system. If V4 is paused, upgraded, or exploited, vault functionality would be impacted. Migration path to V3 exists as fallback.",

    "marketRisk": "Vault holds ALIGNMENT tokens and ETH. Extreme price volatility in either asset affects vault value. No hedging or price protection mechanisms.",

    "composabilityRisk": "Vault interacts with factory hooks, which themselves interact with instances. Complex call chains increase surface area for reentrancy or unexpected state transitions.",

    "additionalRisks": [
      "Gas price spikes may make compounding uneconomical, reducing yields",
      "Low trading volume in ALIGNMENT/ETH pool reduces fee generation",
      "Benefactor claims during low liquidity may impact remaining users"
    ],

    "mitigations": [
      "ReentrancyGuard on all external functions",
      "Emergency pause mechanism (owner-controlled in Phase 1)",
      "Fallback V3 liquidity provision if V4 becomes unavailable",
      "Extensive test suite covering edge cases",
      "Open-source code for community review"
    ]
  },

  "contacts": {
    "maintainer": {
      "name": "MS2Fun Core Team",
      "email": "core@ms2.fun",
      "github": "https://github.com/ms2fun",
      "twitter": "https://twitter.com/ms2fun"
    },
    "support": {
      "discord": "https://discord.gg/ms2fun",
      "telegram": "https://t.me/ms2fun",
      "forum": "https://forum.ms2.fun"
    },
    "emergency": {
      "email": "security@ms2.fun",
      "disclosure": "https://docs.ms2.fun/security/responsible-disclosure"
    }
  },

  "features": [
    "full-range-lp",
    "uniswap-v4",
    "auto-compound",
    "emergency-pause",
    "risk-medium"
  ],

  "audit": {
    "audited": false,
    "note": "Phase 1 deployment. Audit planned for Phase 2 after governance is established.",
    "bugBounty": {
      "active": false,
      "note": "Bug bounty program will launch after initial audit completion"
    }
  },

  "links": {
    "website": "https://ms2.fun",
    "documentation": "https://docs.ms2.fun/vaults/ultra-alignment",
    "github": "https://github.com/ms2fun/ms2fun-contracts",
    "dashboard": "https://app.ms2.fun/vaults"
  }
}
```

## Validation

### Pre-Submission Checklist

Before submitting a vault application, verify:

- [ ] Metadata is stored on IPFS or content-addressed storage
- [ ] All required fields are present and non-empty
- [ ] Strategy section clearly explains yield generation mechanism
- [ ] All material risks are disclosed in risks section
- [ ] Contact information is accurate and monitored
- [ ] Feature tags accurately represent vault capabilities
- [ ] Expected yields are realistic and include disclaimers
- [ ] External links are functional
- [ ] JSON is valid and properly formatted

### Common Validation Errors

**Missing required fields:**
```
Error: Metadata missing required field 'risks.smartContractRisk'
Fix: Add comprehensive smart contract risk disclosure
```

**Invalid feature tags:**
```
Error: Unknown feature tag 'super-high-yield'
Fix: Use only standard feature identifiers or propose new standard tags
```

**Misleading information:**
```
Error: Vault claims 100% APY with "no risk" - unrealistic
Fix: Provide honest risk assessment and realistic yield expectations
```

## Best Practices

### 1. Transparency Over Marketing

**Bad:**
```json
{
  "description": "Revolutionary vault with groundbreaking yields!",
  "risks": {
    "smartContractRisk": "Minimal risk, fully secure"
  }
}
```

**Good:**
```json
{
  "description": "Moderate-risk LP strategy targeting 5-10% APY via Uniswap V4 fees",
  "risks": {
    "smartContractRisk": "Uniswap V4 is novel architecture with limited production history. Vault code is unaudited. Users should not deposit funds they cannot afford to lose."
  }
}
```

### 2. Update Metadata When Strategy Changes

If vault strategy, dependencies, or risk profile changes:
1. Create new metadata file with updated information
2. Pin to IPFS to get new CID
3. Submit governance proposal to update vault metadataURI
4. Do NOT modify existing metadata (breaks immutability guarantee)

### 3. Link to Verifiable Sources

When possible, link to on-chain or verifiable information:
- Audit reports on IPFS (not just auditor website)
- GitHub commit hashes for exact code version
- Etherscan/block explorer for dependency addresses
- Archived snapshots for time-sensitive claims

### 4. Disclose Conflicts of Interest

If vault maintainers have financial interests that could influence decisions:
```json
{
  "conflicts": {
    "tokenHoldings": "Core team holds 15% of ALIGNMENT supply",
    "protocolFees": "Vault maintainer receives 5% of protocol revenues",
    "otherPositions": "Maintainer is also advisor to Uniswap Labs"
  }
}
```

## Governance Considerations

### What Voters Should Check

When evaluating vault applications, EXEC token holders should verify:

1. **Metadata Accessibility**: Can the metadataURI be resolved? Is it on immutable storage?
2. **Completeness**: Are all required fields present and substantive (not placeholder text)?
3. **Honesty**: Do risk disclosures seem comprehensive? Any red flags in claims?
4. **Competence**: Does strategy explanation demonstrate deep understanding?
5. **Support**: Are contact details real? Do maintainers respond to questions?
6. **Track Record**: Does maintainer have history of shipping quality code?

### Rejection Criteria

Applications MAY be rejected for:
- Incomplete or placeholder metadata
- Misleading risk disclosures
- Unrealistic yield claims without justification
- Failure to disclose material dependencies
- Unresponsive maintainers during evaluation period
- Evidence of malicious intent or scam indicators

## Version History

**v1.0.0 (2026-01-07)**
- Initial standard for Phase 2 vault governance
- Based on learnings from Phase 1 UltraAlignmentVault deployment
- Aligned with IAlignmentVault interface requirements

## Future Extensions

Potential additions for v2.0.0:
- Standard schemas for specific vault types (LP, lending, staking)
- On-chain metadata verification via ENS TextRecords
- Machine-readable risk scores
- Historical performance data format
- Integration with DeFi risk frameworks (e.g., DeFi Safety)

---

**Questions or suggestions?** Open an issue or discussion on GitHub.
