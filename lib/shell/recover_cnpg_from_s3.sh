#!/usr/bin/env bash
#
# recover_cnpg_from_s3.sh  (macOS)
#
# Restore a CloudNativePG database from the off-cluster S3 backups (continuous WAL + daily base, written by the
# Barman Cloud plugin). This is the SECOND DR tier — use it when the data is genuinely gone (node/disk loss,
# corruption, a bad migration you want to rewind, or a full cluster rebuild). If the local PV still exists and
# only the Cluster CR was deleted, use recover_cnpg_from_pv.sh instead (faster, no S3 transfer). See docs/13_backups.md.
#
# Non-destructive by design: it bootstraps a NEW, single-instance Cluster in the source namespace from the
# EXISTING ObjectStore (read-only pull via externalClusters), leaving the source backups and any live cluster
# untouched. The recovery cluster does NOT re-archive (no WAL archiver) — it's a restore/verify target; promote
# it by pointing your app at its -rw Service, or dump/reload into the real cluster. Refuses to overwrite an
# existing Cluster of the chosen name.
#
# Target: `latest` (most recent backup + all WAL) or a point-in-time timestamp for PITR (RFC3339, e.g.
# "2026-07-13 14:30:00+00"). Prints the manifest for review, then applies on confirm.
#
# Limitation: the recovery Cluster uses the default `postgresql` operand image. A postgis/timescaledb source
# would need a matching image (spec.imageName) — every cluster in this repo is postgresql, so no knob is wired.
#
# Usage (flags optional — prompts for anything missing):
#   bash recover_cnpg_from_s3.sh [--namespace NS] [--source CLUSTER] [--name RECOVERY_NAME]
#                                [--target latest|"YYYY-MM-DD HH:MM:SS+ZZ"] [--apply]
#   make restore-cnpg
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
STORAGE_CLASS="local-path"     # same node-local class the pg-cluster wrapper uses
STORAGE_SIZE="45Gi"            # matches the wrapper's storage.size (a no-op under local-path; it statfs's the partition)
PLUGIN="barman-cloud.cloudnative-pg.io"

NS=""; SOURCE=""; RECOVERY_NAME=""; TARGET="latest"; DO_APPLY="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    --source)    SOURCE="$2"; shift 2 ;;
    --name)      RECOVERY_NAME="$2"; shift 2 ;;
    --target)    TARGET="$2"; shift 2 ;;
    --apply)     DO_APPLY="true"; shift ;;
    *) die "unknown arg: $1 (see the usage header)" ;;
  esac
done

require kubectl
use_kubeconfig
assert_api

say "CNPG restore from S3 (Barman Cloud plugin) — bootstraps a NEW cluster from the object store"

# ---- 1. discover available ObjectStores (each = a backed-up source cluster) ---------------------------
kubectl get crd objectstores.barmancloud.cnpg.io >/dev/null 2>&1 \
  || die "ObjectStore CRD missing — is the barman plugin (platform app 03_barman_cloud_plugin) synced?"
say "ObjectStores found (namespace / name -> source cluster):"
kubectl get objectstores.barmancloud.cnpg.io -A \
  -o custom-columns='NAMESPACE:.metadata.namespace,OBJECTSTORE:.metadata.name,DESTINATION:.spec.configuration.destinationPath' \
  || warn "could not list ObjectStores"
echo

# ---- 2. gather inputs (prompt for anything not passed) ------------------------------------------------
[ -n "$NS" ]     || read -rp "Source namespace: " NS
[ -n "$SOURCE" ] || read -rp "Source cluster name (its ObjectStore is '<name>-backups', serverName=<name>): " SOURCE
[ -n "$NS" ] && [ -n "$SOURCE" ] || die "namespace and source cluster are required"
OBJECTSTORE="${SOURCE}-backups"     # the chart names it <fullname>-backups
[ -z "$RECOVERY_NAME" ] && RECOVERY_NAME="${SOURCE}-restore"

kubectl -n "$NS" get objectstore.barmancloud.cnpg.io "$OBJECTSTORE" >/dev/null 2>&1 \
  || die "ObjectStore ${NS}/${OBJECTSTORE} not found — check the namespace/source name (see the list above)"

# Preflight: the S3-creds Secret the ObjectStore references must exist, else the recovery cluster can't read
# WAL/base and fails opaquely. Read the real name from the store rather than assuming `cnpg-backup-s3`.
SEC="$(kubectl -n "$NS" get objectstore.barmancloud.cnpg.io "$OBJECTSTORE" -o jsonpath='{.spec.configuration.s3Credentials.accessKeyId.name}' 2>/dev/null)"
[ -n "$SEC" ] || die "could not read the S3 creds secret name from ObjectStore ${NS}/${OBJECTSTORE}"
kubectl -n "$NS" get secret "$SEC" >/dev/null 2>&1 \
  || die "S3 creds secret ${NS}/${SEC} (referenced by the ObjectStore) is missing — seal it into this namespace first (14_cnpg_backup.sh / commit the SealedSecret), then retry"
