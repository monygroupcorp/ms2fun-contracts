# Sepolia Deployment Practice Log

> A post-mortem of the 2026-03-27 to 2026-03-29 Sepolia cleanup sprint.
> Written to prevent repeating the same mistakes. Read this before any broadcast.

---

## What We Were Trying to Do

1. Upgrade MasterRegistryV1 with `updateInstanceMetadata` + `revokeInstance`
2. Deactivate the old ERC404Factory (tokenURI bug)
3. Revoke a test instance
4. Deploy a fixed ERC404Factory with working `tokenURI`

Simple in theory. Here is what actually happened.

---

## Incident 1: Stuck Transactions

**What happened:**
The `UpgradeMasterRegistry` broadcast succeeded for the first 2 txs (deploy impl + upgrade proxy) but the last 2 (`deactivateFactory` + `revokeInstance`) were broadcast at ~0.001 gwei and dropped from the Sepolia mempool after ~12 minutes.

**Cost:** ~20 minutes of waiting + manual recovery via `cast send`.

**Root cause:** No gas price set explicitly — forge used a stale/low estimate.

**Fix applied:** Rebroadcast both calls manually with `--gas-price 2gwei`.

**Rule going forward:** Always pass `--gas-price 2gwei` (or higher) on Sepolia broadcasts. The default estimate is unreliable.

---

## Incident 2: revokeInstance Doesn't Work as Intended

**What happened:**
We built `revokeInstance` to hide a test instance from the frontend by making `getInstanceInfo` revert with `NotRegistered`. After deploying, the instance was still visible on the site.

**Root cause:** The frontend discovers instances from indexed `InstanceRegistered` events, not from calling `getInstanceInfo`. Blocking the read path does nothing if the discovery path is event-based.

**Cost:** One wasted MasterRegistry upgrade cycle. `revokeInstance` is now a dead feature marked as temporary.

**Rule going forward:** Before building any on-chain gating or visibility mechanism, confirm with the frontend team how they actually query the data. Don't assume.

---

## Incident 3: metadataURI Coupling (Factory Deploy #1 Wasted)

**What happened:**
The tokenURI fix added `metadataURI` as a field passed from `createInstance` into `initializeMetadata` on the instance — making it the same value as the one written to MasterRegistry. This forced the NFT base URI and the project metadata URI (image/banner/description) to be the same string.

Frontend flagged this immediately. Required a redesign: `metadataURI` stays for the registry, `tokenBaseURI` is a new separate field in `CreateParams` for the instance.

**Cost:** One wasted factory deploy (`0x29737148` deactivated).

**Root cause:** Two different concepts had the same name. The distinction between "project metadata for the registry" and "NFT base URI for tokenURI()" was never clearly defined before implementation.

**Rule going forward:** When a param serves two different purposes, name them separately and confirm with the frontend before deploying. A 10-minute conversation saves a deploy.

---

## Incident 4: Wrong ComponentRegistry — Twice (Factory Deploys #2 and #3 Wasted)

**What happened:**
`DeployCore.sol` deploys a ComponentRegistry at a standard CREATE2 address. `SeedSepolia.s.sol` hardcodes a *different* ComponentRegistry at a vanity address (`0x00001152Ed...`) and approves components there. The `DeployERC404Factory.s.sol` script was written by copying the address from `DeployCore`'s output, not from `SeedSepolia`.

Result: the new ERC404Factory was wired to a ComponentRegistry with zero approved components. `createInstance` would have reverted on every call with `UnapprovedLiquidityDeployer`.

This mistake happened **twice** — on factory deploys #2 and #3 — because the first fix (metadataURI decoupling) was committed and redeployed before the ComponentRegistry issue was caught.

**Cost:** Two wasted factory deploys (`0x29737148` and `0xBCd41D5` both deactivated). Three dead factories sitting in the registry.

**Root cause:** Hardcoded addresses in scripts with no single source of truth. There are two ComponentRegistries on Sepolia and we grabbed the wrong one both times.

**Rule going forward:**
- Never hardcode addresses in deploy scripts by hand.
- All scripts must read from the canonical deployment artifact (`broadcast/DeploySepolia.s.sol/11155111/run-latest.json` or `SeedSepolia`) or a `NetworkConfig` struct.
- Before any broadcast that wires contracts together, run `cast call <ComponentRegistry> "getApprovedComponents()(address[])"` on the address you're using and confirm it's non-empty.

---

## Pre-Broadcast Checklist (Required Going Forward)

Before any `--broadcast` on Sepolia:

- [ ] Simulate first (`forge script` without `--broadcast`) and read every log line
- [ ] Every hardcoded address cross-referenced against `broadcast/SeedSepolia.s.sol/11155111/run-latest.json`
- [ ] If wiring to ComponentRegistry: `cast call <addr> "getApprovedComponents()(address[])"` returns non-empty
- [ ] If wiring to MasterRegistry: confirm it's `0x00001152CBa5fDB16A0FAE780fFebD5b9dF8e7cF`
- [ ] Gas price explicitly set (`--gas-price 2gwei` minimum)
- [ ] Confirmed with frontend that any new on-chain mechanism matches how they query data

---

## Final State After Sprint

| Contract | Address | Status |
|---|---|---|
| MasterRegistryV1 proxy | `0x00001152CBa5fDB16A0FAE780fFebD5b9dF8e7cF` | Upgraded ✅ |
| ERC404Factory (original) | `0xd84f755AdFac9408ADbde65832F8A1BFf5179bF8` | Deactivated |
| ERC404Factory (wrong ComponentRegistry) | `0x29737148d3030dd82CD8536189E05a86cf9B4d07` | Deactivated |
| ERC404Factory (wrong ComponentRegistry again) | `0xBCd41D5dB0a631C69f1681265814E104134eB2E6` | Deactivated |
| ERC404Factory (correct) | `0xe57b69d9e27c5559ae632e1a7ee9a941262181ba` | Active ✅ |
| ERC404BondingInstance impl (correct) | `0xcf40a105fd9cc942417f43c614b7d2f785c9d106` | Live ✅ |
| Test instance revoked | `0x3EC4c183d62eC8520d1346Db57D38F9d0D11059d` | Revoked ✅ |

---

## Summary

4 factory deploys for what should have been 1. Every wasted deploy is real ETH and real time.
The common thread: moving too fast without verifying addresses and without confirming assumptions with the frontend.
Slow down. Simulate. Read the logs. Check the addresses. Then broadcast.
