# Quai (KawPow) GPU miner container for SaladCloud — AMD GPUs

Container image that runs [WildRig-Multi](https://github.com/andru-kun/wildrig-multi)
on SaladCloud AMD GPU classes (RX 6000 / RX 7000) and mines Quai over KawPow.

**Read the economics note in `Dockerfile` first.** Renting GPUs to mine is usually
a net loss; test with one replica for 24 h before scaling.

## 1. Get the image built (no Docker needed)

1. Create a free GitHub account if you don't have one, then create a new
   **public** repository (e.g. `wildrig-salad`).
2. From this folder, in PowerShell:

   ```powershell
   git remote add origin https://github.com/<YOU>/wildrig-salad.git
   git push -u origin main
   ```

3. On GitHub open the **Actions** tab — the `build-and-push` workflow runs
   automatically (~5–10 min) and pushes `ghcr.io/<you>/wildrig-salad:latest`.
4. Make the package public: your GitHub profile → **Packages** →
   `wildrig-salad` → **Package settings** → **Change visibility** → Public.
   SaladCloud can only pull public images (or you'd have to configure registry
   credentials in the container group).

## 2. Get a Quai wallet address

Install the [Pelagus](https://pelaguswallet.io/) browser wallet, create a
wallet, and copy the **Cyprus-1** zone address (starts with `0x00`). Pools
require a Cyprus-1 address for payouts.

## 3. Deploy on SaladCloud

Portal → **Container Groups → Deploy**:

| Setting | Value |
|---|---|
| Image | `ghcr.io/<you>/wildrig-salad:latest` |
| Replicas | `1` for testing |
| GPU | an **AMD** class (e.g. RX 7800 XT / 7900 XTX). Don't put NVIDIA classes in the same group. |
| vCPU / RAM | 2 vCPU / 4 GB |
| Storage | smallest |
| Priority | Batch |
| Command | *(leave empty)* |
| Gateway / health probes | none / off |

Environment variables:

| Name | Value |
|---|---|
| `WALLET` | your Cyprus-1 address (`0x00…`) — **required** |
| `POOL` | `stratum+tcp://ca.quai.herominers.com:1185` (default; `us.` / `de.` regions also exist) |
| `ALGO` | `kawpow` (default) |
| `WORKER` | optional label; Salad's machine id is used if unset |
| `WILDRIG_EXTRA_ARGS` | optional extra WildRig flags |
| `PROGPOW_KERNELS` | kernel variants to try, default `1 2 0` (ROCm's OpenCL compiler can't build every variant; the entrypoint auto-falls-back) |

## 4. Verify

Open the container's logs in the Salad portal. You should see:

1. `rocminfo` listing an agent with a `gfx…` name (GPU visible).
2. `clinfo -l` showing an AMD platform.
3. WildRig printing accepted shares within a couple of minutes.

Then check `https://quai.herominers.com/` with your wallet address to see
hashrate and estimated earnings; compare that to what Salad bills per hour.

### Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `HSA_STATUS_ERROR_OUT_OF_RESOURCES` in rocminfo | Image ROCm < 7.1 or something overwrote `LD_LIBRARY_PATH`. Don't set those in Dockerfile/entrypoint. |
| `CL_BUILD_PROGRAM_FAILURE when calling clBuildProgram` | ROCm's OpenCL compiler rejected that ProgPoW kernel variant; the entrypoint tries `--progpow-kernel 1`, `2`, `0` in turn. Pin the one that works with `PROGPOW_KERNELS=1`. |
| `no OpenCL devices found` but rocminfo works | OpenCL ICD missing — check `/etc/OpenCL/vendors/amdocl64.icd` exists and points to a real `libamdocl64.so`. |
| Instance keeps restarting | Batch priority nodes get reallocated; that's normal. Check for `ERROR: set the WALLET` in logs. |
| Works locally, fails on Salad | Salad's AMD path is ROCm-on-WSL, not native ROCm; only test on Salad. |

## Files

- `Dockerfile` — image definition (ROCm 7.2 base + WildRig)
- `entrypoint.sh` — readiness checks + miner launch
- `.github/workflows/build.yml` — builds and pushes to GHCR on every push to `main`
