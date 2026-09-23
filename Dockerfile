# ============================================================================
#  Pearl (PRL, pearlhash) GPU miner for SaladCloud  (AMD GPU classes,
#  ROCm-on-WSL / DXG)
#
#  Forked from the Quai/KawPow image (wildrig-salad). Pearl is a
#  proof-of-useful-work chain: every share is an int8 matrix-multiply plus a
#  STARK proof, so hashrates read in TH/s and shares are heavy.
#
#  Ships FOUR miners and lets the entrypoint pick the first one that actually
#  produces accepted shares on the node it lands on:
#    1. krig-miner    (Kryptex; ROCm/HIP backend, RDNA2/3/4, 0% devfee)
#    2. SRBMiner-MULTI (pearlhash on AMD+NVIDIA, 2% devfee)
#    3. BzMiner        (pearl on AMD+NVIDIA, 2% devfee)
#    4. WildRig-Multi  (pearlhash, AMD support fixed in 0.51.2, 0% devfee;
#                       known to struggle under ROCm OpenCL - last resort)
#  TeamRedMiner is gone: it has no pearlhash support.
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
#  .github/workflows/build.yml builds and pushes ghcr.io/<you>/pearl-salad
#  automatically (see README.md).  With Docker:
#    docker build -t YOURUSER/pearl-salad:latest .
#    docker push  YOURUSER/pearl-salad:latest
#
#  ---- SaladCloud container-group settings ----------------------------------
#    Image Name : ghcr.io/<you>/pearl-salad:latest   (must be a PUBLIC image)
#    Replicas   : 1   (for testing)
#    GPU        : an AMD class (RX 9000 / RX 7000 / RX 6000). Do NOT mix with NVIDIA.
#    vCPU / RAM : 2 vCPU / 4 GB
#    Storage    : minimum
#    Priority   : Batch (cheapest, interruptible - fine for mining)
#    Command    : leave EMPTY (the ENTRYPOINT below runs the miner)
#    Gateway    : none        Health probe : OFF
#    Environment Variables:
#      WALLET = <your Pearl address, prl1p...>   (REQUIRED)
#      POOL   = <pool host:port>                 (see options below)
#      MINERS = optional; default "krig srb bz wildrig"
#      WORKER = optional; Salad's machine id is used automatically if unset
#
#  ---- POOL options ---------------------------------------------------------
#    Pearl - Kryptex, 1% fee, DEFAULT. The only pool krig-miner (0% devfee)
#    will talk to. Region auto-selected by latency at startup (prl prl-us
#    prl-eu prl-br prl-sg prl-hk prl-ru prl-ae; POOL_AUTO=0 to pin). TLS port
#    8048 because krig-miner refuses plain TCP (7048 works for the others):
#      POOL   = stratum+ssl://prl.kryptex.network:8048
#    Pearl - HeroMiners, 0% fee (alternative; krig is skipped, SRBMiner 2%
#    devfee takes over; regions ca us us2 us3 de es fi fr ru tr hk sg kr au br):
#      POOL   = stratum+tcp://ca.pearl.herominers.com:1200
#
#  ---- HONEST NOTE ON ECONOMICS ---------------------------------------------
#    On public SaladCloud rental prices, renting a GPU to mine generally LOSES
#    money (rent >= coin yield). Pearl's difficulty has been climbing fast since
#    its April 2026 launch. Treat this as a test. Deploy ONE replica for 24h
#    and compare the pool's estimated daily earnings to the all-in $/hr Salad
#    bills you BEFORE scaling replicas.
# ============================================================================

# Salad-recommended AMD base (ROCm 7.2, ubuntu 24.04). Includes rocminfo and
# the HIP runtime (libamdhip64) that krig-miner needs.
FROM rocm/dev-ubuntu-24.04:7.2

ENV DEBIAN_FRONTEND=noninteractive

# Set by the build workflow to the git tag (v1.2.3) or branch; the entrypoint
# prints it so the Salad log says which image version a node is running.
ARG IMAGE_VERSION=dev
ENV IMAGE_VERSION=${IMAGE_VERSION}

