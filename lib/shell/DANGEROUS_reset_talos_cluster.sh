#!/usr/bin/env bash
#
# DANGEROUS, wipes the whole cluster back to maintenance, INCLUDING all persistent data.
#
# Wipes STATE + EPHEMERAL (Talos persistent state + k8s/etcd) AND both data user volumes: `u-longhorn`
# (the dedicated Longhorn volume) and `u-localpath` (the local-path-provisioner volume backing CNPG + RabbitMQ),
# both provisioned by 03d on /dev/nvme0n1. Keeps BOOT/EFI/META, so nodes reboot straight to maintenance,
# NO reflash needed. Wiping the data volumes too means NO orphaned replica/DB data ever survives a reset:
# a rebuilt cluster always starts from a clean disk (the old volume CRs die with etcd anyway).
# Recoverable state (k8s objects) comes back from git via ArgoCD; the on-disk data is gone for good.
#
# When run STANDALONE (`make reset-cluster`), it ALSO tears down the off-cluster S3 backups at the end:
# empties the bucket + `terraform destroy` (bucket + IAM writer gone), via 13_s3_backup_bucket.sh destroy.
# A rebuild calls this with REBUILD_IN_PROGRESS=1 and SKIPS that — the rebuild keeps the bucket + IAM and only
# wipes the backup CONTENTS itself (so a fresh cluster starts clean). See docs/13_backups.md.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"   # dockerized talosctl() (mounts CLUSTER_DIR) + CLUSTER_NODES from .env

# Standalone reset also destroys the S3 backup infra; a rebuild (REBUILD_IN_PROGRESS=1) does not — reflect that
# in the confirmation so the operator knows exactly what's about to go.
S3_CLAUSE=""
[ "${REBUILD_IN_PROGRESS:-0}" != 1 ] && S3_CLAUSE=" AND DESTROY the S3 backup bucket + all its backups + IAM"
read -r -p ">> Destroy ENTIRE Talos cluster AND wipe ALL Longhorn/PVC data (u-longhorn, u-localpath)${S3_CLAUSE}? type YES: " confirm
[ "${confirm}" = "YES" ] || { echo "skipped destruction (phew!)."; exit 0; }

# Node IPs from .env (CLUSTER_NODES "host:ip" -> IPs).
NODES=(); for e in "${CLUSTER_NODES[@]}"; do NODES+=("${e##*:}"); done

# Reset every node at once, they're all being wiped + rebooted (graceful=false), so there's no
# reason to serialize. Each runs in its own subshell/container; output is prefixed with the node IP
# so the interleaved streams stay readable. PIPESTATUS[0] propagates talosctl's status past the sed.
#
# --system-labels-to-wipe takes partition labels resolved against each node's VolumeStatus (NOT a fixed
# STATE/EPHEMERAL/META set): u-longhorn is the Longhorn user volume and u-localpath the local-path-provisioner
# volume (03d UserVolumeConfig names `longhorn`/`localpath` -> partition labels `u-longhorn`/`u-localpath`). Wiping
# them here is what guarantees no orphaned replica/DB data survives. 03d re-creates the EPHEMERAL +
# u-longhorn + u-localpath partitions on the next config apply.
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

# S3 backup teardown — STANDALONE reset only (a rebuild keeps the bucket + wipes contents itself). 13's
# `destroy` empties the bucket then `terraform destroy`s it; ASSUME_YES=1 since we already confirmed above.
# No-ops cleanly if .env has no AWS creds. Best-effort: a teardown hiccup shouldn't mask the node reset.
if [ "${REBUILD_IN_PROGRESS:-0}" != 1 ]; then
  say "tearing down the S3 backup bucket + IAM (empty + terraform destroy)"
  ASSUME_YES=1 bash "${SCRIPT_DIR}/13_s3_backup_bucket.sh" destroy \
    || echo ">> S3 teardown did not complete; run 'make s3-backup-destroy' by hand." >&2
fi
