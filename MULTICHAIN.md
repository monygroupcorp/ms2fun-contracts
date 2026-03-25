# Multichain Governance Specification

**Date:** 2026-03-17
**Status:** Draft — pending advisor review

---

## Summary

ms2.fun operates as a multichain protocol with a single DAO on mainnet. Each remote chain (Base, Arbitrum, etc.) gets a fully independent protocol deployment. The mainnet DAO controls all chains through canonical bridges — no third-party bridge dependencies, no recurring infrastructure costs, no off-chain services to maintain.

Cross-chain alignment (e.g. a Base project aligning with mainnet CULT) is deferred to a future vault type. At launch, each chain's projects align only with tokens native to that chain.

---

## Architecture

```
MAINNET                                    REMOTE CHAIN (Base, Arb, etc.)
───────────────────────                    ─────────────────────────────────

GrandCentral + Safe                        AlignmentRegistryV1
    │                                      MasterRegistryV1
    ▼                                      GlobalMessageRegistry
Timelock (48h)                             ProtocolTreasuryV1
    │                                      Factories (ERC404, ERC1155, ERC721)
    ├── mainnet protocol contracts         Vaults (per alignment target)
    │                                          ▲
    ▼                                          │ owned by
CrossChainRelay                            BridgeReceiver ◄── canonical bridge
    │                                          │
    │── canonical bridge ──────────────────────►│
    │   (Arbitrum Inbox,                       │
    │    OP CrossDomainMessenger, etc.)     Guardian (pause-only multisig)
    │
    ├── ArbitrumBridgeAdapter
    ├── OPStackBridgeAdapter
    └── (future chain adapters)
```

Each remote chain is a self-contained ms2.fun deployment. The only thing crossing chains is governance authority.

---

## Components

Each component below is described with its purpose so that any piece can be evaluated, replaced, or improved independently.

### CrossChainRelay (mainnet — new contract)

**Purpose:** Single point through which the mainnet DAO sends governance calls to remote chains. Sits behind the Timelock so all cross-chain calls go through the same 48h proposal/delay flow as mainnet governance.

**Why it exists:** Without this, the DAO would need to interact with each chain's bridge contracts directly, coupling governance proposals to bridge-specific interfaces. The relay abstracts that — proposals just say "call X on chain Y" and the relay handles delivery.

**What it does:**
- Maintains a registry of known remote chains, their BridgeReceiver addresses, and which bridge adapter to use
- Encodes and forwards governance calls via the appropriate bridge adapter
- Supports batch calls (multiple operations in one bridge message to save gas)
- Only callable by the Timelock

**Could be replaced if:** A better cross-chain messaging standard emerges that all target chains support natively, eliminating the need for per-chain adapters.

```solidity
interface ICrossChainRelay {
    function registerChain(uint256 chainId, address bridgeReceiver, address bridgeAdapter) external;
    function deregisterChain(uint256 chainId) external;
    function relay(uint256 chainId, address target, bytes calldata data) external payable;
    function relayBatch(uint256 chainId, address[] calldata targets, bytes[] calldata data) external payable;
}
```

### IBridgeAdapter (mainnet — per-chain adapter contracts)

**Purpose:** Normalize the interface differences between each chain's canonical bridge so that CrossChainRelay doesn't need to know bridge-specific details.

**Why it exists:** Arbitrum's Inbox, OP Stack's CrossDomainMessenger, and other canonical bridges all have different function signatures, gas payment models, and message encoding. Adapters hide this behind a common interface.

**What it does:**
- Translates a generic "send this payload to this address" call into the chain-specific bridge call
- Handles any bridge-specific gas or fee payment

**Could be replaced if:** You add a new chain — just write a new adapter. If a chain upgrades its bridge, only that adapter changes.

```solidity
interface IBridgeAdapter {
    function sendMessage(address receiver, bytes calldata payload) external payable returns (bytes32 messageId);
}
```

**Planned adapters:**
- `ArbitrumBridgeAdapter` — wraps Arbitrum Inbox retryable tickets
- `OPStackBridgeAdapter` — wraps OP Stack CrossDomainMessenger (covers Base, Optimism, and all OP Stack chains)

### BridgeReceiver (per remote chain — new contract)

**Purpose:** The ownership root on each remote chain. Every protocol contract on the remote chain is owned by the BridgeReceiver. It only accepts calls that originate from the mainnet CrossChainRelay via the canonical bridge.

**Why it exists:** Remote contracts need an owner that can make governance calls (register factories, add targets, withdraw treasury, etc.). The BridgeReceiver fills that role while ensuring only the mainnet DAO can trigger those calls. No local admin keys, no multisig governance — just the DAO.