# OpenCL runtime + ICD loader so the OpenCL miners can see the AMD platform.
# Package name differs across ROCm releases, so try both. The ROCm package can
# register the AMD platform twice (two .icd files); keep exactly one so the
# GPU isn't enumerated twice.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates wget curl ocl-icd-libopencl1 clinfo procps \
    && (apt-get install -y --no-install-recommends rocm-opencl-runtime \
        || apt-get install -y --no-install-recommends rocm-opencl) \
    && mkdir -p /etc/OpenCL/vendors \
    && (ls /etc/OpenCL/vendors/amdocl64.icd >/dev/null 2>&1 \
        || echo "/opt/rocm/lib/libamdocl64.so" > /etc/OpenCL/vendors/amdocl64.icd) \
    && rm -rf /var/lib/apt/lists/* \
    && for f in /etc/OpenCL/vendors/*; do [ "$f" = /etc/OpenCL/vendors/amdocl64.icd ] || rm -f "$f"; done \
    && ls -la /etc/OpenCL/vendors && cat /etc/OpenCL/vendors/*

# Each miner tarball lays itself out differently (some have a top-level dir,
# some don't). Extract into a scratch dir, find the binary, and move whatever
# directory contains it to /opt/<name>. That way a version bump can't break
# the build because the archive layout changed.

# --- 1. krig-miner (Kryptex) -------------------------------------------------
ARG KRIG_VERSION=1.5.2
RUN wget -qO /tmp/krig.tgz \
      https://github.com/kryptex/krig-miner/releases/download/v${KRIG_VERSION}/krig-miner-${KRIG_VERSION}-linux-x64.tar.gz \
 && mkdir -p /tmp/krig && tar xzf /tmp/krig.tgz -C /tmp/krig \
 && bin="$(find /tmp/krig -type f -name 'krig-miner*' ! -name '*.txt' ! -name '*.md' | head -1)" \
 && [ -n "$bin" ] && mv "$(dirname "$bin")" /opt/krig \
 && ( [ -x /opt/krig/krig-miner ] || mv "/opt/krig/$(basename "$bin")" /opt/krig/krig-miner ) \
 && chmod +x /opt/krig/krig-miner && rm -rf /tmp/krig /tmp/krig.tgz \
 && ls -la /opt/krig

# --- 2. SRBMiner-MULTI ------------------------------------------------------
ARG SRB_VERSION=3.6.9
RUN wget -qO /tmp/srb.tgz \
      https://github.com/doktor83/SRBMiner-Multi/releases/download/${SRB_VERSION}/SRBMiner-Multi-$(echo ${SRB_VERSION} | tr . -)-Linux.tar.gz \
 && mkdir -p /tmp/srb && tar xzf /tmp/srb.tgz -C /tmp/srb \
 && bin="$(find /tmp/srb -type f -name SRBMiner-MULTI | head -1)" \
 && [ -n "$bin" ] && mv "$(dirname "$bin")" /opt/srb \
 && chmod +x /opt/srb/SRBMiner-MULTI && rm -rf /tmp/srb /tmp/srb.tgz \
 && ls -la /opt/srb

# --- 3. BzMiner --------------------------------------------------------------
ARG BZ_VERSION=100.31
RUN wget -qO /tmp/bz.tgz \
      https://github.com/bzminer/bzminer/releases/download/v${BZ_VERSION}/bzminer_v${BZ_VERSION}_linux.tar.gz \
 && mkdir -p /tmp/bz && tar xzf /tmp/bz.tgz -C /tmp/bz \
 && bin="$(find /tmp/bz -type f -name bzminer | head -1)" \
 && [ -n "$bin" ] && mv "$(dirname "$bin")" /opt/bz \
 && chmod +x /opt/bz/bzminer && rm -rf /tmp/bz /tmp/bz.tgz \
 && ls -la /opt/bz

# --- 4. WildRig-Multi (last resort) ----------------------------------------
ARG WILDRIG_VERSION=0.51.2
RUN wget -qO /tmp/w.tgz \
      https://github.com/andru-kun/wildrig-multi/releases/download/${WILDRIG_VERSION}/wildrig-multi-linux-${WILDRIG_VERSION}.tar.gz \
 && mkdir -p /tmp/w && tar xzf /tmp/w.tgz -C /tmp/w \
 && bin="$(find /tmp/w -type f -name wildrig-multi | head -1)" \
 && [ -n "$bin" ] && mv "$(dirname "$bin")" /opt/wildrig \
 && chmod +x /opt/wildrig/wildrig-multi && rm -rf /tmp/w /tmp/w.tgz \
 && ls -la /opt/wildrig

# NOTE: no LD_LIBRARY_PATH / HSA_ENABLE_DXG_DETECTION here on purpose -
# SaladCloud injects them; setting them in the image breaks GPU enumeration.

# Runtime defaults - override these in the SaladCloud env vars
ENV POOL=stratum+ssl://prl.kryptex.network:8048 \
    WALLET=REPLACE_WITH_YOUR_WALLET \
    WORKER=salad01 \
    MINERS="krig srb bz wildrig" \
    NO_SHARE_TIMEOUT=300

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
