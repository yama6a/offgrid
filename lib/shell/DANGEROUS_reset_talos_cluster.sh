#!/usr/bin/env bash
# DANGEROUS: wipes the whole cluster back to maintenance, INCLUDING all persistent data.
#
# Wipes STATE + EPHEMERAL and the `u-longhorn` data user volume. Keeps BOOT/EFI/META,
# so nodes reboot straight to maintenance with no reflash. Wiping the data volumes too means no orphaned
# replica or DB data ever survives a reset. Recoverable state comes back from git via ArgoCD; the on-disk
# data is gone for good.
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

# Every node, workers included: leaving one configured and pointed at a cluster that no longer exists is worse
# than wiping it, because it comes back as a member of nothing and nobody notices until it is needed.
RESET_IPS=("${ALL_IPS[@]}")

# All at once: every node is being wiped and rebooted anyway, so there is no reason to serialize. Output is
# prefixed with the node IP so the interleaved streams stay readable. That prefixing pipes through sed, and a
# pipeline's exit code is sed's, not talosctl's, so PIPESTATUS[0] is how we still see whether talosctl failed.
#
# Every label here must resolve to a live VolumeStatus, which means the machine config must still DECLARE that
# volume: the reset looks each one up by ID and fails the whole call if one is missing. So a label for a volume
# already dropped from the config belongs in `talosctl wipe disk <part> --drop-partition` instead, not here.
# Since Talos 1.12 this both wipes AND drops the partition, so 03c re-provisions each from free space.
WIPE_LABELS="STATE,EPHEMERAL,u-longhorn"
say "resetting ${#RESET_IPS[@]} nodes in parallel (${WIPE_LABELS}) -> maintenance"
pids=()
for ip in "${RESET_IPS[@]}"; do
  (
    talosctl reset -e "$ip" -n "$ip" \
      --system-labels-to-wipe "$WIPE_LABELS" \
      --reboot --graceful=false 2>&1 | sed "s/^/[$ip] /"
    exit "${PIPESTATUS[0]}"
  ) &
  pids+=("$!")
done

# Wait on each, not the first failure, so every node gets reset and every failure is reported.
fail=0
for i in "${!RESET_IPS[@]}"; do
  if wait "${pids[$i]}"; then
    say "[${RESET_IPS[$i]}] reset OK"
  else
    rc=$?
    echo ">> [${RESET_IPS[$i]}] reset FAILED (exit $rc)" >&2
    fail=1
  fi
done

[ "$fail" -eq 0 ] && say "all nodes reset -> maintenance." || { echo ">> one or more nodes failed to reset." >&2; exit 1; }

# Standalone reset only: a rebuild keeps the bucket and wipes the contents itself. No-ops cleanly with no
# AWS creds. Best-effort, a teardown hiccup should not mask the node reset.
if [ "${REBUILD_IN_PROGRESS:-0}" != 1 ]; then
  say "tearing down the S3 backup bucket + IAM (empty + terraform destroy)"
  ASSUME_YES=1 bash "${SCRIPT_DIR}/13_s3_backup_bucket.sh" destroy \
    || echo ">> S3 teardown did not complete; run 'make s3-backup-destroy' by hand." >&2
fi