**What it does:**
- Receives messages delivered by the canonical bridge endpoint
- Validates that the message originated from the mainnet CrossChainRelay (using the bridge's native sender verification)
- Executes the decoded call on the target contract
- Supports batch execution

**No timelock on remote.** The mainnet Timelock already enforces 48h delay. The canonical bridge adds its own transport delay (minutes for Arbitrum, hours/days for OP Stack). Stacking another delay is unnecessary.

**Could be replaced if:** A chain provides a native "governed-from-L1" ownership primitive that makes this contract redundant.

```solidity
interface IBridgeReceiver {
    function receiveMessage(address target, bytes calldata data) external;
    function receiveMessageBatch(address[] calldata targets, bytes[] calldata data) external;
}
```

### Guardian (per remote chain — new contract)

**Purpose:** Emergency circuit breaker. A small multisig (2-of-3 or 3-of-5) that can pause protocol contracts on the remote chain if a bridge exploit or other emergency is detected.

**Why it exists:** If the canonical bridge is compromised, an attacker could send a forged governance message to the BridgeReceiver. The canonical bridge's transport delay (especially 7 days on OP Stack) gives a window to react. The Guardian can pause contracts during that window, preventing the malicious message from doing damage.

**What it can do:**
- Pause any protocol contract on the remote chain

**What it cannot do:**
- Unpause (only the DAO via bridge can unpause)
- Execute arbitrary calls
- Change ownership or parameters
- Modify registries

**Why these restrictions matter:** If Guardian keys are compromised, the worst case is a griefing attack (pausing everything). The DAO unpauses via bridge. The attacker cannot steal funds, change state, or take ownership.

**Could be replaced if:** Canonical bridges develop their own emergency pause mechanisms, or if a watchtower/monitoring system can trigger pauses automatically.

---

## Existing Contracts — No Changes Needed

The following contracts deploy to each remote chain exactly as they exist today. The only difference is `owner` points to the BridgeReceiver instead of a local Timelock.

| Contract | Why no changes |
|----------|---------------|
| AlignmentRegistryV1 | UUPS proxy, Ownable — just set owner = BridgeReceiver |
| MasterRegistryV1 | UUPS proxy, Ownable — same |
| GlobalMessageRegistry | Chain-scoped activity feed, no cross-chain awareness needed |
| ProtocolTreasuryV1 | Accumulates fees locally, DAO controls withdrawals via bridge |
| All Factories | Receive GlobalMessageRegistry at construction, owned by BridgeReceiver |
| All Vaults | Align with chain-local tokens only (v1) |

---

## What Stays Mainnet-Only

| Contract | Why mainnet-only |
|----------|-----------------|
| GrandCentral | DAO voting and share management — fragmenting across chains creates conflicting governance |
| Gnosis Safe | Execution avatar for the DAO |
| Timelock | Single delay enforcement point for all governance, local and remote |
| ShareOffering | Share issuance tied to DAO membership |
| StipendConductor | Contributor payments from mainnet treasury |
| Ragequit Pool | Economic exit for shareholders |
| CrossChainRelay | Mainnet-side bridge interface |
| Bridge Adapters | Mainnet-side canonical bridge wrappers |

---

## Governance Flow

### How a cross-chain governance call works

```
1. Proposal submitted to GrandCentral on mainnet
2. Shareholders vote
3. Proposal passes → queued in Timelock (48h delay)
4. After 48h, anyone executes the proposal
5. Timelock calls CrossChainRelay.relay(chainId, target, data)
6. CrossChainRelay looks up the chain's bridge adapter and BridgeReceiver address
7. Bridge adapter sends the message via canonical bridge
8. Canonical bridge transports message (minutes for Arbitrum, longer for OP Stack)
9. Bridge endpoint on remote chain delivers message to BridgeReceiver
10. BridgeReceiver validates origin, calls target.functionCall(data)
```

### Example proposals

**Launch on a new chain:**
```
CrossChainRelay.registerChain(BASE_CHAIN_ID, baseBridgeReceiver, opStackAdapter)
```
(Remote contracts already deployed by team, owned by BridgeReceiver. This proposal registers the chain in the relay.)

**Add an alignment target on Base:**
```
CrossChainRelay.relay(BASE_CHAIN_ID, baseAlignmentRegistry,
    abi.encodeCall(AlignmentRegistryV1.addTarget, (title, desc, uri)))
```

**Register a factory on Arbitrum:**
```
CrossChainRelay.relay(ARB_CHAIN_ID, arbMasterRegistry,
    abi.encodeCall(MasterRegistryV1.registerFactory, (arbErc404Factory)))
```

**Withdraw from Base treasury:**
```
CrossChainRelay.relay(BASE_CHAIN_ID, baseTreasury,
    abi.encodeCall(ProtocolTreasuryV1.withdraw, (token, recipient, amount)))
```

**Multiple operations on one chain (single bridge message):**
```
CrossChainRelay.relayBatch(BASE_CHAIN_ID,
    [baseAlignmentRegistry, baseMasterRegistry],
    [abi.encodeCall(...addTarget...), abi.encodeCall(...registerVault...)])
```

---

## Deployment Procedure

### Adding a new chain

1. **Dev team deploys** BridgeReceiver on the remote chain
2. **Dev team deploys** Guardian multisig on the remote chain
3. **Dev team deploys** all protocol contracts on the remote chain (via CreateX where practical), all owned by BridgeReceiver:
   - AlignmentRegistryV1 (UUPS proxy)
   - MasterRegistryV1 (UUPS proxy)
   - GlobalMessageRegistry
   - ProtocolTreasuryV1
   - Factories (passed GlobalMessageRegistry at construction)
   - Vaults as needed per alignment target
4. **Dev team deploys** bridge adapter on mainnet for this chain's canonical bridge (if one doesn't exist)
5. **DAO proposal** on mainnet: `CrossChainRelay.registerChain(...)` — formally recognizes the chain
6. **DAO proposal** on mainnet: relay calls to grant Guardian pause roles on each remote contract

