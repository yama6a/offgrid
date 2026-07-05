#!/usr/bin/env bash
#
# DANGEROUS, wipes the whole cluster back to maintenance, INCLUDING all persistent data.
#
# Wipes STATE + EPHEMERAL (Talos persistent state + k8s/etcd) AND `u-longhorn` (the dedicated Longhorn
# user volume, /dev/nvme0n1p7, provisioned by 03d). Keeps BOOT/EFI/META, so nodes reboot straight to
# maintenance, NO reflash needed. Wiping Longhorn too means NO orphaned replica data ever survives a
# reset: a rebuilt cluster always starts from a clean disk (the old volume CRs die with etcd anyway).
# Recoverable state (k8s objects) comes back from git via ArgoCD; the Longhorn data is gone for good.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"   # dockerized talosctl() (mounts CLUSTER_DIR) + CLUSTER_NODES from .env

read -r -p ">> Destroy ENTIRE Talos cluster AND wipe ALL Longhorn/PVC data (u-longhorn)? type YES: " confirm
[ "${confirm}" = "YES" ] || { echo "skipped destruction (phew!)."; exit 0; }

# Node IPs from .env (CLUSTER_NODES "host:ip" -> IPs).
NODES=(); for e in "${CLUSTER_NODES[@]}"; do NODES+=("${e##*:}"); done

# Reset every node at once, they're all being wiped + rebooted (graceful=false), so there's no
# reason to serialize. Each runs in its own subshell/container; output is prefixed with the node IP
# so the interleaved streams stay readable. PIPESTATUS[0] propagates talosctl's status past the sed.
#
# --system-labels-to-wipe takes partition labels resolved against each node's VolumeStatus (NOT a fixed
# STATE/EPHEMERAL/META set): u-longhorn is the Longhorn user volume (03d UserVolumeConfig name `longhorn`
# -> partition label `u-longhorn`). Wiping it here is what guarantees no orphaned replica data survives.
# 03d re-creates the EPHEMERAL + u-longhorn partitions on the next config apply.
say "resetting ${#NODES[@]} nodes in parallel (STATE,EPHEMERAL,u-longhorn) -> maintenance"
pids=()
for ip in "${NODES[@]}"; do
  (
    talosctl reset -e "$ip" -n "$ip" \
      --system-labels-to-wipe STATE,EPHEMERAL,u-longhorn \
      --reboot --graceful=false 2>&1 | sed "s/^/[$ip] /"
    exit "${PIPESTATUS[0]}"
  ) &
  pids+=("$!")
done

# wait on each (not the first failure) so all nodes get reset and every failure is reported.
fail=0
for i in "${!NODES[@]}"; do
  if wait "${pids[$i]}"; then
    say "[${NODES[$i]}] reset OK"
  else
    rc=$?
    echo ">> [${NODES[$i]}] reset FAILED (exit $rc)" >&2
    fail=1
  fi
done

[ "$fail" -eq 0 ] && say "all nodes reset -> maintenance." || { echo ">> one or more nodes failed to reset." >&2; exit 1; }
