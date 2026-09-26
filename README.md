# Pearl (PRL) GPU miner container for SaladCloud — AMD GPUs

Container image for SaladCloud AMD GPU classes (RX 6000 / RX 7000 / RX 9000)
that mines [Pearl](https://pearlchain.live/) (PRL) on the **pearlhash**
proof-of-useful-work algorithm. Forked from the Quai/KawPow image
([wildrig-salad](https://github.com/pvandenburg1234-eng/wildrig-salad)); same
miner-probing entrypoint, different coin and miners.

It bundles four miners and auto-selects the first one that produces an
accepted share on the node it lands on:

1. [krig-miner](https://github.com/kryptex/krig-miner) — Kryptex's miner,
   ROCm/HIP backend (RDNA2/3/4), 0% devfee. **Only works with Kryptex's own
   pool**; it refuses every other pool, so the entrypoint skips it unless
   `POOL` is a `kryptex.network` address. **Verified working on SaladCloud
   2026-09-23: RX 9060 XT (gfx1200) at 51.9 TH/s** on Kryptex US over TLS,
   well above the ~36 TH/s public benchmark for that card. Also detects an
   RX 7800 XT (gfx1101) and picks an RDNA3 kernel.
2. [SRBMiner-MULTI](https://github.com/doktor83/SRBMiner-Multi) — pearlhash on
   AMD via OpenCL (2% devfee). Its OpenCL path is known to work on Salad's ROCm
   stack from the Quai image (RX 9060 XT). **Unverified for pearlhash.**
3. [BzMiner](https://github.com/bzminer/bzminer) — pearl on AMD (2% devfee).
   **Unverified.**
4. [WildRig-Multi](https://github.com/andru-kun/wildrig-multi) — last resort;
   AMD pearlhash was fixed in 0.51.2 (0% devfee for pearlhash) but under ROCm
   OpenCL its kernels historically failed to build. **Unverified.**

TeamRedMiner is not included: it has no pearlhash support.

Once you see `ACCEPTED SHARE - this miner works on this node` in the logs,
please update the list above with the card and hashrate.

**Read the economics note in `Dockerfile` first.** Renting GPUs to mine is usually
a net loss, and Pearl's difficulty has climbed steeply since its April 2026
launch. Test with one replica for 24 h before scaling.

Expected pearlhash rates from public benchmarks (TH/s): RX 9070 XT ~71,
RX 9070 ~59, RX 7900 XTX ~46, RX 7900 XT ~40, RX 7800 XT ~29, RX 9060 XT ~36,
RX 6800 XT ~24. Compare against an RTX 3080 at ~105. On Salad with krig-miner
the RX 9060 XT measured 51.9 TH/s, so RDNA4 cards may do better than the
benchmark sites suggest.

| Card (Salad class) | Miner | Rate | Date |
|---|---|---|---|
| RX 9060 XT | krig-miner 1.5.2 | 51.9 TH/s | 2026-09-23 |
| RX 9060 XT | krig-miner 1.5.2 | 49.1 TH/s, 5 shares in 5 min (bench, Kryptex SG) | 2026-09-24 |
| RX 9060 XT | SRBMiner 3.6.9 | 42.3 TH/s, 1 share in 5 min (bench) | 2026-09-24 |
| RX 9060 XT | BzMiner 100.36 | 34 falling to 29 TH/s, 0 shares in 5 min (bench) | 2026-09-24 |
| RX 9060 XT | WildRig 0.51.2 | does not hash under ROCm OpenCL (`n/a TH/s`, `err`) | 2026-09-24 |
| RX 9070 XT | krig-miner 1.5.2 | **fails at 4 GB RAM**: `CUDA driver call failed (host A pinned alloc): 2` (out of memory) on every attempt. **Works at 8 GB: 87.4 TH/s**, 2 shares in 4 min. Still well behind BzMiner. | 2026-09-24 |
| RX 9070 XT | SRBMiner 3.6.9 | 90.9 TH/s, 2 shares in 5 min (bench, Kryptex global 44 ms) | 2026-09-24 |
| RX 9070 XT | BzMiner 100.36 | **126.0 TH/s**, 5 shares in 5 min (bench; pool-side 99–149) | 2026-09-24 |

The winner depends on the card, so pin per GPU class:

| Salad GPU class | `MINERS=` | Why |
|---|---|---|
| RX 9060 XT | `krig` | 49–52 TH/s at 0% devfee; BzMiner only 33 |
| RX 9070 XT | `bz` | 126–127 TH/s (124 after 2% devfee) vs SRBMiner 91 and krig 87 (krig also needs 8 GB RAM on this card) |
| RX 7800 XT / 7900 XT | run the bench | krig detects them (gfx1101/gfx1100); no numbers yet |

krig's 9070 XT failure at 4 GB is a page-locked host-memory allocation, which
under WSL comes out of the container's RAM limit; at 8 GB it runs, at 87 TH/s.

## 1. Get the image built (no Docker needed)

1. Push this folder to a **public** GitHub repository (this one is
   `pearl-salad`).
2. On GitHub open the **Actions** tab — the `build-and-push` workflow runs
   automatically (~5–10 min). A push to `main` updates
   `ghcr.io/<you>/pearl-salad:latest`; a git tag `vX.Y.Z` publishes
   `ghcr.io/<you>/pearl-salad:vX.Y.Z` (see **Releases** below).
3. Make the package public: your GitHub profile → **Packages** →
   `pearl-salad` → **Package settings** → **Change visibility** → Public.
   SaladCloud can only pull public images (or you'd have to configure registry
   credentials in the container group).

## 2. Get a Pearl wallet address

Install the [Pearl Wallet](https://pearlchain.live/wallet) browser extension
(or any wallet from the Pearl docs), create a wallet, and copy the address.
Pearl mainnet addresses are bech32m and **always start with `prl1p`**. The
entrypoint warns if `WALLET` doesn't start with `prl1`.

## 3. Deploy on SaladCloud

Portal → **Container Groups → Deploy**:

| Setting | Value |
|---|---|
| Image | `ghcr.io/<you>/pearl-salad:v1.0.0` — pin a release tag, not `:latest`, so a Batch reallocation can't pull an untested build |
| Replicas | `1` for testing |
| GPU | an **AMD** class (RX 7000 / RX 9000 preferred; RX 6000 works at lower rates). Don't put NVIDIA classes in the same group. |
| vCPU / RAM | 2 vCPU / 4 GB. On an RX 9070 XT krig failed its pinned host-memory allocation at 4 GB; use 8 GB there if you want krig, or pin `MINERS=bz` (faster anyway, see the table above) |
| Storage | smallest |
| Priority | Batch |
| Command | *(leave empty)* |
| Gateway / health probes | none / off |

Environment variables:

| Name | Value |
|---|---|
| `WALLET` | your Pearl address (`prl1p…`) — **required** |
| `POOL` | `stratum+ssl://prl.kryptex.network:8048` (default; Kryptex, 1% fee, dashboard at `pool.kryptex.com/prl`). TLS on 8048 because krig-miner refuses plain TCP; the other miners get `--tls` / `stratum+ssl://` from the same URL. If you set the plain port 7048, krig is silently given 8048. Kryptex is the only pool krig-miner will talk to, and 1% pool fee + krig's 0% devfee beats any 0% pool + SRBMiner's 2% devfee. The **region is auto-selected** at startup by TCP latency from the node (`prl prl-us prl-eu prl-br prl-sg prl-hk prl-ru prl-ae`); the log shows the probe results. Set `POOL_AUTO=0` to use `POOL` exactly as given. Alternative: HeroMiners, `stratum+tcp://ca.pearl.herominers.com:1200` (0% fee, PPS+; regions `ca us us2 us3 de es fi fr ru tr hk sg kr au br` are auto-probed the same way; krig is skipped there and SRBMiner takes over). |
| `WORKER` | optional label; Salad's machine id is used if unset |
| `MINERS` | order to try, default `krig srb bz wildrig`. Pin one with e.g. `MINERS=srb` |
| `NO_SHARE_TIMEOUT` | seconds a miner gets to produce an accepted share before the next is tried (default `600` — Pearl shares are STARK proofs and the first one can be slow on weak cards) |
| `POOL_CHECK` | `1`. After the region is picked, open a TLS connection to the pool and verify its certificate (curl, 8 s). No handshake at all, not even to the global `prl.kryptex.network:8048`, means the host cannot reach the pool, and the replica is handed back to Salad right away instead of paying `NO_SHARE_TIMEOUT` per miner for nothing (a 5070 Ti Laptop host did exactly that: TCP fine, every TLS connect failed, GPU idle). Handshake works but the certificate does not verify means something on the host's network intercepts TLS: SRBMiner and BzMiner mine through it, krig refuses such a pool as "not the official Kryptex PRL pool", so krig is skipped on that host and the next miner starts. `0` disables. |
| `MAX_FAILED_PASSES` | `1`. Full passes through `MINERS` with no accepted share from any miner that ran, after which the replica is handed back to Salad (one pass is `NO_SHARE_TIMEOUT` x the miners that ran). Before this the loop retried forever on a node that could not mine. A pass where every miner was skipped is a configuration error and is retried, not reallocated. Off Salad it just keeps retrying. |
| `KRIG_EXTRA_ARGS` / `SRB_EXTRA_ARGS` / `BZ_EXTRA_ARGS` / `WILDRIG_EXTRA_ARGS` | optional extra flags per miner (e.g. `KRIG_EXTRA_ARGS=--rocm-runtime 7`) |
| `AXIOM_TOKEN` | optional; an Axiom **ingest** token (add it as a secret in Salad). When set, the container posts its own log (the `===` lines and the miner output) to Axiom every `SHIP_INTERVAL` seconds (default `10`), in the same record shape as Salad's Axiom forwarder (`@timestamp`, `log.message`, `resource.labels.*` from Salad's `SALAD_*` variables) plus `via=container`. Written because Salad's external-logging forwarder stopped delivering on 2026-09-25. Line times are the post time (up to `SHIP_INTERVAL` late). Shipping never stops mining: failed posts are retried, rejected ones dropped. `AXIOM_DATASET` (default `salad-prl`) and `AXIOM_HOST` (default `us-east-1.aws.edge.axiom.co`; `api.axiom.co` does not serve this ingest path) override the target. If Salad's own Axiom logging also works on the group, lines arrive twice; use one or the other. |
| `LOG_SHIP` | `1`. `0` turns the log shipping off even when `AXIOM_TOKEN` is set. |

There is no `ALGO` variable: every miner spells pearlhash differently
(`--coin pearl`, `--algorithm pearlhash`, `-a pearl`, `--algo pearlhash`), so
the entrypoint hardcodes it per miner.

## 4. Verify

Open the container's logs in the Salad portal. You should see:

1. `rocminfo` listing an agent with a `gfx…` name (GPU visible).
2. `clinfo -l` showing an AMD platform.
3. `Probing Kryptex Pearl regions` followed by `Using nearest region` and
   `pool check: TLS handshake and certificate OK`.
4. `=== [krig] starting ...` then, within a few minutes,
   `=== [krig] ACCEPTED SHARE - this miner works on this node ===` (or the
   same for `srb`, `bz` or `wildrig` if earlier miners were skipped).

Then check `https://pool.kryptex.com/prl` with your wallet address to see
hashrate and estimated earnings; compare that to what Salad bills per hour.

### Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `HSA_STATUS_ERROR_OUT_OF_RESOURCES` in rocminfo | Image ROCm < 7.1 or something overwrote `LD_LIBRARY_PATH`. Don't set those in Dockerfile/entrypoint. |
| `no accepted share after 600s - killing and trying next miner` | That miner can't hash on this node's driver stack; the entrypoint moves on. Once you see `ACCEPTED SHARE - this miner works`, pin it with `MINERS=<name>` to skip the probing on future reallocations. |
| `pool check: no TLS handshake to ...` then `asking Salad to reallocate` | The node's network lets TCP through but no TLS session to the pool ever completes (seen on a 5070 Ti Laptop host: BzMiner `TLS connect failed`, SRBMiner silent, GPU idle). Nothing can mine there; Salad moves the replica. `POOL_CHECK=0` to skip the check. |
| `pool check: TLS handshake works but the certificate does NOT verify` | The host's network intercepts TLS (on such a host the region probe reads 1-4 ms to every region on earth). SRBMiner and BzMiner mine through it; krig is skipped because it refuses the intercepted pool. |
| `no miner produced an accepted share this pass` then `asking Salad to reallocate` | Every miner in `MINERS` ran and none got a share within `NO_SHARE_TIMEOUT`. The node can't mine (network, driver, GPU); Salad moves the replica. Raise `MAX_FAILED_PASSES` to retry on the same node first. |
| krig: `CUDA driver call failed (host A pinned alloc): 2`, retrying forever | krig couldn't page-lock host RAM for this card's buffers (seen on RX 9070 XT at 4 GB). Give the group 8 GB, or pin `MINERS=bz`. The entrypoint moves on after `NO_SHARE_TIMEOUT` either way. |
| krig: HIP runtime / `hipErrorNoDevice` | Try `KRIG_EXTRA_ARGS=--rocm-runtime 7` (the image ships ROCm 7.2; krig tries HIP 6 first by default). If that fails, `MINERS=srb bz wildrig`. |
| WildRig: `CL_BUILD_PROGRAM_FAILURE` | Expected under ROCm OpenCL — WildRig targets AMD's proprietary driver. That's why it's last in the list. |
| `no OpenCL devices found` but rocminfo works | OpenCL ICD missing — check `/etc/OpenCL/vendors/amdocl64.icd` exists and points to a real `libamdocl64.so`. |
| Shares rejected as stale, pool latency > ~150 ms | Node is far from the pool region. With `POOL_AUTO=1` (default) the entrypoint picks the nearest region of whichever pool is in use; check the `Probing ... regions` lines. |
| `WARNING: Pearl mainnet addresses start with 'prl1p'` | Wrong wallet. Wrapped Pearl (WPRL, an Ethereum `0x…` address) is not a mining payout address. |
| Instance keeps restarting | Batch priority nodes get reallocated; that's normal. Check for `ERROR: set the WALLET` in logs. |
| Works locally, fails on Salad | Salad's AMD path is ROCm-on-WSL, not native ROCm; only test on Salad. |

### Not yet wired up

- **MDL merge mining.** HeroMiners lets you earn modelOS (MDL) on top of PRL
  with the same shares. It needs an MDL address passed alongside the PRL one;
  the exact field format wasn't confirmed when this fork was made. Add it via
  the `*_EXTRA_ARGS` variables once you have it.
- **Hashrate floor (`HASHRATE_MIN`).** A per-group minimum in TH/s: a worker
  whose miner-reported rate stays under it for ten minutes would be handed
  back to Salad. This is the only check that can see a merely *weak* host,
  as opposed to a broken one. Two cases from 2026-09-25 that nothing catches
  today: an RX 9070 XT running 103 to 106 TH/s in a group of eight doing 119
  to 135 (AMD exposes no watts or temperature under Salad), and an RTX 5080
  Laptop pinned by its owner's power profile at 95 W and 96 TH/s, cool at
  66 °C, next to another at 175 W and 130 TH/s (laptops report no power
  limit, so the cap is invisible). Both were still profitable, and the
  classes had no spare machines to swap to, so this stays unbuilt for now.
  When built it would sit in `host_check_tick` next to the NVIDIA checks and
  use `parse_hashrate` on the miner log; the floor is per class, so it is a
  group variable, not a default.

## Benchmarking the miners (`pearl-salad-bench`)

The production image picks the first miner that gets a share, which is a
compatibility test, not a speed test. Miners don't change often, so instead of
benchmarking on every start there is a separate image, built from the same
Dockerfile with the same miner binaries, that you run when you want to know
which miner is fastest on a GPU class (for example after a miner ships a big
update):

```
ghcr.io/<you>/pearl-salad-bench:<same tag as production>
```

Deploy it exactly like the production image (one replica, one GPU class, same
`WALLET`). It mines with each miner in turn for `BENCH_SECONDS` (default 300),
parses the hashrate the miner reports, applies that miner's devfee, and prints:

```
 MINER    STATUS   REPORTED TH/s  SAMPLES  SHARES  DEVFEE EFFECTIVE TH/s
 krig     ok              49.11        7       5      0%          49.11
 srb      ok              41.92       14       1      2%          41.08
 bz       ok              33.43        8       0      2%          32.76
 wildrig  failed              0        0       0      0%           0.00
 RECOMMENDED for this GPU class:  MINERS=krig
```

(real run, RX 9060 XT, 2026-09-24; the BzMiner row is what the fixed parser
produces from that run's log). Then it keeps mining with the winner until you stop the group, so the paid
node time isn't wasted. Set `MINERS=<winner>` on the production group for that
GPU class. A Salad GPU class pins the card model, so one run per class is
enough until a miner update changes the picture.

Miners within 3% of the top are treated as a tie and the lower devfee wins:
reported rates are only accurate to a few percent, and the pool's 24-hour
worker figure is what actually pays.

| Variable | Default | Meaning |
|---|---|---|
| `BENCH_SECONDS` | `300` | mining window per miner |
| `BENCH_SKIP_SAMPLES` | `2` | warm-up hashrate reports ignored before taking the median |
| `MINERS` | all four | which miners to test, in order |
| `BENCH_THEN` | `mine` | `mine` with the winner, `hold` (idle `BENCH_HOLD` s, then exit) or `exit` (Salad restarts the container, so stop the group once you've read the table) |

The hashrate parser and share counter are verified against the real Salad
output of all four miners (krig `Total:` lines, SRBMiner's colour-coded stats
table, BzMiner's `34.07th` unit and `shares=N` counter, WildRig's `n/a TH/s`).
If a future miner version changes its wording and shows `failed` with hashrate
lines visible in the log, paste those lines and the parser needs a rule.

## Releases

Images are versioned with git tags. The workflow builds every push to `main`
as `:latest` (for testing), and every tag `vX.Y.Z` as `:vX.Y.Z` and `:vX.Y`.
Release tags never move, so Salad groups pinned to one keep running the exact
build you tested. The entrypoint prints the version as its first log line.

To cut a release after testing `:latest` on one replica:

```bash
git tag -a v1.1.0 -m "what changed" && git push origin v1.1.0
```

Bump the **patch** number for miner version bumps and doc fixes, **minor** for
new behaviour (new miner, new pool, new env var), **major** if an env var
changes meaning or a default pool switches.

| Version | Date | Notes |
|---|---|---|
| v1.4.0 | 2026-09-26 | In-container log shipping to Axiom (`AXIOM_TOKEN`, off with `LOG_SHIP=0`), because Salad's external-logging forwarder has delivered nothing since 12:32 UTC 25 Sep while the portal and the containers' own network work. Same `common.sh`/`entrypoint.sh`/`bench.sh` as pearl-salad-nvidia v1.6.0. |
| v1.3.0 | 2026-09-25 | Two node traps. `POOL_CHECK`: after region selection, a TLS handshake with certificate verification against the pool; no handshake (even to the global endpoint) hands the replica back to Salad at once, an unverifiable certificate marks the network as TLS-intercepting and skips krig. `MAX_FAILED_PASSES`: a full pass through `MINERS` with no accepted share from any miner hands the replica back instead of retrying forever; the bench does the same when no miner produced a hashrate. Both came from Salad laptop hosts on 2026-09-25: one where no TLS connect to 8048 ever completed (GPU idle, billed anyway), one where an intercepting network made krig refuse the pool. Same `common.sh`/`entrypoint.sh`/`bench.sh` as pearl-salad-nvidia v1.5.0. |
| v1.2.2 | 2026-09-24 | BzMiner prints its device table every 5 min instead of every 30 s (Salad's group log view caps at 1000 rows and a 5-node BzMiner group filled it in 20 min); `--no-color`. Detection unchanged (uses the per-minute `shares=N` line). |
| v1.2.1 | 2026-09-24 | Bench parser: BzMiner summary rows carry `pool hr | miner hr` once shares arrive; take the miner column, not the pool estimate. RX 9070 XT results: BzMiner 126 TH/s beats SRBMiner 91; krig fails its pinned-memory allocation at 4 GB. Per-class `MINERS=` table. |
| v1.2.0 | 2026-09-24 | Benchmark image `pearl-salad-bench` (same Dockerfile, `bench` stage) and shared `common.sh`. Share detector now understands BzMiner's `shares=N` counter (BzMiner has no "accepted" wording, so v1.1.0 could never confirm it). Diagnostics when a miner is dropped. First bench on RX 9060 XT: krig 49.1 > SRBMiner 42.3 > BzMiner ~33 TH/s; WildRig doesn't hash. |
| v1.1.0 | 2026-09-23 | Entrypoint hardening: bounded miner log (was unbounded; a few MB/day), SIGTERM handled as PID 1, a miner that exits after getting shares is restarted rather than replaced, share detector no longer matches "accepting"/"accepted connection", `NO_SHARE_TIMEOUT` default 600. BzMiner 100.36. |
| v1.0.0 | 2026-09-23 | First verified release: krig-miner on Kryptex (TLS), RX 9060 XT at 51.9 TH/s |

## Files

- `Dockerfile` — image definition (ROCm 7.2 base + krig-miner, SRBMiner, BzMiner, WildRig); two stages, `miner` (production) and `bench`
- `common.sh` — shared by both entrypoints: GPU check, pool region probe, miner commands, share detector, hashrate parser
- `entrypoint.sh` — production: miner selection by accepted shares
- `bench.sh` — benchmark image: hashrate table + `MINERS=` recommendation
- `.github/workflows/build.yml` — builds and pushes to GHCR on every push to `main`
