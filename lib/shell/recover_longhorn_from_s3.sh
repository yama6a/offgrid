#!/usr/bin/env bash
#
# recover_longhorn_from_s3.sh  (macOS)
#
# Restore an opt-in Longhorn volume from its off-cluster S3 backups (native Longhorn backups, written by the
# daily/weekly RecurringJobs — see 02_longhorn + 16_longhorn_backup.sh). Second DR tier — use it when the data is
# genuinely gone (disk/node loss, corruption, a bad write to rewind, or a full rebuild). See docs/13_backups.md.
#
# Mechanism: this cluster runs with the CSI snapshotter sidecar DISABLED (02_longhorn values csi.snapshotterReplicaCount:
# 0), so the Kubernetes VolumeSnapshot restore path is unavailable. Instead we use Longhorn's native path: create a
# Longhorn `Volume` CR with spec.fromBackup (Longhorn pulls the backup from S3 into a NEW volume), then a static PV +
# PVC bound to it, in the target namespace. Non-destructive: it never touches the source backups or any live volume,
# and refuses to overwrite an existing Volume/PVC of the chosen name. Point your workload at the restored PVC.
#
# Usage (flags optional — prompts/lists for anything missing):
#   bash recover_longhorn_from_s3.sh [--volume LONGHORN_VOL] [--backup latest|<backup-name>] \
#        [--target-ns NS] [--name RESTORE_NAME] [--apply]
#   make restore-longhorn
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
LH_VALUES="${REPO_ROOT}/argo_apps/platform/charts/02_longhorn/values.yaml"  # single source for the backup target
LH_NS="longhorn-system"
RESTORE_SC="longhorn-r2-retained-with-backups"   # restored PV/PVC use the backup class (so the restored volume keeps getting backed up)

VOL=""; BACKUP="latest"; TARGET_NS=""; RESTORE_NAME=""; DO_APPLY="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --volume)    VOL="$2"; shift 2 ;;
    --backup)    BACKUP="$2"; shift 2 ;;
    --target-ns) TARGET_NS="$2"; shift 2 ;;
    --name)      RESTORE_NAME="$2"; shift 2 ;;
    --apply)     DO_APPLY="true"; shift ;;
    *) die "unknown arg: $1 (see the usage header)" ;;
  esac
done

require kubectl yq
use_kubeconfig
assert_api

say "Longhorn restore from S3 — native Volume(fromBackup) -> static PV/PVC (non-destructive)"

# ---- 1. preflight: backup target must be configured + available -------------
kubectl get crd backuptargets.longhorn.io >/dev/null 2>&1 \
  || die "Longhorn BackupTarget CRD missing — is the longhorn app (platform wave 2) synced?"
AVAIL="$(kubectl -n "$LH_NS" get backuptargets.longhorn.io default -o jsonpath='{.status.available}' 2>/dev/null || true)"
[ "$AVAIL" = "true" ] \
  || die "Longhorn backup target 'default' is not available (status.available=${AVAIL:-<none>}). Enable backups first (make configure-longhorn-backup), push, and let it sync."
ok "backup target 'default' is available"

# ---- 2. discover backed-up volumes ------------------------------------------
say "backed-up volumes (BackupVolumes in ns ${LH_NS}):"
kubectl -n "$LH_NS" get backupvolumes.longhorn.io \
  -o custom-columns='BACKUPVOLUME:.metadata.name,VOLUME:.status.volumeName,LAST-BACKUP:.status.lastBackupName,LAST-AT:.status.lastBackupAt,SIZE:.status.size' \
  2>/dev/null || warn "could not list BackupVolumes"
echo

# ---- 3. gather inputs -------------------------------------------------------
[ -n "$VOL" ] || read -rp "Longhorn volume to restore (the VOLUME column above, e.g. pvc-xxxx): " VOL
[ -n "$VOL" ] || die "a volume is required"
[ -n "$TARGET_NS" ] || read -rp "Target namespace for the restored PVC: " TARGET_NS
[ -n "$TARGET_NS" ] || die "a target namespace is required"
[ -z "$RESTORE_NAME" ] && RESTORE_NAME="${VOL}-restore"

# backups for this volume. Filter with yq over JSON (data-driven on .status.volumeName — robust vs the
# backup-volume label / CR-name changes across Longhorn versions, and vs kubectl jsonpath escape quirks).
BK_JSON="$(kubectl -n "$LH_NS" get backups.longhorn.io -o json 2>/dev/null || echo '{}')"
say "backups for volume ${VOL} (name / created / state):"
echo "$BK_JSON" | VOL="$VOL" yq -p json -o tsv \
  '.items[] | select(.status.volumeName == strenv(VOL)) | [.metadata.name, .status.snapshotCreatedAt, .status.state]' \
  2>/dev/null | sort -k2 || warn "could not list backups"
echo