Steps 1–4 are permissionless dev work. Steps 5–6 require DAO governance.

### Deploying new factory/vault types across chains

A release chore, not an architectural concern:
1. Dev deploys the new contract on each chain via CreateX (same salt = same address)
2. DAO proposal registers it on each chain via `relayBatch`

---

## Cost Analysis

Post-Pectra, L1 gas is consistently sub-1 gwei.

| Item | Cost |
|------|------|
| Single relay call (~200k gas at 0.5 gwei) | ~0.0001 ETH (~$0.25) |
| L2 execution | Sub-cent |
| 30 governance messages/chain/year × 3 chains | ~0.009 ETH (~$25/year) |
| Recurring infrastructure (relayers, keepers, indexers) | $0 — canonical bridges handle delivery |
| Guardian maintenance | $0 — it's a Safe, no upkeep |

**Total estimated annual cost for 3 chains: ~$25.** The protocol remains free to run.

---

## Cross-Chain Alignment (Future — v2)

**Not in scope for v1.** Documented here for context.

The scenario: a Base project wants to align with mainnet CULT. The vault needs to buy CULT and LP it, but CULT lives on mainnet.

**Concept: `CrossChainAlignmentVault`** — a new vault type (same IVault interface) that:
- Lives on the remote chain, receives fees from project instances like any vault
- Tracks benefactor contributions locally
- Periodically bridges accumulated fees to a paired mainnet vault via canonical bridge
- The mainnet vault buys the aligned token and provides LP

**Open problems:**
- **LP yield distribution**: mainnet vault earns yield, but benefactors are on the remote chain. Options include merkle-based claims on mainnet, bridging yield back, or accepting that cross-chain benefactors claim on mainnet.
- **Benefactor identity**: the mainnet vault sees the bridge as the fee sender, not individual projects. Needs a registration or proof mechanism.

These problems are solvable but warrant their own design cycle. The existing `IVault` interface accommodates new vault types without registry or factory changes — a `CrossChainAlignmentVault` registers like any other vault.

---

## Security Considerations

### Bridge exploit

**Risk:** Attacker compromises the canonical bridge and sends a forged governance message.

**Mitigations:**
- Canonical bridges are the highest-security option per chain (inherit the chain's own security model)
- Guardian can pause contracts during the bridge transport delay
- BridgeReceiver validates sender via the bridge's native origin verification
- No third-party bridge trust assumptions

### Guardian compromise

**Risk:** Guardian multisig keys are compromised.

**Impact:** Limited to pausing (griefing). Cannot execute, unpause, or change state. DAO unpauses via bridge.

### Message replay

**Risk:** A governance message is replayed.

**Mitigation:** Canonical bridges handle replay protection natively (nonces/message IDs).

### Remote chain compromise

**Risk:** The remote chain itself has a consensus failure or reorg.

**Impact:** Scoped to that chain's deployment. No effect on mainnet DAO or other chains. Each chain is an independent deployment with independent risk.
