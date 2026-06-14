# s-nomp-verus Project Context

## Setup

- Pool runs in Docker Compose: `docker compose up -d` from `/root/s-nomp-verus`
- Website: port 8080, stratum: port 9999
- Redis runs as a Docker sidecar (service name `redis`)
- Clustering forks set to 2 (prevents flooding verusd RPC queue)
- Pool Fee: 0% (rewardRecipients empty, all goes to mining address)
- Payments: disabled

## Daemon Access

All daemons accessed directly via `nodes.home` (172.16.3.31). `proxy.home` (172.16.0.25) is a reverse proxy that forwards to nodes.home — use the direct IP to avoid routing issues with addmergedblock registration.

| Chain | Port  |
|-|-|
| VRSC  | 27486 |
| vARRR | 20778 |
| VDEX  | 21778 |
| CHIPS | 22778 |

Credentials stored in `pool_configs/vrsc.json` (gitignored).

## Mining Address

`RAQCrce8uVhKrvSkjn19WNorrzRBna1AEz` — all rewards go here. No payouts.

## PBaaS Chain IDs

| Chain | currencyid |
|-|-|
| vARRR | iExBJfZYK7KREDpuhj6PzZBzqMAKaFg7d2 |
| VDEX  | iHog9UCTrn95qpUBFCZ7kKz7qWdMA8MQ6N |
| CHIPS | iJ3WZocnjG9ufv7GKUA4LijQno5gTMb7tP |

## GitHub Repos (oneidprod)

| Repo | Purpose |
|-|-|
| oneidprod/s-nomp-verus | Pool frontend/portal |
| oneidprod/node-stratum-pool-verus | Stratum pool module (pbaasRegistrar lives here) |
| oneidprod/equihashverify | Node 18 patched equihash verifier |
| oneidprod/verushash-node | Node 18 patched VerusHash module |

## Miner Capabilities (DO NOT SECOND-GUESS THIS)

The user's miner finds VRSC blocks solo 1-3x per week and PBaaS blocks 2-5x per day at
verus.farm. The miner shows as the named block winner in verus.farm's blocks API — these
are genuine solo block finds, not pool-share payouts. Do not suggest this is impossible
or that "it must be pool distribution." Accept it as fact.

## NiceHash / hashflow Proxy

- hashflow proxy connects as miner `RAQCrce8uVhKrvSkjn19WNorrzRBna1AEz.hashflow`
- Pool enables NiceHash mode by returning `result: true` on `mining.extranonce.subscribe`
- Confirmed working: proxy logs "NiceHash mode active (extranonce.subscribe accepted)"
- No `#xnsub` URL flag needed; no separate port needed

## PBaaS Merge Mining

`pbaasRegistrar.js` in `node-stratum-pool-verus/lib/`:
- Polls each PBaaS chain via `getblocktemplate` every 10s
- Stores each chain's current target (from `bits` field) for block match detection
- Assembles minimal block hex (140-byte header + solution + txns)
- Calls `addmergedblock` on VRSC daemon with `[hexdata, chainname, host, port, "user:pass"]`
- On `nextblocktime` response, retries immediately with that nTime
- Also fires `registerAll()` on every new VRSC block
- 3/3 chains confirmed registered (vARRR, VDEX, CHIPS)

When a miner share meets a PBaaS chain's difficulty, `getMatchingChains()` identifies which
chains it satisfies. Result stored in `shareData.pbaasChainMatches` and logged as:
`PBaaS found [vARRR, CHIPS]: <hash> by <worker>`

## Block Detection and Submission Flow