# resolve the chosen backup name
if [ "$BACKUP" = "latest" ]; then
  BACKUP="$(echo "$BK_JSON" | VOL="$VOL" yq -p json -o tsv \
    '.items[] | select(.status.volumeName == strenv(VOL)) | [.status.snapshotCreatedAt, .metadata.name]' \
    2>/dev/null | sort | tail -1 | cut -f2)"
  [ -n "$BACKUP" ] \
    || die "no backups found for volume ${VOL} — check the volume name against the list above, or pass --backup <name>"
fi
kubectl -n "$LH_NS" get backups.longhorn.io "$BACKUP" >/dev/null 2>&1 \
  || die "backup ${BACKUP} not found in ns ${LH_NS}"

# the exact fromBackup URL comes straight off the chosen Backup CR (no manual URL assembly, prefix-safe)
FROM_BACKUP="$(kubectl -n "$LH_NS" get backups.longhorn.io "$BACKUP" -o jsonpath='{.status.url}' 2>/dev/null || true)"
[ -n "$FROM_BACKUP" ] || die "backup ${BACKUP} has no .status.url yet (still syncing?) — retry shortly"
# volume size (bytes) for the Volume/PV/PVC capacity — from the BackupVolume, falling back to the Backup
SIZE="$(kubectl -n "$LH_NS" get backupvolumes.longhorn.io -o json 2>/dev/null \
  | VOL="$VOL" yq -p json '.items[] | select(.status.volumeName == strenv(VOL)) | .status.size' 2>/dev/null | head -1)"
[ -n "$SIZE" ] && [ "$SIZE" != "null" ] \
  || SIZE="$(kubectl -n "$LH_NS" get backups.longhorn.io "$BACKUP" -o jsonpath='{.status.size}' 2>/dev/null || true)"
[ -n "$SIZE" ] && [ "$SIZE" != "null" ] || die "could not determine the volume size for ${VOL}"

# ---- 4. refuse to overwrite -------------------------------------------------
kubectl -n "$LH_NS" get volumes.longhorn.io "$RESTORE_NAME" >/dev/null 2>&1 \
  && die "Longhorn Volume ${LH_NS}/${RESTORE_NAME} already exists — pass a different --name or delete it first"
kubectl -n "$TARGET_NS" get pvc "$RESTORE_NAME" >/dev/null 2>&1 \
  && die "PVC ${TARGET_NS}/${RESTORE_NAME} already exists — pass a different --name or delete it first"

# ---- 5. render the restore manifests ----------------------------------------
# Longhorn Volume(fromBackup) pulls the backup into a NEW volume; the static PV binds that volume (volumeHandle ==
# the Longhorn volume name) to a PVC in the target namespace. reclaimPolicy Retain so cleanup is deliberate.
MANIFEST="$(cat <<YAML
---
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: ${RESTORE_NAME}
  namespace: ${LH_NS}
spec:
  fromBackup: "${FROM_BACKUP}"
  frontend: blockdev
  numberOfReplicas: 2
  size: "${SIZE}"
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${RESTORE_NAME}
spec:
  capacity:
    storage: "${SIZE}"
  accessModes: ["ReadWriteOnce"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ${RESTORE_SC}
  csi:
    driver: driver.longhorn.io
    fsType: ext4
    volumeHandle: ${RESTORE_NAME}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${RESTORE_NAME}
  namespace: ${TARGET_NS}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ${RESTORE_SC}
  resources:
    requests:
      storage: "${SIZE}"
  volumeName: ${RESTORE_NAME}
YAML
)"

echo
say "Restore plan"
echo "    Source volume : ${VOL}"
echo "    Backup        : ${BACKUP}"
echo "    fromBackup    : ${FROM_BACKUP}"
echo "    Size          : ${SIZE} bytes"
echo "    Restore into  : Longhorn volume ${LH_NS}/${RESTORE_NAME} -> PV ${RESTORE_NAME} -> PVC ${TARGET_NS}/${RESTORE_NAME} (class ${RESTORE_SC})"
echo
echo "$MANIFEST"
echo

if [ "$DO_APPLY" != "true" ]; then
  read -rp "Apply this restore? [y/N]: " OK
  [[ "$OK" =~ ^[Yy]$ ]] || { warn "Aborted (nothing applied)."; exit 0; }
fi

say "applying restore manifests"
echo "$MANIFEST" | kubectl apply -f - >/dev/null
ok "applied — Longhorn is restoring volume ${RESTORE_NAME} from S3"

cat <<EOF

Restore started. Watch it complete:
  kubectl -n ${LH_NS} get volumes.longhorn.io ${RESTORE_NAME} -w        # wait for state Detached/Attached, robustness Healthy
  kubectl -n ${TARGET_NS} get pvc ${RESTORE_NAME}                        # should Bound

Then point a workload at PVC ${TARGET_NS}/${RESTORE_NAME}. The restored PV/PVC use reclaimPolicy Retain and the
${RESTORE_SC} class, so the restored volume itself keeps getting backed up.
EOF
