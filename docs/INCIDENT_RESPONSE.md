# Incident Response Playbook

## Roles

All roles are held by the project lead until the team expands. As the team grows, split into dedicated roles.

| Role | Responsibility |
|------|---------------|
| **Detector** | Monitors on-chain activity, triages alerts, escalates to Responder |
| **Responder** | Assesses severity, executes containment and mitigation actions |
| **Communicator** | Drafts and posts public statements on Twitter and Telegram |

## Severity Tiers

### P1 — Critical (funds actively at risk)

Triggers:
- Active exploit draining vault or instance funds
- Governance compromise (malicious proposal executing or about to clear timelock)
- Private key compromise of the Safe signer
- Rogue agent actively misusing permissions

Response target: immediate action, public comms within 1 hour.

### P2 — High (vulnerability confirmed, no active exploit)

Triggers:
- Vulnerability reported or discovered but not yet exploited
- Suspicious on-chain activity that could be reconnaissance
- Unexpected contract behavior (wrong fee splits, stuck funds)

Response target: investigate within hours, prepare mitigation.

### P3 — Low (anomalous, needs investigation)

Triggers:
- Unusual transaction patterns that don't clearly indicate attack
- Failed transactions on key contracts
- Community reports of odd behavior

Response target: investigate within 24 hours.

## Emergency Toolkit

### Available Today

| Action | Effect | Limitations |
|--------|--------|-------------|
| **Remove vault/factory from registry** | Quarantines the target, blocks new deployments | Existing instances continue operating |
| **Defrock rogue agents** | Immediately revokes agent permissions via GrandCentral conductor system | Does not affect already-executed actions |
| **UUPS upgrade via DAO** | Patch or replace vulnerable contract logic | Subject to 48h timelock, cannot be fast-tracked |

### Future: Vault-Level Pause Guardian

A dedicated guardian multisig (separate from the DAO) that can freeze individual vaults — no deposits, no claims. The guardian can only pause; unpausing requires the normal DAO/timelock path. This preserves timelock integrity for all governance actions while providing a fast response for the most critical scenario (funds draining from a vault).

Retrofittable via UUPS upgrade once the multisig is expanded. New factories and vaults can bake pause support in from day one.

## Response Procedures

### P1 — Critical

1. **Assess** — confirm the exploit, identify affected contracts and funds at risk
2. **Contain** — remove compromised vault/factory from registry, defrock any rogue agents
3. **Mitigate** — if upgrade needed, submit DAO proposal immediately (48h timelock clock starts)
4. **Communicate** — public statement on Twitter + Telegram within 1 hour
5. **Monitor** — watch for copycat attacks on similar contracts
6. **Post-mortem** — after resolution, document what happened and what changes

### P2 — High

1. **Investigate** — reproduce and confirm the vulnerability
2. **Assess blast radius** — identify which contracts and instances are affected
3. **Prepare upgrade** — draft and test the fix against a fork
4. **Submit proposal** — start the 48h timelock
5. **Communicate** — only if users need to take action (e.g., "do not interact with contract X")

### P3 — Low

1. **Investigate** — check monitoring logs, transaction history, contract state
2. **Escalate or close** — promote to P2/P1 if confirmed, otherwise document findings and close

## Monitoring

Custom monitoring bot running on a VPS, alerting via Telegram.

### Watched Events

| Event | Source | Why |
|-------|--------|-----|
| Large ETH movements | Vaults | Potential drain or unusual withdrawal |
| Vault/factory registration or removal | MasterRegistry | Unexpected registry changes |
| Graduation events | ERC404 instances | Large liquidity deployment moments |
| Proposal submissions, votes, executions | GrandCentral | Governance activity and potential manipulation |
| Agent role grants and revocations | GrandCentral conductors | Permission changes |
| Failed transactions on key contracts | All protocol contracts | Could indicate attack attempts or broken state |

Thresholds for "large" movements should be calibrated based on vault TVL after launch.

## Communication Playbook

### Rules

- Never speculate publicly about exploit details while an incident is active — this helps attackers
- Keep P1 comms to: "aware, investigating, here's what we know about fund safety"
- Do not promise timelines for fixes

### Cadence

| Severity | Channel | Timing | Content |
|----------|---------|--------|---------|
| P1 initial | Twitter + Telegram | Within 1 hour | Acknowledge the issue, fund safety status |
| P1 updates | Twitter + Telegram | Every 2-4 hours | Progress, what users should do |
| P1 resolved | Twitter + Telegram | After resolution | Summary and post-mortem |
| P2 | Telegram only | If user action needed | Advisory on what to avoid |
| P3 | No public comms | — | Internal only unless escalated |

## Post-Mortem Template

After any P1 or escalated P2 incident:

```
## Incident: [Title]
**Date:** YYYY-MM-DD
**Severity:** P1/P2
**Duration:** [time from detection to resolution]

### What Happened
[1-2 paragraphs describing the incident]

### Timeline
- HH:MM — [event]
- HH:MM — [event]

### What We're Changing
- [action item]
- [action item]
```

## Key Addresses

Maintain a private, up-to-date list of:
- Gnosis Safe address and signer addresses
- All deployed vault addresses
- All deployed factory addresses
- MasterRegistry and AlignmentRegistry proxy addresses
- GrandCentral proxy address
- Timelock address

## External Contacts

Maintain a private list of:
- Auditor contact (for emergency review)
- Chain/protocol contacts (if coordination needed)
- Legal counsel (if applicable)
