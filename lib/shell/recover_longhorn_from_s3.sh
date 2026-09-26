#!/usr/bin/env bash
# Restores a Longhorn volume from its S3 backups into a new volume with a static PV and PVC.
# It never changes the backups or a live volume, and refuses to overwrite a Volume or PVC of the chosen name.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat << EOF
recover_longhorn_from_s3.sh [--volume <longhorn-vol>] [--backup latest|<name>] [--target-ns <ns>]
                           [--name <restore-name>] [--apply]     (or: make restore-longhorn)
  every flag is optional. The script prompts for anything missing.
  --apply   skip the confirmation prompt

The CSI snapshotter sidecar is off on this cluster, so a VolumeSnapshot restore is not possible.
A Longhorn Volume CR with spec.fromBackup pulls the backup into a new volume instead.
A static PV and PVC then bind to it in the target namespace. Point your workload at the restored PVC.
EOF
}

# ---- knobs ----
LH_VALUES="${PLATFORM_CHARTS}/02_longhorn/values.yaml" # holds the backup target
LH_NS="longhorn-system"
RESTORE_SC="longhorn-r2-retained-with-backups" # the backup class, so backups of the restored volume continue

# ---- state ----
VOL="" # set by parse_args / prompt_for_missing
BACKUP="latest"
TARGET_NS=""
RESTORE_NAME=""
DO_APPLY="false"
BK_JSON=""     # set by list_backups
FROM_BACKUP="" # set by resolve_backup
SIZE=""
MANIFEST="" # set by build_manifest

# ---- functions ----

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --volume)
        VOL="$2"
        shift 2
        ;;
      --backup)
        BACKUP="$2"
        shift 2
        ;;
      --target-ns)
        TARGET_NS="$2"
        shift 2
        ;;
      --name)
        RESTORE_NAME="$2"
        shift 2
        ;;
      --apply)
        DO_APPLY="true"
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) die "unknown argument: $1. See --help." ;;
    esac
  done
}

assert_backup_target_available() {
  local avail
  say "Longhorn restore from S3 into a new Volume with a static PV and PVC. Changes no existing data."
  kubectl get crd backuptargets.longhorn.io > /dev/null 2>&1 \
    || die "Longhorn BackupTarget CRD missing. Check that the longhorn app (platform wave 2) is synced."
  avail="$(kubectl -n "$LH_NS" get backuptargets.longhorn.io default -o jsonpath='{.status.available}' 2> /dev/null || true)"
  [ "$avail" = "true" ] \
    || die "Longhorn backup target 'default' is not available (status.available=${avail:-<none>}). Run make configure-longhorn-backup, push, and let it sync."
  ok "backup target 'default' is available"
}

list_backup_volumes() {
  say "backed-up volumes (BackupVolumes in ns ${LH_NS}):"
  kubectl -n "$LH_NS" get backupvolumes.longhorn.io \
    -o custom-columns='BACKUPVOLUME:.metadata.name,VOLUME:.status.volumeName,LAST-BACKUP:.status.lastBackupName,LAST-AT:.status.lastBackupAt,SIZE:.status.size' \
    2> /dev/null || warn "could not list BackupVolumes"
  echo
}

prompt_for_missing() {
  [ -n "$VOL" ] || read -rp "Longhorn volume to restore (the VOLUME column above, for example pvc-xxxx): " VOL
  [ -n "$VOL" ] || die "a volume is required"
  [ -n "$TARGET_NS" ] || read -rp "Target namespace for the restored PVC: " TARGET_NS
  [ -n "$TARGET_NS" ] || die "a target namespace is required"
  [ -z "$RESTORE_NAME" ] && RESTORE_NAME="${VOL}-restore"
  return 0
}

# Filters on .status.volumeName with yq. The backup-volume label and CR name change across Longhorn versions,
# and kubectl jsonpath escaping is unreliable here.
list_backups() {
  BK_JSON="$(kubectl -n "$LH_NS" get backups.longhorn.io -o json 2> /dev/null || echo '{}')"
  say "backups for volume ${VOL} (name / created / state):"
  echo "$BK_JSON" | VOL="$VOL" yq -p json -o tsv \
    '.items[] | select(.status.volumeName == strenv(VOL)) | [.metadata.name, .status.snapshotCreatedAt, .status.state]' \
    2> /dev/null | sort -k2 || warn "could not list backups"
  echo
}