1. `jobManager.js`: share meets `merged_target` (from GBT `mergeminebits`) → sets `blockHex`, `blockHash`, `blockOnlyPBaaS`
2. `pool.js`: calls `submitmergedblock` on VRSC daemon
3. For VRSC blocks (`!blockOnlyPBaaS`): `CheckBlockAccepted` via `getblock` on VRSC daemon
4. For PBaaS-only blocks (`blockOnlyPBaaS`):
   - `getMatchingChains(blockHash)` pre-filters by current `chainTargets`
   - **If pre-filter returns [] (stale targets), falls back to ALL chain names** (fix added Session 5)
   - `verifyChainAcceptance` calls `getblock` on each candidate PBaaS chain
   - Only credited as valid if at least one chain confirms the block

## Current Chain Difficulties (as of 2026-06-13)

| Chain | PoW Diff | Reachable |
|-|-|-|
| CHIPS | ~226M | Yes — same as merged_target |
| vARRR | ~3.2B | No |
| VDEX  | ~2.8B | No |
| VRSC  | ~4.5T | Yes (user finds 1-3/week) |

CHIPS has ~68% PoS block rate (network-wide). PoS competition means not every valid
PoW candidate will land — a staker may claim that height first. This is expected and
not a code bug. The pool daemons having `staking=True` in `getmininginfo` is just lottery
participation; confirmed 0 staking wins on pool wallet addresses.

## submitmergedblock Response Format

Known confirmed fields:
- `accepted: true` — VRSC accepted the block (VRSC difficulty met)
- `accepted: "pbaas"` — only PBaaS chain difficulty met, not VRSC
- `accepted: false` / `rejected: "reason"` — rejected
- `pbaas_submissions: { "name": "chainID_hex" }` — lists which PBaaS chains were attempted

**Important:** `pbaas_submissions` only confirms the block was submitted to a chain, NOT
that the chain accepted it. `getblock` on the PBaaS daemon is the authoritative check.

## Oink70 Comparison (Oink70/s-nomp + Oink70/node-stratum-pool)

Repos cloned to `/tmp/oink-snomp` and `/tmp/oink-stratum` for reference.

Our fork is AHEAD of Oink70 in these areas — do not regress them:
- `pbaasRegistrar.js` — Oink70 has no equivalent; no per-chain block detection
- `verifyChainAcceptance` — Oink70 trusts submitmergedblock and records false positives
- `mining.extranonce.subscribe` returns `true` — Oink70 returns `false` (no NiceHash)
- `authorized` event + job resend in `pool.js` — Oink70 doesn't have this
- Address validation via daemon `validateaddress` RPC — Oink70 uses WAValidator npm package

Oink70 improvements worth future consideration:
- 15-second clean job throttle in `jobManager.js` (prevents miner disruption from frequent PBaaS polls)

Do NOT switch to Oink70 wholesale — we would lose all PBaaS-specific capabilities.

## Docker Notes

- Image built from `node:18-bullseye`
- Dockerfile has `ARG CACHEBUST=1` before `RUN npm install` — use this to bust only the npm layer:
  `docker compose build --build-arg CACHEBUST=$(date +%s) && docker compose up -d`
- After code changes to `node-stratum-pool-verus`, docker cp + restart is fastest for iteration:
  `docker cp /root/node-stratum-pool/lib/<file>.js s-nomp-verus-site-1:/site/node_modules/stratum-pool/lib/<file>.js && docker restart s-nomp-verus-site-1`
- Anonymous volume `- /site/node_modules` keeps container node_modules isolated from host mount
- pbaasRegistrar.js and pool.js are baked into the image — no manual cp needed after full rebuild

## Backlog

- Port Oink70's 15-second clean job throttle from `jobManager.js` (low priority)
- Compare oneidprod/s-nomp-verus against VerusCoin/s-nomp upstream (93 commits behind)

---

## Session Log

### Session 7 - next
<!-- placeholder -->

