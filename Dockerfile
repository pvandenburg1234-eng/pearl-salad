# ============================================================================
#  WildRig GPU miner for SaladCloud  (AMD GPU classes, ROCm-on-WSL / DXG)
#  Mines Quai (KawPow) by default; also does Pearl/PRL (PearlHash) via env.
#
#  How AMD GPUs work on SaladCloud (per Salad's AMD/ROCm docs):
#    * The GPU is /dev/dxg (WSL bridge). There is NO /dev/kfd or /dev/dri.
#    * The host injects librocdxg (/opt/rocm-host/lib), the WSL driver libs
#      (/usr/lib/wsl/lib) and a DXG-capable amd-smi (/opt/rocm-wsl), and sets
#      HSA_ENABLE_DXG_DETECTION=1 plus the LD_LIBRARY_PATH / PATH ordering.
#    * The host does NOT provide a ROCm runtime - the image must ship ROCm
#      7.1 or newer. Anything older fails with HSA_STATUS_ERROR_OUT_OF_RESOURCES.
#    * NEVER assign LD_LIBRARY_PATH / PYTHONPATH in the image or entrypoint -
#      that erases the injected bridge and the GPU disappears.
#    * `rocminfo` is the official readiness check; the entrypoint runs it first.
#
#  ---- BUILD & PUSH ---------------------------------------------------------
#  No Docker locally? Push this folder to a GitHub repo - the included
#  .github/workflows/build.yml builds and pushes ghcr.io/<you>/wildrig-salad
#  automatically (see README.md).  With Docker:
#    docker build -t YOURUSER/wildrig-salad:latest .
#    docker push  YOURUSER/wildrig-salad:latest
#
#  ---- SaladCloud container-group settings ----------------------------------
#    Image Name : ghcr.io/<you>/wildrig-salad:latest   (must be a PUBLIC image)
#    Replicas   : 1   (for testing)
#    GPU        : an AMD class (RX 7000 / RX 6000). Do NOT mix with NVIDIA.
#    vCPU / RAM : 2 vCPU / 4 GB   (KawPow is GPU-bound - don't overbuy)
#    Storage    : minimum
#    Priority   : Batch (cheapest, interruptible - fine for mining)
#    Command    : leave EMPTY (the ENTRYPOINT below runs the miner)
#    Gateway    : none        Health probe : OFF
#    Environment Variables:
#      WALLET = <your payout address>            (REQUIRED)
#      POOL   = <pool host:port>                 (see options below)
#      ALGO   = kawpow (Quai)  |  pearlhash (Pearl/PRL)
#      WORKER = optional; Salad's machine id is used automatically if unset
#
#  ---- POOL / COIN options --------------------------------------------------
#    Quai (KawPow) - HeroMiners:
#      ALGO   = kawpow
#      POOL   = stratum+tcp://ca.quai.herominers.com:1185   (us./de. also exist)
#      WALLET = your Pelagus Cyprus-1 zone address (0x00... )
#    Quai (KawPow) - 2Miners (alternative):
#      POOL   = stratum+tcp://quai-kawpow.2miners.com:5555  (check 2miners.com for region ports)
#    Pearl / PRL (PearlHash):
#      ALGO   = pearlhash
#      POOL   = stratum+ssl://pool.pearlhash.xyz:9000
#      WALLET = your prl1... address
#
#  ---- HONEST NOTE ON ECONOMICS ---------------------------------------------
#    On public SaladCloud rental prices, renting a GPU to mine generally LOSES
#    money (rent >= coin yield). Treat this as a test. Deploy ONE replica for
#    24h and compare the pool's estimated daily earnings to the all-in $/hr
#    Salad bills you BEFORE scaling replicas.
# ============================================================================

# Salad-recommended AMD base (ROCm 7.2, ubuntu 24.04). Includes rocminfo.
FROM rocm/dev-ubuntu-24.04:7.2

ENV DEBIAN_FRONTEND=noninteractive

# OpenCL runtime + ICD loader so WildRig can see the AMD platform.
# Package name differs across ROCm releases, so try both.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates wget ocl-icd-libopencl1 clinfo \
    && (apt-get install -y --no-install-recommends rocm-opencl-runtime \
        || apt-get install -y --no-install-recommends rocm-opencl) \
    && mkdir -p /etc/OpenCL/vendors \
    && (ls /etc/OpenCL/vendors/amdocl64.icd >/dev/null 2>&1 \
        || echo "/opt/rocm/lib/libamdocl64.so" > /etc/OpenCL/vendors/amdocl64.icd) \
    && rm -rf /var/lib/apt/lists/*

ARG WILDRIG_VERSION=0.51.2
WORKDIR /opt/wildrig
RUN wget -qO /tmp/w.tgz \
      https://github.com/andru-kun/wildrig-multi/releases/download/${WILDRIG_VERSION}/wildrig-multi-linux-${WILDRIG_VERSION}.tar.gz \
 && tar xzf /tmp/w.tgz -C /opt/wildrig --strip-components=1 \
 && rm /tmp/w.tgz \
 && chmod +x /opt/wildrig/wildrig-multi

# NOTE: no LD_LIBRARY_PATH / HSA_ENABLE_DXG_DETECTION here on purpose -
# SaladCloud injects them; setting them in the image breaks GPU enumeration.

# Runtime defaults - override these in the SaladCloud env vars
ENV ALGO=kawpow \
    POOL=stratum+tcp://ca.quai.herominers.com:1185 \
    WALLET=REPLACE_WITH_YOUR_WALLET \
    WORKER=salad01

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
