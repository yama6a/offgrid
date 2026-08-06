#!/usr/bin/env bash
# DANGEROUS: wipes the whole cluster back to maintenance, INCLUDING all persistent data.
#
# Wipes STATE + EPHEMERAL and the `u-longhorn` data user volume. Keeps BOOT/EFI/META,
# so nodes reboot straight to maintenance with no reflash. Wiping the data volumes too means no orphaned
# replica or DB data ever survives a reset. Recoverable state comes back from git via ArgoCD; the on-disk
# data is gone for good.
#
# Workers are reset first and must be back in maintenance before the control plane is touched. See the comment
# on the ordering below; getting it wrong strands a worker with no API and costs a physical reflash.
#
# Run STANDALONE it ALSO tears down the S3 backups at the end (empty the bucket, then terraform destroy).
# A rebuild sets REBUILD_IN_PROGRESS=1 and skips that: it keeps the bucket and IAM and only wipes contents.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"   # dockerized talosctl() (mounts CLUSTER_DIR) + the inventory node arrays

# Spell out which of the two it is, so the operator knows exactly what is about to go.
S3_CLAUSE=""
[ "${REBUILD_IN_PROGRESS:-0}" != 1 ] && S3_CLAUSE=" AND DESTROY the S3 backup bucket + all its backups + IAM"
confirm_word_always YES "Destroy ENTIRE Talos cluster AND wipe ALL Longhorn/PVC data (u-longhorn)${S3_CLAUSE}?" \
  || { echo "skipped destruction (phew!)."; exit 0; }

# ---- knobs ------------------------------------------------------------------
# Every label here must resolve to a live VolumeStatus, which means the machine config must still DECLARE that
# volume: the reset looks each one up by ID and fails the whole call if one is missing. So a label for a volume
# already dropped from the config belongs in `talosctl wipe disk <part> --drop-partition` instead, not here.
# Since Talos 1.12 this both wipes AND drops the partition, so 03c re-provisions each from free space.
WIPE_LABELS="STATE,EPHEMERAL,u-longhorn"
RESET_TIMEOUT="10m"   # per node. talosctl's own default is 30m, which just retries silently for half an hour
MAINT_WAIT=300        # secs for a reset worker to answer the maintenance API again

# reset_group <label> <ip...>: reset every node in the group at once, then wait for all of them. Output is
# prefixed with the node IP so the interleaved streams stay readable. That prefixing pipes through sed, and a
# pipeline's exit code is sed's, not talosctl's, so PIPESTATUS[0] is how we still see whether talosctl failed.
reset_group() {
  local label="$1"; shift
  local ips=("$@") pids=() fail=0 ip i rc
  say "resetting ${#ips[@]} ${label} node(s) in parallel (${WIPE_LABELS}) -> maintenance"
  for ip in "${ips[@]}"; do
    (
      talosctl reset -e "$ip" -n "$ip" \
        --system-labels-to-wipe "$WIPE_LABELS" \
        --timeout "$RESET_TIMEOUT" \
        --reboot --graceful=false 2>&1 | sed "s/^/[$ip] /"
      exit "${PIPESTATUS[0]}"
    ) &
    pids+=("$!")
  done
  # Wait on each, not the first failure, so every node in the group is reported.
  for i in "${!ips[@]}"; do
    if wait "${pids[$i]}"; then
      say "[${ips[$i]}] reset OK"
    else
      rc=$?
      echo ">> [${ips[$i]}] reset FAILED (exit $rc)" >&2
      fail=1
    fi
  done
  return "$fail"
}

# Workers FIRST, and all the way back into maintenance, before the control plane is touched. A worker holds no
# CA key of its own: its apid gets a server certificate signed by trustd, which runs ONLY on control-plane
# nodes (port 50001). So wiping the control plane while a worker is mid-reset kills that worker's apid for
# good, its reset can never finish, and no API is left to retry it. Recovering that needs a physical reflash.
#
# Waiting for maintenance, not just for the reset call to return, is the point: the guarantee we need is that
# the worker no longer depends on the control plane at all.
if [ "${#WORKER_IPS[@]}" -gt 0 ]; then
  reset_group worker "${WORKER_IPS[@]}" \
    || die "a worker failed to reset. The control plane is still UP and untouched, so fix that node and re-run."
  say "confirming every worker is back on the maintenance API before the control plane goes"
  for ip in "${WORKER_IPS[@]}"; do
    printf '   %-16s ' "$ip"
    wait_talos_api "$ip" "$MAINT_WAIT" insecure || { echo "TIMEOUT"; die \
      "${ip} did not come back in maintenance within ${MAINT_WAIT}s. The control plane is still UP: fix this
       node and re-run. Do NOT reset the control plane first, or this node loses its apid and needs a reflash."; }
    echo "maintenance"
  done
fi

reset_group control-plane "${CP_IPS[@]}" \
  || { echo ">> one or more control-plane nodes failed to reset." >&2; exit 1; }
say "all nodes reset -> maintenance."

# Standalone reset only: a rebuild keeps the bucket and wipes the contents itself. No-ops cleanly with no
# AWS creds. Best-effort, a teardown hiccup should not mask the node reset.
if [ "${REBUILD_IN_PROGRESS:-0}" != 1 ]; then
  say "tearing down the S3 backup bucket + IAM (empty + terraform destroy)"
  ASSUME_YES=1 bash "${SCRIPT_DIR}/13_s3_backup_bucket.sh" destroy \
    || echo ">> S3 teardown did not complete; run 'make s3-backup-destroy' by hand." >&2
fi
