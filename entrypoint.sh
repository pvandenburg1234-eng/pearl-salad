#!/bin/sh
# Entrypoint for the WildRig / SaladCloud AMD image.
# Do NOT export LD_LIBRARY_PATH or PYTHONPATH here - Salad injects them.

set -u

if [ "${WALLET:-REPLACE_WITH_YOUR_WALLET}" = "REPLACE_WITH_YOUR_WALLET" ]; then
  echo "ERROR: set the WALLET environment variable in your SaladCloud container group." >&2
  exit 1
fi

WORKER_NAME="${SALAD_MACHINE_ID:-${WORKER:-salad01}}"
# Salad machine ids are long UUIDs; pools usually cap worker names, so trim.
WORKER_NAME="$(echo "$WORKER_NAME" | tr -cd 'A-Za-z0-9_-' | cut -c1-24)"

echo "=== GPU readiness check (rocminfo) ==="
echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-<unset>}"
if command -v rocminfo >/dev/null 2>&1; then
  rocminfo 2>&1 | grep -E 'Name:|Marketing Name|gfx|HSA_STATUS' | head -20
else
  echo "rocminfo not found in image (unexpected)"
fi

echo "=== OpenCL platforms (clinfo) ==="
clinfo -l 2>&1 | head -20 || true

# ROCm's OpenCL compiler doesn't build every WildRig ProgPoW kernel variant.
# WildRig exits on CL_BUILD_PROGRAM_FAILURE, so try each variant in turn and
# only treat a run as "working" if it survives longer than MIN_RUN_SECONDS.
# Override with PROGPOW_KERNELS="1" to pin one, or WILDRIG_EXTRA_ARGS for
# any other flags.
PROGPOW_KERNELS="${PROGPOW_KERNELS:-1 2 0}"
MIN_RUN_SECONDS="${MIN_RUN_SECONDS:-90}"

run_miner() {
  kernel="$1"
  echo "=== Starting WildRig: algo=$ALGO pool=$POOL worker=$WORKER_NAME progpow-kernel=$kernel ==="
  start=$(date +%s)
  /opt/wildrig/wildrig-multi \
    --algo "$ALGO" \
    --url "$POOL" \
    --user "$WALLET.$WORKER_NAME" \
    --pass x \
    --opencl-platforms amd \
    --no-adl --no-igcl --no-sysfs \
    --progpow-kernel "$kernel" \
    ${WILDRIG_EXTRA_ARGS:-}
  rc=$?
  elapsed=$(( $(date +%s) - start ))
  echo "=== WildRig exited rc=$rc after ${elapsed}s (kernel=$kernel) ==="
  [ "$elapsed" -ge "$MIN_RUN_SECONDS" ]
}

while :; do
  for k in $PROGPOW_KERNELS; do
    if run_miner "$k"; then
      # Ran for a while then died (pool drop, node hiccup): keep the same
      # kernel, restart immediately.
      PROGPOW_KERNELS="$k"
      break
    fi
    echo "=== kernel $k failed fast, trying next ==="
  done
  echo "=== restarting in 15s ==="
  sleep 15
done
