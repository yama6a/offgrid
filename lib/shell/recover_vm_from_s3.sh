#!/usr/bin/env bash
# Restores VictoriaMetrics or VictoriaLogs from the S3 exports, by streaming a gzip'd export back into the LIVE
# store's import endpoint via a temporary pod. Nothing touches a PVC or the operator's CRs.
# NON-DESTRUCTIVE: /import MERGES into whatever is already there, it never wipes. For a clean DR, point it at
# a fresh store. VictoriaLogs stream-field fidelity is best-effort on re-ingest.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<EOF
recover_vm_from_s3.sh [--kind metrics|logs] [--target all|latest|<s3-key>] [--apply]
                                                             (or: make restore-vm)
  --kind     which store; prompts if omitted
  --target   backups are one gzip'd slice per UTC day. all = replay every slice, latest = just the newest,
             or name one key relative to the bucket. Defaults to latest.
  --apply    skip the confirmation prompt

Use it after a TOTAL loss of the monitoring volumes; deletionProtection already covers an accidental prune.
EOF
}

# ---- knobs ----
VB_VALUES="${PLATFORM_CHARTS}/08_vm_backup/values.yaml"  # single source for bucket/prefix/store URLs
RESTORE_NS="monitoring"          # the restore pod runs where the sealed creds + stores live
SECRET_NAME="vm-backup-s3"       # the sealed writer creds in RESTORE_NS
# renovate: datasource=docker
RUNNER_IMAGE="alpine/k8s:1.36.2" # curl + aws-cli + gzip, same as the backup CronJob

# ---- state ----
KIND=""             # set by parse_args / resolve_kind
TARGET="latest"
DO_APPLY="false"
BUCKET=""           # set by read_backup_values
PREFIX=""
VMSINGLE=""
VLSINGLE=""
SUBPREFIX=""        # set by resolve_kind
EXT=""
IMPORT_URL=""
STORE_NAME=""
STORE_INSTANCE=""
STORE_PORT=""
DEST=""             # set by resolve_objects
OBJECTS=""
OBJECTS_ONELINE=""
N_OBJ=0
RESTORE_POD=""      # set by resolve_kind
BG_NETPOL=""

# ---- functions ----

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind)    KIND="$2"; shift 2 ;;
      --target)  TARGET="$2"; shift 2 ;;
      --apply)   DO_APPLY="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown arg: $1 (see --help)" ;;
    esac
  done
}

# The S3 listing runs on the HOST with the .env DEPLOYER creds (read is within its s3:* on the bucket). The
# in-cluster download uses the sealed WRITER creds already in ns monitoring, so no host writer creds are needed.
use_deploy_creds() {
  [ -n "$AWS_DEPLOY_ACCESS_KEY_ID" ] || die "AWS_DEPLOY_ACCESS_KEY_ID empty in .env, needed to list S3 backups"
  export_deploy_aws_creds
}

read_backup_values() {
  BUCKET="$(yq -r '.bucket' "$VB_VALUES")"
  PREFIX="$(yq -r '.prefix' "$VB_VALUES")"
  VMSINGLE="$(yq -r '.vmsingle' "$VB_VALUES")"
  VLSINGLE="$(yq -r '.vlsingle' "$VB_VALUES")"
  [ -n "$BUCKET" ] && [ "$BUCKET" != "null" ] || die "bucket is unset in ${VB_VALUES}: run 10e_vm_backup.sh first"
  say "VM/VL restore from S3: stream a gzip'd export back into the live store's /import endpoint"
}

resolve_kind() {
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
  RESTORE_POD="vm-restore-${KIND}"
  BG_NETPOL="vm-restore-breakglass-${KIND}"
  kubectl -n "$RESTORE_NS" get secret "$SECRET_NAME" >/dev/null 2>&1 \
    || die "sealed creds ${RESTORE_NS}/${SECRET_NAME} missing: enable backups first (make configure-vm-backup)"
}