# Reads the fromBackup URL from the Backup CR, so a bucket prefix cannot break it.
# The size comes from the BackupVolume, or from the Backup when that has none.
resolve_backup() {
  if [ "$BACKUP" = "latest" ]; then
    BACKUP="$(echo "$BK_JSON" | VOL="$VOL" yq -p json -o tsv \
      '.items[] | select(.status.volumeName == strenv(VOL)) | [.status.snapshotCreatedAt, .metadata.name]' \
      2> /dev/null | sort | tail -1 | cut -f2)"
    [ -n "$BACKUP" ] \
      || die "no backups found for volume ${VOL}. Check the volume name against the list above, or pass --backup <name>."
  fi
  kubectl -n "$LH_NS" get backups.longhorn.io "$BACKUP" > /dev/null 2>&1 \
    || die "backup ${BACKUP} not found in ns ${LH_NS}"
  FROM_BACKUP="$(kubectl -n "$LH_NS" get backups.longhorn.io "$BACKUP" -o jsonpath='{.status.url}' 2> /dev/null || true)"
  [ -n "$FROM_BACKUP" ] || die "backup ${BACKUP} has no .status.url yet. It may still sync. Try again shortly."
  SIZE="$(kubectl -n "$LH_NS" get backupvolumes.longhorn.io -o json 2> /dev/null \
    | VOL="$VOL" yq -p json '.items[] | select(.status.volumeName == strenv(VOL)) | .status.size' 2> /dev/null | head -1)"
  [ -n "$SIZE" ] && [ "$SIZE" != "null" ] \
    || SIZE="$(kubectl -n "$LH_NS" get backups.longhorn.io "$BACKUP" -o jsonpath='{.status.size}' 2> /dev/null || true)"
  [ -n "$SIZE" ] && [ "$SIZE" != "null" ] || die "could not determine the volume size for ${VOL}"
}

assert_target_free() {
  kubectl -n "$LH_NS" get volumes.longhorn.io "$RESTORE_NAME" > /dev/null 2>&1 \
    && die "Longhorn Volume ${LH_NS}/${RESTORE_NAME} already exists. Pass a different --name or delete it first."
  kubectl -n "$TARGET_NS" get pvc "$RESTORE_NAME" > /dev/null 2>&1 \
    && die "PVC ${TARGET_NS}/${RESTORE_NAME} already exists. Pass a different --name or delete it first."
  return 0
}

# reclaimPolicy Retain, so the volume goes only when someone deletes it on purpose.
build_manifest() {
  MANIFEST="$(
    cat << YAML
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
}

print_plan() {
  echo
  say "Restore plan"
  echo "    Source volume : ${VOL}"
  echo "    Backup        : ${BACKUP}"
  echo "    fromBackup    : ${FROM_BACKUP}"
  echo "    Size          : ${SIZE} bytes"
  echo "    Restore into  : Longhorn volume ${LH_NS}/${RESTORE_NAME}, PV ${RESTORE_NAME}, PVC ${TARGET_NS}/${RESTORE_NAME} (class ${RESTORE_SC})"
  echo
  echo "$MANIFEST"
  echo
}

confirm_restore() {
  local answer
  [ "$DO_APPLY" = "true" ] && return 0
  read -rp "Apply this restore? [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || {
    warn "Aborted (nothing applied)."
    exit 0
  }
}

apply_restore() {
  say "applying restore manifests"
  echo "$MANIFEST" | kubectl apply -f - > /dev/null
  ok "applied. Longhorn is restoring volume ${RESTORE_NAME} from S3."
}

print_next_steps() {
  cat << EOF

Restore started. Watch it complete:
  kubectl -n ${LH_NS} get volumes.longhorn.io ${RESTORE_NAME} -w        # wait for state Detached or Attached, robustness Healthy
  kubectl -n ${TARGET_NS} get pvc ${RESTORE_NAME}                        # expect Bound

Then point a workload at PVC ${TARGET_NS}/${RESTORE_NAME}.
The restored PV and PVC use reclaimPolicy Retain and the ${RESTORE_SC} class, so backups of the volume continue.
EOF
}

# ---- main ----

parse_args "$@"
require kubectl yq
use_kubeconfig
assert_api

assert_backup_target_available
list_backup_volumes
prompt_for_missing
list_backups
resolve_backup
assert_target_free
build_manifest
print_plan
confirm_restore
apply_restore
print_next_steps
