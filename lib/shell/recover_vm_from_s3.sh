#!/usr/bin/env bash
#
# recover_vm_from_s3.sh  (macOS)
#
# Restore VictoriaMetrics (metrics) or VictoriaLogs (logs) from the off-cluster S3 exports written by the central
# backup CronJob (08_vm_backup / 17_vm_backup.sh). Use it after a total loss of the monitoring volumes (both
# Longhorn replicas / cluster / off-site) — the day-to-day `longhorn-r2-retained` class only survives an accidental
# delete, not that. See docs/13_backups.md and docs/09_monitoring.md.
#
# Streams the chosen gzip'd export straight back into the LIVE store's import endpoint via a TEMPORARY pod in ns
# monitoring (where the sealed S3 creds live), so nothing touches a PVC or the operator's VLSingle/VMSingle CRs:
#   metrics  aws s3 cp <obj> - | gunzip | curl -XPOST $VMSINGLE/api/v1/import/native -T -
#   logs     aws s3 cp <obj> - | gunzip | curl -XPOST $VLSINGLE/insert/jsonline?_time_field=_time&_msg_field=_msg -T -
# The pod is labelled app.kubernetes.io/name=vm-backup, so the store's existing ingress allowlist already lets it
# in; a break-glass egress CiliumNetworkPolicy lets the pod reach S3 + the store. A cleanup trap tears both down.
#
# NON-DESTRUCTIVE: /import MERGES into whatever's already there (it never wipes). For a clean disaster-recovery,
# point it at a FRESH/empty store. VictoriaLogs stream-field fidelity is best-effort on re-ingest (stream labels
# are re-derived), which is expected for a logical export/import.
#
# Usage (flags optional — prompts for anything missing):
#   bash recover_vm_from_s3.sh [--kind metrics|logs] [--target latest|<s3-key>] [--apply]
#   make restore-vm
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
VB_VALUES="${REPO_ROOT}/argo_apps/platform/charts/08_vm_backup/values.yaml"  # single source for bucket/prefix/store URLs
RESTORE_NS="monitoring"                                          # the restore pod runs where the sealed creds + stores live
SECRET_NAME="vm-backup-s3"                                       # the sealed writer creds in RESTORE_NS
# renovate: datasource=docker
RUNNER_IMAGE="alpine/k8s:1.36.2"                                 # curl + aws-cli + gzip, same as the backup CronJob

KIND=""; TARGET="latest"; DO_APPLY="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --kind)   KIND="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --apply)  DO_APPLY="true"; shift ;;
    *) die "unknown arg: $1 (see the usage header)" ;;
  esac
done

require kubectl aws yq
use_kubeconfig
assert_api

# S3 listing runs on the HOST with the .env DEPLOYER creds (read is within its s3:* on the bucket). The in-cluster
# download uses the sealed WRITER creds already in ns monitoring — no host writer creds needed.
[ -n "$AWS_DEPLOY_ACCESS_KEY_ID" ] || die "AWS_DEPLOY_ACCESS_KEY_ID empty in .env — needed to list S3 backups"
export AWS_ACCESS_KEY_ID="$AWS_DEPLOY_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$AWS_DEPLOY_SECRET_ACCESS_KEY_SECRET"
export AWS_DEFAULT_REGION="$AWS_REGION"

BUCKET="$(yq -r '.bucket' "$VB_VALUES")"
PREFIX="$(yq -r '.prefix' "$VB_VALUES")"
VMSINGLE="$(yq -r '.vmsingle' "$VB_VALUES")"
VLSINGLE="$(yq -r '.vlsingle' "$VB_VALUES")"
[ -n "$BUCKET" ] && [ "$BUCKET" != "null" ] || die "bucket is unset in ${VB_VALUES} — run 17_vm_backup.sh first"

say "VM/VL restore from S3 — stream a gzip'd export back into the live store's /import endpoint"

# ---- 1. gather inputs -------------------------------------------------------
[ -n "$KIND" ] || read -rp "Kind to restore [metrics|logs]: " KIND
case "$KIND" in
  metrics)
    SUBPREFIX="metrics/"; EXT=".native.gz"
    IMPORT_URL="${VMSINGLE}/api/v1/import/native"
    STORE_NAME="vmsingle"; STORE_INSTANCE="victoria-metrics-k8s-stack"; STORE_PORT="8428" ;;
  logs)
    SUBPREFIX="logs/"; EXT=".jsonl.gz"
    IMPORT_URL="${VLSINGLE}/insert/jsonline?_time_field=_time&_msg_field=_msg"
    STORE_NAME="vlsingle"; STORE_INSTANCE="victoria-logs"; STORE_PORT="9428" ;;
  *) die "kind must be 'metrics' or 'logs' (got '${KIND}')" ;;
esac

kubectl -n "$RESTORE_NS" get secret "$SECRET_NAME" >/dev/null 2>&1 \
  || die "sealed creds ${RESTORE_NS}/${SECRET_NAME} missing — enable backups first (make configure-vm-backup)"

DEST="s3://${BUCKET}/${PREFIX}${SUBPREFIX}"
if [ "$TARGET" = "latest" ]; then
  say "resolving latest ${KIND} export under ${DEST}"
  KEY="$(aws s3 ls "$DEST" | awk '{print $4}' | grep -E "${EXT}\$" | sort | tail -1)"
  [ -n "$KEY" ] || die "no ${EXT} objects under ${DEST} — nothing to restore"
  OBJECT="${DEST}${KEY}"