# OBJECTS is a newline list of full s3:// urls. Slices are date-named, so a plain sort is chronological.
resolve_objects() {
  local keys key
  DEST="s3://${BUCKET}/${PREFIX}${SUBPREFIX}"
  case "$TARGET" in
    all)
      say "resolving ALL ${KIND} daily slices under ${DEST}"
      keys="$(aws s3 ls "$DEST" | awk '{print $4}' | grep -E "${EXT}\$" | sort)"
      [ -n "$keys" ] || die "no ${EXT} objects under ${DEST}, nothing to restore"
      OBJECTS="$(printf '%s\n' "$keys" | sed "s#^#${DEST}#")" ;;
    latest)
      say "resolving latest ${KIND} daily slice under ${DEST}"
      key="$(aws s3 ls "$DEST" | awk '{print $4}' | grep -E "${EXT}\$" | sort | tail -1)"
      [ -n "$key" ] || die "no ${EXT} objects under ${DEST}, nothing to restore"
      OBJECTS="${DEST}${key}" ;;
    *)
      OBJECTS="s3://${BUCKET}/${TARGET#/}"   # caller passed a full key relative to the bucket
      aws s3 ls "$OBJECTS" >/dev/null 2>&1 || die "object not found: ${OBJECTS}" ;;
  esac
  OBJECTS_ONELINE="$(printf '%s ' $OBJECTS)"   # space-joined for the pod's `for` loop (keys have no spaces)
  N_OBJ="$(printf '%s\n' "$OBJECTS" | grep -c .)"
  ok "restoring ${N_OBJ} object(s):"
  printf '%s\n' "$OBJECTS" | sed 's/^/    /'
}

confirm_restore() {
  local answer
  echo
  say "Restore plan"
  echo "    Kind        : ${KIND}"
  echo "    From        : ${N_OBJ} object(s) under ${DEST}"
  echo "    Into        : ${IMPORT_URL}  (MERGE, import never wipes)"
  echo "    Runner pod  : ${RESTORE_NS}/${RESTORE_POD}  (image ${RUNNER_IMAGE})"
  echo
  warn "Import MERGES into the live store. For a clean DR, run this against a FRESH/empty ${KIND} store."
  [ "$DO_APPLY" = "true" ] && return 0
  read -rp "Proceed? [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { warn "Aborted."; exit 0; }
}

cleanup() {
  warn "cleaning up restore pod + break-glass netpol"
  kubectl -n "$RESTORE_NS" delete pod "$RESTORE_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$RESTORE_NS" delete ciliumnetworkpolicy "$BG_NETPOL" --ignore-not-found >/dev/null 2>&1 || true
}

apply_breakglass_netpol() {
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
}

# app.kubernetes.io/name=vm-backup so the store's existing ingress allowlist already admits this pod.
create_restore_pod() {
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
          fail=0
          # host bakes the space-joined slice list (keys are date-named, no spaces => safe word-split); pod-local
          # \$-vars are escaped so the unquoted heredoc doesn't expand them. Any failed slice fails the pod.
          for o in ${OBJECTS_ONELINE}; do
            echo "streaming \${o} -> ${IMPORT_URL}"
            if aws s3 cp "\$o" - | gunzip | curl -sf --max-time 3000 -X POST "${IMPORT_URL}" -T -; then
              echo "  ok"
            else
              echo "  FAILED \${o}"; fail=1
            fi
          done
          [ "\$fail" -eq 0 ]
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
}

# Succeeded means the import returned 200; Failed surfaces the logs and dies.
wait_for_import() {
  local phase="" _
  say "waiting for the restore to complete (this can take a while for a large export)"
  for _ in $(seq 1 900); do
    phase="$(kubectl -n "$RESTORE_NS" get pod "$RESTORE_POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in
      Succeeded) break ;;
      Failed)    kubectl -n "$RESTORE_NS" logs "$RESTORE_POD" || true; die "restore pod failed, see logs above" ;;
    esac
    sleep 2
  done
  [ "${phase:-}" = "Succeeded" ] || { kubectl -n "$RESTORE_NS" logs "$RESTORE_POD" 2>/dev/null || true; die "restore did not complete (phase=${phase:-unknown})"; }
  kubectl -n "$RESTORE_NS" logs "$RESTORE_POD" 2>/dev/null || true
  ok "import completed"
}

# ---- main ----

parse_args "$@"
require kubectl aws yq
use_kubeconfig
assert_api

use_deploy_creds
read_backup_values
resolve_kind
resolve_objects
confirm_restore

trap cleanup EXIT
apply_breakglass_netpol
create_restore_pod
wait_for_import

say "verify in vmui/Grafana: ${KIND} data should now be queryable (imports flush async; allow a few seconds)"
summary
[ "$FAIL" -eq 0 ]