### Session 6 - 2026-06-14 ✓
Committed and rebuilt Docker image to bake in all node-stratum-pool changes (NiceHash, PBaaS stale-target fallback, clean job on auth). Added restart:unless-stopped to docker-compose.yml. Changed proxy.home → 172.16.3.31 (nodes.home direct IP) in pool_configs/vrsc.json — proxy.home caused addmergedblock registrations to silently fail (mergemining stayed 0). Added 30-second watchdog in pool.js: checks getmininginfo, if mergemining=0 disconnects all stratum clients so hashflow proxy fails over automatically. Eliminated DNS queries by using IPs throughout. Confirmed mergemining:4 with all 3 chains registered (vARRR, vDEX, CHIPS).

### Session 5 - 2026-06-13 ✓
Fixed stats page layout: moved VRSC Blocks Found to appear directly under VRSC Network Stats (was pushed to bottom). Fixed "0 Sol" → "0 H/s" in getReadableNetworkHashRateString (stats.js line 843). PBaaS chain boxes (Pool Stats + Network Stats + Blocks Found per chain) now appear after VRSC section. Deployed via docker cp + restart, verified via curl.

### Session 4+5 - 2026-06-13 ✓
NiceHash: stratum.js mining.extranonce.subscribe returns true; confirmed "NiceHash mode active" in hashflow proxy. Investigated invalidBlocks:4 — docker logs showed pool finding PBaaS candidates (226M+ shareDiff) but all rejected post-Session-3 fix. Root cause: getMatchingChains() uses chainTargets updated every 10s, but block was found against job's merged_target set at job creation — if CHIPS retargeted between those two moments, pre-filter returns [] and we bailed before calling verifyChainAcceptance. Fix: when getMatchingChains returns [], fall back to getAllChainNames() and still run verifyChainAcceptance. Added getAllChainNames() to pbaasRegistrar.js. Also confirmed CHIPS ~68% PoS rate network-wide causes genuine PoW rejections regardless. Compared Oink70/s-nomp and Oink70/node-stratum-pool thoroughly — our fork is ahead on all PBaaS features; do not switch wholesale. Removed temporary debug log from jobManager.js. Deployed pool.js + pbaasRegistrar.js.

### Session 3 - 2026-06-12 ✓
Added per-chain PBaaS block detection (getMatchingChains, pbaasChainMatches). Implemented getblock acceptance check after submitmergedblock to eliminate false positive block recording — verified getblock error format consistent across all 3 chains. Cleaned 2 false positive CHIPS entries from Redis pbaasPending. Added authorized event to stratum.js and resend job in pool.js after authorization to fix proxy not getting clean jobs on reconnect. Investigated false CHIPS block claim — root cause: staking block beat our PoW submission, acceptance check now prevents this. Discovered fork is 93 commits behind VerusCoin/s-nomp — upstream comparison needed next session. Cloned VerusCoin/s-nomp to /tmp/verus-snomp-ref.

### Session 2 - 2026-06-11 ✓
Cleared "pool nonce missing" false alarm (timing artifact). Full Docker image rebuild with CACHEBUST to bake pbaasRegistrar.js permanently. Added per-chain PBaaS block detection: pbaasRegistrar stores chain targets from GBT bits, exposes getMatchingChains(); pool.js populates shareData.pbaasChainMatches; poolWorker logs chain names; shareProcessor writes one pbaasPending Redis entry per chain (format: blockHash:chainName:worker:timestamp); stats.js reads pbaasPending; stats.html renders PBaaS Chain Blocks Found section. Investigated false positive PBaaS block detection — root cause is missing getblock acceptance check after submitmergedblock. Documented submitmergedblock response format and correct fix approach.

### Session 1 - 2026-06-11 ✓
Brought s-nomp-verus up in Docker on Node 18. Patched equihashverify and verushash-node C++ addons for Node 18 V8 API compatibility. Fixed Redis connection bug in website.js. Implemented PBaaS merge mining registrar (pbaasRegistrar.js) with addmergedblock flow, nextblocktime retry, and 10s polling for all 3 chains. Confirmed 3/3 chains registered. Set clustering forks to 2, fee to 0%, payments disabled. Updated READMEs. Added CACHEBUST arg to Dockerfile.