else
  OBJECT="s3://${BUCKET}/${TARGET#/}"   # caller passed a full key relative to the bucket
fi
aws s3 ls "$OBJECT" >/dev/null 2>&1 || die "object not found: ${OBJECT}"
ok "restoring from: ${OBJECT}"

RESTORE_POD="vm-restore-${KIND}"
BG_NETPOL="vm-restore-breakglass-${KIND}"

echo
say "Restore plan"
echo "    Kind        : ${KIND}"
echo "    From        : ${OBJECT}"
echo "    Into        : ${IMPORT_URL}  (MERGE — import never wipes)"
echo "    Runner pod  : ${RESTORE_NS}/${RESTORE_POD}  (image ${RUNNER_IMAGE})"
echo
warn "Import MERGES into the live store. For a clean DR, run this against a FRESH/empty ${KIND} store."
if [ "$DO_APPLY" != "true" ]; then
  read -rp "Proceed? [y/N]: " OK
  [[ "$OK" =~ ^[Yy]$ ]] || { warn "Aborted."; exit 0; }
fi

# ---- cleanup trap -----------------------------------------------------------
cleanup() {
  warn "cleaning up restore pod + break-glass netpol"
  kubectl -n "$RESTORE_NS" delete pod "$RESTORE_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$RESTORE_NS" delete ciliumnetworkpolicy "$BG_NETPOL" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---- 2. break-glass egress netpol (restore pod -> DNS + S3 + the store) -----
say "applying break-glass egress network policy"
kubectl apply -f - >/dev/null <<YAML
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: ${BG_NETPOL}
  namespace: ${RESTORE_NS}
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: vm-backup
      app.kubernetes.io/component: vm-restore
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports: [{ port: "53", protocol: UDP }, { port: "53", protocol: TCP }]
          rules:
            dns: [{ matchPattern: "*" }]
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: ${RESTORE_NS}
            app.kubernetes.io/name: ${STORE_NAME}
            app.kubernetes.io/instance: ${STORE_INSTANCE}
      toPorts:
        - ports: [{ port: "${STORE_PORT}", protocol: TCP }]
    - toFQDNs:
        - matchPattern: "*.s3.${AWS_REGION}.amazonaws.com"
        - matchName: "s3.${AWS_REGION}.amazonaws.com"
      toPorts:
        - ports: [{ port: "443", protocol: TCP }]
YAML
ok "break-glass netpol applied"

# ---- 3. restore pod: download the export, stream it into /import ------------
# app.kubernetes.io/name=vm-backup so the store's existing ingress allowlist already admits this pod.
say "creating restore pod (downloads the export, streams it into the store)"
kubectl -n "$RESTORE_NS" delete pod "$RESTORE_POD" --ignore-not-found >/dev/null 2>&1 || true
kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${RESTORE_POD}
  namespace: ${RESTORE_NS}
  labels:
    app.kubernetes.io/name: vm-backup
    app.kubernetes.io/component: vm-restore
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: restore
      image: "${RUNNER_IMAGE}"
      command: ["/bin/sh","-c"]
      args:
        - |
          set -o pipefail
          echo "streaming ${OBJECT} -> ${IMPORT_URL}"
          aws s3 cp "${OBJECT}" - | gunzip | curl -sf --max-time 3000 -X POST "${IMPORT_URL}" -T -
      env:
        - { name: HOME, value: /tmp }
        - { name: TMPDIR, value: /tmp }
        - { name: AWS_DEFAULT_REGION, value: "${AWS_REGION}" }
        - { name: AWS_ACCESS_KEY_ID,     valueFrom: { secretKeyRef: { name: ${SECRET_NAME}, key: AWS_ACCESS_KEY_ID } } }
        - { name: AWS_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: ${SECRET_NAME}, key: AWS_SECRET_ACCESS_KEY } } }
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: ["ALL"] }
        readOnlyRootFilesystem: true
      volumeMounts: [{ name: tmp, mountPath: /tmp }]
  volumes:
    - name: tmp
      emptyDir: {}
YAML

say "waiting for the restore to complete (this can take a while for a large export)"
# Poll the pod phase: Succeeded => import returned 200; Failed => surface logs and die.
for _ in $(seq 1 900); do
  PHASE="$(kubectl -n "$RESTORE_NS" get pod "$RESTORE_POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "$PHASE" in
    Succeeded) break ;;
    Failed)    kubectl -n "$RESTORE_NS" logs "$RESTORE_POD" || true; die "restore pod failed — see logs above" ;;
  esac
  sleep 2
done
[ "${PHASE:-}" = "Succeeded" ] || { kubectl -n "$RESTORE_NS" logs "$RESTORE_POD" 2>/dev/null || true; die "restore did not complete (phase=${PHASE:-unknown})"; }
kubectl -n "$RESTORE_NS" logs "$RESTORE_POD" 2>/dev/null || true
ok "import completed"

# ---- 4. done (trap tears down the pod + netpol) -----------------------------
say "verify in vmui/Grafana: ${KIND} data should now be queryable (imports flush async; allow a few seconds)"
summary
[ "$FAIL" -eq 0 ]
