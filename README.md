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
   `POOL` is a `kryptex.network` address. Verified 2026-09-23 on a Salad
   RX 7800 XT that it detects the GPU (gfx1101) and picks an RDNA3 kernel;
   hashing itself is unverified.
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
RX 6800 XT ~24. Compare against an RTX 3080 at ~105.

## 1. Get the image built (no Docker needed)

1. Push this folder to a **public** GitHub repository (this one is
   `pearl-salad`).
2. On GitHub open the **Actions** tab — the `build-and-push` workflow runs
   automatically (~5–10 min) and pushes `ghcr.io/<you>/pearl-salad:latest`.
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
| Image | `ghcr.io/<you>/pearl-salad:latest` |
| Replicas | `1` for testing |
| GPU | an **AMD** class (RX 7000 / RX 9000 preferred; RX 6000 works at lower rates). Don't put NVIDIA classes in the same group. |
| vCPU / RAM | 2 vCPU / 4 GB |
| Storage | smallest |
| Priority | Batch |
| Command | *(leave empty)* |
| Gateway / health probes | none / off |

Environment variables:

| Name | Value |
|---|---|
| `WALLET` | your Pearl address (`prl1p…`) — **required** |
| `POOL` | `stratum+tcp://prl.kryptex.network:7048` (default; Kryptex, 1% fee, dashboard at `pool.kryptex.com/prl`). Kryptex is the only pool krig-miner will talk to, and 1% pool fee + krig's 0% devfee beats any 0% pool + SRBMiner's 2% devfee. The **region is auto-selected** at startup by TCP latency from the node (`prl prl-us prl-eu prl-br prl-sg prl-hk prl-ru prl-ae`); the log shows the probe results. Set `POOL_AUTO=0` to use `POOL` exactly as given. Alternative: HeroMiners, `stratum+tcp://ca.pearl.herominers.com:1200` (0% fee, PPS+; regions `ca us us2 us3 de es fi fr ru tr hk sg kr au br` are auto-probed the same way; krig is skipped there and SRBMiner takes over). |
| `WORKER` | optional label; Salad's machine id is used if unset |
| `MINERS` | order to try, default `krig srb bz wildrig`. Pin one with e.g. `MINERS=srb` |
| `NO_SHARE_TIMEOUT` | seconds a miner gets to produce an accepted share before the next is tried (default `300`) |
| `KRIG_EXTRA_ARGS` / `SRB_EXTRA_ARGS` / `BZ_EXTRA_ARGS` / `WILDRIG_EXTRA_ARGS` | optional extra flags per miner (e.g. `KRIG_EXTRA_ARGS=--rocm-runtime 7`) |

There is no `ALGO` variable: every miner spells pearlhash differently
(`--coin pearl`, `--algorithm pearlhash`, `-a pearl`, `--algo pearlhash`), so
the entrypoint hardcodes it per miner.

## 4. Verify

Open the container's logs in the Salad portal. You should see:

1. `rocminfo` listing an agent with a `gfx…` name (GPU visible).
2. `clinfo -l` showing an AMD platform.
3. `Probing Kryptex Pearl regions` followed by `Using nearest region`.
4. `=== [krig] starting ...` then, within a few minutes,
   `=== [krig] ACCEPTED SHARE - this miner works on this node ===` (or the
   same for `srb`, `bz` or `wildrig` if earlier miners were skipped).

Then check `https://pool.kryptex.com/prl` with your wallet address to see
hashrate and estimated earnings; compare that to what Salad bills per hour.

### Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `HSA_STATUS_ERROR_OUT_OF_RESOURCES` in rocminfo | Image ROCm < 7.1 or something overwrote `LD_LIBRARY_PATH`. Don't set those in Dockerfile/entrypoint. |
| `no accepted share after 300s - killing and trying next miner` | That miner can't hash on this node's driver stack; the entrypoint moves on. Once you see `ACCEPTED SHARE - this miner works`, pin it with `MINERS=<name>` to skip the probing on future reallocations. |
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

## Files

- `Dockerfile` — image definition (ROCm 7.2 base + krig-miner, SRBMiner, BzMiner, WildRig)
- `entrypoint.sh` — readiness checks, pool region probe, miner selection by accepted shares
- `.github/workflows/build.yml` — builds and pushes to GHCR on every push to `main`
