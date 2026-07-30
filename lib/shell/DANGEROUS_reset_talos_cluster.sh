#!/usr/bin/env bash
# DANGEROUS: wipes the whole cluster back to maintenance, INCLUDING all persistent data.
#
# Wipes STATE + EPHEMERAL and both data user volumes, `u-longhorn` and `u-localpath`. Keeps BOOT/EFI/META,
# so nodes reboot straight to maintenance with no reflash. Wiping the data volumes too means no orphaned
# replica or DB data ever survives a reset. Recoverable state comes back from git via ArgoCD; the on-disk
# data is gone for good.
#
# Run STANDALONE it ALSO tears down the S3 backups at the end (empty the bucket, then terraform destroy).
# A rebuild sets REBUILD_IN_PROGRESS=1 and skips that: it keeps the bucket and IAM and only wipes contents.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"   # dockerized talosctl() (mounts CLUSTER_DIR) + CLUSTER_NODES from .env

# Spell out which of the two it is, so the operator knows exactly what is about to go.
S3_CLAUSE=""
[ "${REBUILD_IN_PROGRESS:-0}" != 1 ] && S3_CLAUSE=" AND DESTROY the S3 backup bucket + all its backups + IAM"
read -r -p ">> Destroy ENTIRE Talos cluster AND wipe ALL Longhorn/PVC data (u-longhorn, u-localpath)${S3_CLAUSE}? type YES: " confirm
[ "${confirm}" = "YES" ] || { echo "skipped destruction (phew!)."; exit 0; }

NODES=(); for e in "${CLUSTER_NODES[@]}"; do NODES+=("${e##*:}"); done

# All at once: every node is being wiped and rebooted anyway, so there is no reason to serialize. Output is
# prefixed with the node IP so the interleaved streams stay readable. That prefixing pipes through sed, and a
# pipeline's exit code is sed's, not talosctl's, so PIPESTATUS[0] is how we still see whether talosctl failed.
#
# --system-labels-to-wipe takes partition labels resolved against each node's VolumeStatus, not a fixed set.
# Wiping the two user volumes here is what guarantees no orphaned replica or DB data survives; 03d re-creates
# those partitions on the next config apply.
say "resetting ${#NODES[@]} nodes in parallel (STATE,EPHEMERAL,u-longhorn,u-localpath) -> maintenance"
pids=()
for ip in "${NODES[@]}"; do
  (
    talosctl reset -e "$ip" -n "$ip" \
      --system-labels-to-wipe STATE,EPHEMERAL,u-longhorn,u-localpath \
      --reboot --graceful=false 2>&1 | sed "s/^/[$ip] /"
    exit "${PIPESTATUS[0]}"
  ) &
  pids+=("$!")
done

# Wait on each, not the first failure, so every node gets reset and every failure is reported.
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

# Standalone reset only: a rebuild keeps the bucket and wipes the contents itself. No-ops cleanly with no
# AWS creds. Best-effort, a teardown hiccup should not mask the node reset.
if [ "${REBUILD_IN_PROGRESS:-0}" != 1 ]; then
  say "tearing down the S3 backup bucket + IAM (empty + terraform destroy)"
  ASSUME_YES=1 bash "${SCRIPT_DIR}/13_s3_backup_bucket.sh" destroy \
    || echo ">> S3 teardown did not complete; run 'make s3-backup-destroy' by hand." >&2
fi
