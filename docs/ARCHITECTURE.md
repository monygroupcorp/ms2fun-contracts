# Architecture Overview

## System Architecture

The ms2.fun launchpad consists of several interconnected components:

### Core Components

1. **Master Registry**: Central registry managing factory applications and instances
2. **Factory Contracts**: Deploy and manage token instances (ERC404, ERC1155)
3. **Governance System**: EXEC token holder voting
4. **Ultra-Alignment System**: Advanced hooks and vaults for ERC404 tokens

### Contract Interaction Flow

```
User → Factory Application → Voting → Approval → Factory Registration
                                                      ↓
                                              Instance Creation
                                                      ↓
                                              Instance Registration
```

### Upgradeability

The Master Registry uses UUPS (Universal Upgradeable Proxy Standard) pattern for upgradeability. Upgrades are controlled by EXEC governance.

### Pricing System

Dynamic pricing for featured promotions uses:
- Supply-based pricing (utilization rate)
- Demand-based pricing (recent purchase tracking)
- Price decay mechanism
- Automatic equilibrium finding

