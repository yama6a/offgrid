#!/usr/bin/env bash

set -euo pipefail

cd ./03_operating_system
OUTDIR="$PWD/talos-cluster"

talosctl() { docker run --rm --network host -v "$OUTDIR:/work" -w /work \
  -e TALOSCONFIG=/work/talosconfig "ghcr.io/siderolabs/talosctl:v1.13.4" "$@"; }

read -r -p ">> Destroy ENTIRE Talos Cluster? type YES: " ok
[ "${ok}" = "YES" ] || { echo "skipped destruction (phew!)."; exit 0; }

NODES=(192.168.10.201 192.168.10.202 192.168.10.203)

# Reset every node at once — they're all being wiped + rebooted (graceful=false), so there's no
# reason to serialize. Each runs in its own subshell/container; output is prefixed with the node IP
# so the interleaved streams stay readable. PIPESTATUS[0] propagates talosctl's status past the sed.
echo ">> resetting ${#NODES[@]} nodes in parallel -> maintenance"
pids=()
for ip in "${NODES[@]}"; do
  (
    talosctl reset -e "$ip" -n "$ip" \
      --system-labels-to-wipe STATE,EPHEMERAL \
      --reboot --graceful=false 2>&1 | sed "s/^/[$ip] /"
    exit "${PIPESTATUS[0]}"
  ) &
  pids+=("$!")
done

# wait on each (not the first failure) so all nodes get reset and every failure is reported.
fail=0
for i in "${!NODES[@]}"; do
  if wait "${pids[$i]}"; then
    echo ">> [${NODES[$i]}] reset OK"
  else
    rc=$?
    echo ">> [${NODES[$i]}] reset FAILED (exit $rc)" >&2
    fail=1
  fi
done

[ "$fail" -eq 0 ] && echo ">> all nodes reset -> maintenance." || { echo ">> one or more nodes failed to reset." >&2; exit 1; }
