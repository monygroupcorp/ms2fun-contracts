# Security Considerations

## Overview

This document outlines security considerations for the ms2.fun launchpad contracts.

## Security Features

### Access Control

- Owner-only functions for critical operations
- Factory-only functions for instance registration
- EXEC token holder voting for governance

### Reentrancy Protection

- ReentrancyGuard on critical functions
- Checks-effects-interactions pattern

### Integer Overflow Protection

- Solidity 0.8+ built-in overflow protection
- Safe math operations

### Upgrade Safety

- UUPS proxy pattern
- Storage layout compatibility checks
- Governance-controlled upgrades

## Audit Requirements

Before mainnet deployment:
- External security audit
- Bug bounty program
- Formal verification for critical functions

## Best Practices

- Comprehensive test coverage
- Event emission for all state changes
- Input validation
- Gas optimization
- Documentation

## MEV & Transaction-Ordering

See [MEV_ANALYSIS.md](MEV_ANALYSIS.md) for the full analysis. Key protections:

- **Bonding curve**: `maxCost`/`minRefund` slippage guards + opt-in `deadline`
- **V4 hook**: `hookFeeBips` is immutable; `lpFeeRate` is owner-adjustable but bounded by `MAX_LP_FEE`
- **Vault conversions**: Router-level `minOutTarget`/`minTokenOut` slippage; price oracle deviation check (UniVault)
- **ERC721 auctions**: Immutable `timeBuffer` anti-snipe extension + absolute `bidIncrement`
- **Governance**: Checkpoint snapshots at `votingStarts` prevent buy-and-vote; `minRetentionPercent` blocks ragequit dilution

Residual risks include opt-in deadline on bonding (frontend should enforce), zero slippage on internal fee-sweep paths, and keeper-supplied minimums on vault harvest.

## Known Limitations

- Factory applications require manual finalization
- Pricing calculations may need adjustment based on usage
- Hook system requires careful implementation

## Reporting Security Issues

Please report security issues responsibly through appropriate channels.