ok "S3 creds secret ${SEC} present"

# Preflight: a restore needs a COMPLETED base backup — WAL alone has no recovery point and the restore hangs.
# If the source Cluster CR still exists we can read its recoverability point; if it's gone (the real DR case)
# we can't inspect it, so we note that and trust the object store.
if kubectl -n "$NS" get cluster.postgresql.cnpg.io "$SOURCE" >/dev/null 2>&1; then
  FRP="$(kubectl -n "$NS" get cluster.postgresql.cnpg.io "$SOURCE" -o jsonpath='{.status.firstRecoverabilityPoint}' 2>/dev/null)"
  [ -n "$FRP" ] && ok "source has a recoverability point: ${FRP}" \
    || warn "source cluster ${SOURCE} has NO firstRecoverabilityPoint yet — no completed base backup, so a restore will have no recovery point and may hang. Trigger a base backup first (Backup CR, method: plugin)."
else
  warn "source cluster ${SOURCE} not present in ${NS} (expected in a real DR) — can't pre-check for a base backup; trusting the object store has one."
fi

if kubectl -n "$NS" get cluster.postgresql.cnpg.io "$RECOVERY_NAME" >/dev/null 2>&1; then
  die "Cluster ${NS}/${RECOVERY_NAME} already exists — pick a different --name (this tool never overwrites a live cluster)"
fi

# ---- 3. render the recovery Cluster -------------------------------------------------------------------
# recoveryTarget only when doing PITR; `latest` restores the most recent base backup + replays all WAL.
RECOVERY_TARGET_BLOCK=""
if [ "$TARGET" != "latest" ]; then
  RECOVERY_TARGET_BLOCK=$(printf '\n      recoveryTarget:\n        targetTime: "%s"' "$TARGET")
fi
MANIFEST=$(cat <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${RECOVERY_NAME}
  namespace: ${NS}
spec:
  instances: 1
  storage:
    storageClass: ${STORAGE_CLASS}
    size: ${STORAGE_SIZE}
  affinity:
    topologyKey: kubernetes.io/hostname
  bootstrap:
    recovery:
      source: ${SOURCE}${RECOVERY_TARGET_BLOCK}
  externalClusters:
    - name: ${SOURCE}
      plugin:
        name: ${PLUGIN}
        parameters:
          barmanObjectName: ${OBJECTSTORE}
          serverName: ${SOURCE}
YAML
)

echo
say "Recovery plan"
echo "    Namespace       : ${NS}"
echo "    Restore FROM    : ObjectStore ${OBJECTSTORE} (serverName ${SOURCE})"
echo "    Restore INTO    : new Cluster ${RECOVERY_NAME} (1 instance, no re-archiving)"
echo "    Target          : ${TARGET}"
echo
echo "----- manifest -----"
echo "$MANIFEST"
echo "--------------------"

# ---- 4. apply (confirm) -------------------------------------------------------------------------------
if [ "$DO_APPLY" != "true" ]; then
  read -rp "Apply this recovery Cluster now? [y/N]: " OK
  [[ "$OK" =~ ^[Yy]$ ]] || { warn "Not applied. Re-run with --apply, or apply the manifest above by hand."; exit 0; }
fi
echo "$MANIFEST" | kubectl apply -f -
ok "recovery Cluster ${NS}/${RECOVERY_NAME} created"

cat <<INSTRUCTIONS

Watch it bootstrap from S3 (pull base backup -> replay WAL -> reach the target):
    kubectl -n ${NS} get pods -l cnpg.io/cluster=${RECOVERY_NAME} -w
    kubectl cnpg status ${RECOVERY_NAME} -n ${NS}         # if the kubectl-cnpg plugin is installed

When Healthy, the restored data is served at Service ${RECOVERY_NAME}-rw.${NS}. To make it the real database,
repoint your app (or dump/reload into the live cluster). This recovery cluster is NOT a GitOps object — delete
it when done:  kubectl -n ${NS} delete cluster.postgresql.cnpg.io ${RECOVERY_NAME}

Note: it does not archive WAL (restore/verify target). To turn it into a permanent, backed-up cluster, add the
barman plugin as a .spec.plugins WAL archiver (see lib/helm/pg-cluster + docs/13_backups.md).
INSTRUCTIONS
