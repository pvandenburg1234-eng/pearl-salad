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

echo "=== Starting WildRig: algo=$ALGO pool=$POOL worker=$WORKER_NAME ==="
exec /opt/wildrig/wildrig-multi \
  --algo "$ALGO" \
  --url "$POOL" \
  --user "$WALLET.$WORKER_NAME" \
  --pass x \
  --opencl-platforms amd \
  --no-adl --no-igcl --no-sysfs \
  --print-full \
  ${WILDRIG_EXTRA_ARGS:-}
