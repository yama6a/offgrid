#!/usr/bin/env bash
#
# recover_redis_from_s3.sh  (macOS)
#
# Restore a standalone OpsTree Redis instance from its off-cluster S3 RDB dumps (written by the central backup
# CronJob, 07_redis_backup / 15_redis_backup.sh). Second DR tier — use it when the data is genuinely gone
# (disk/cluster loss, corruption, or a bad write you want to rewind). See docs/12_redis.md and docs/13_backups.md.
#
# Live, in-place, full-fidelity restore that NEVER deletes the Redis CR or touches its PVC/AOF files (so the
# OpsTree operator is left alone):
#   1. a TEMPORARY seed pod (in ns redis-backup, where the sealed S3 creds live) downloads the chosen RDB and
#      boots a plain redis-server from it (appendonly off) -> holds the dataset. Its image == the instance's
#      image (grepped from redis.yaml), so it can load the dump (an RDB is forward-only).
#   2. break-glass CiliumNetworkPolicies open target(ns) <-> seed(redis-backup ns) on 6379 for the duration.
#   3. the target is made a replica of the seed (REPLICAOF) -> full resync PULLS the whole dataset (all types +
#      TTLs, exact fidelity), then REPLICAOF NO ONE promotes it back to a standalone master. Its appendonly=yes
#      rebuilds the AOF from the restored data automatically.
#   4. the seed pod + break-glass netpols are torn down (a cleanup trap runs even on failure).
# `FLUSHALL` on the target first => a CLEAN replace, not a merge. Prompts before the destructive step.
#
# Usage (flags optional — prompts for anything missing):
#   bash recover_redis_from_s3.sh [--namespace NS] [--instance NAME] [--target latest|<s3-key>] [--apply]
#   make restore-redis
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
RB_VALUES="${REPO_ROOT}/argo_apps/platform/charts/07_redis_backup/values.yaml"  # single source for bucket/prefix
REDIS_TPL="${REPO_ROOT}/lib/helm/redis-instance/templates/redis.yaml"  # single source for the server image tag
SEED_NS="redis-backup"                                            # the seed runs where the sealed creds live
SECRET_NAME="redis-backup-s3"                                     # the sealed writer creds in SEED_NS
# renovate: datasource=docker
AWSCLI_IMAGE="public.ecr.aws/aws-cli/aws-cli:2.36.0"             # the seed's S3-download initContainer

NS=""; INSTANCE=""; TARGET="latest"; DO_APPLY="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --namespace) NS="$2"; shift 2 ;;
    --instance)  INSTANCE="$2"; shift 2 ;;
    --target)    TARGET="$2"; shift 2 ;;
    --apply)     DO_APPLY="true"; shift ;;
    *) die "unknown arg: $1 (see the usage header)" ;;
  esac
done

require kubectl aws yq
use_kubeconfig
assert_api

# S3 listing runs on the HOST with the .env DEPLOYER creds (read is within its s3:* on the bucket). The in-cluster
# download uses the sealed WRITER creds already in ns redis-backup — no host writer creds needed.
[ -n "$AWS_DEPLOY_ACCESS_KEY_ID" ] || die "AWS_DEPLOY_ACCESS_KEY_ID empty in .env — needed to list S3 backups"
export AWS_ACCESS_KEY_ID="$AWS_DEPLOY_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$AWS_DEPLOY_SECRET_ACCESS_KEY_SECRET"
export AWS_DEFAULT_REGION="$AWS_REGION"

BUCKET="$(yq -r '.bucket' "$RB_VALUES")"
PREFIX="$(yq -r '.prefix' "$RB_VALUES")"
[ -n "$BUCKET" ] && [ "$BUCKET" != "null" ] || die "bucket is unset in ${RB_VALUES} — run 15_redis_backup.sh first"

# Seed image == the instance's server image (grepped from the CR template): an RDB is forward-only, so the seed
# that loads it MUST match the instance major. Tracks renovate's bumps of redis.yaml automatically.
SEED_IMAGE="$(grep -oE 'quay\.io/opstree/redis:[^"]+' "$REDIS_TPL" | head -1)"
[ -n "$SEED_IMAGE" ] || die "could not read the redis image tag from ${REDIS_TPL}"

say "Redis restore from S3 — seed pod + replication resync (in-place, non-destructive to the CR)"

# ---- 1. gather inputs -------------------------------------------------------
[ -n "$NS" ]       || read -rp "Namespace: " NS
[ -n "$INSTANCE" ] || read -rp "Redis instance name (the CR / Service name): " INSTANCE
[ -n "$NS" ] && [ -n "$INSTANCE" ] || die "namespace and instance are required"

kubectl -n "$NS" get redis "$INSTANCE" >/dev/null 2>&1 \
  || die "Redis CR ${NS}/${INSTANCE} not found — check the namespace/name"
kubectl -n "$SEED_NS" get secret "$SECRET_NAME" >/dev/null 2>&1 \
  || die "sealed creds ${SEED_NS}/${SECRET_NAME} missing — enable backups first (make configure-redis-backup)"

DEST="s3://${BUCKET}/${PREFIX}${NS}/${INSTANCE}/"
if [ "$TARGET" = "latest" ]; then
  say "resolving latest dump under ${DEST}"
  KEY="$(aws s3 ls "$DEST" | awk '{print $4}' | grep -E '\.rdb$' | sort | tail -1)"
  [ -n "$KEY" ] || die "no .rdb objects under ${DEST} — nothing to restore"
  OBJECT="${DEST}${KEY}"
else
  OBJECT="s3://${BUCKET}/${TARGET#/}"   # caller passed a full key relative to the bucket
fi
aws s3 ls "$OBJECT" >/dev/null 2>&1 || die "object not found: ${OBJECT}"
ok "restoring from: ${OBJECT}"

TARGET_POD="$(kubectl -n "$NS" get pod -l "app=${INSTANCE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[ -n "$TARGET_POD" ] || die "no running pod with label app=${INSTANCE} in ${NS} — is the instance up?"

SEED_POD="redis-restore-${INSTANCE}"
BG_NETPOL="redis-restore-breakglass-${INSTANCE}"

echo
say "Restore plan"
echo "    Target      : ${NS}/${INSTANCE}  (pod ${TARGET_POD})"
echo "    From        : ${OBJECT}"
echo "    Seed pod    : ${SEED_NS}/${SEED_POD}  (image ${SEED_IMAGE})"
echo "    Method      : FLUSHALL the target, then REPLICAOF the seed (CLEAN REPLACE), then promote back."
echo
warn "This ERASES the target's current data and replaces it with the dump. This is destructive."
if [ "$DO_APPLY" != "true" ]; then
  read -rp "Proceed? [y/N]: " OK
  [[ "$OK" =~ ^[Yy]$ ]] || { warn "Aborted."; exit 0; }
fi

# ---- cleanup trap -----------------------------------------------------------
cleanup() {
  warn "cleaning up seed pod + break-glass netpols"
  kubectl -n "$SEED_NS" delete pod "$SEED_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$SEED_NS" delete ciliumnetworkpolicy "${BG_NETPOL}-seed" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$NS" delete ciliumnetworkpolicy "${BG_NETPOL}-target" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---- 2. break-glass netpols (target<->seed on 6379; seed egress DNS+S3) -----
say "applying break-glass network policies"
kubectl apply -f - >/dev/null <<YAML
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: ${BG_NETPOL}-seed
  namespace: ${SEED_NS}
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/component: redis-restore
      app.kubernetes.io/name: ${INSTANCE}
  ingress:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: ${NS}
            app: ${INSTANCE}
      toPorts:
        - ports: [{ port: "6379", protocol: TCP }]
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports: [{ port: "53", protocol: UDP }, { port: "53", protocol: TCP }]
          rules:
            dns: [{ matchPattern: "*" }]
    - toFQDNs:
        - matchPattern: "*.s3.${AWS_REGION}.amazonaws.com"
        - matchName: "s3.${AWS_REGION}.amazonaws.com"
      toPorts:
        - ports: [{ port: "443", protocol: TCP }]
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: ${BG_NETPOL}-target
  namespace: ${NS}
spec:
  endpointSelector:
    matchLabels: { app: ${INSTANCE} }
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: ${SEED_NS}
            app.kubernetes.io/component: redis-restore
            app.kubernetes.io/name: ${INSTANCE}
      toPorts:
        - ports: [{ port: "6379", protocol: TCP }]
YAML
ok "break-glass netpols applied"

# ---- 3. seed pod: download the RDB, boot redis from it ----------------------
say "creating seed pod (downloads the RDB, serves it as a master)"
kubectl -n "$SEED_NS" delete pod "$SEED_POD" --ignore-not-found >/dev/null 2>&1 || true
kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${SEED_POD}
  namespace: ${SEED_NS}
  labels:
    app.kubernetes.io/name: ${INSTANCE}
    app.kubernetes.io/component: redis-restore
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
    seccompProfile: { type: RuntimeDefault }
  initContainers:
    - name: fetch
      image: "${AWSCLI_IMAGE}"
      command: ["/bin/sh","-c","aws s3 cp \"${OBJECT}\" /data/dump.rdb"]
      env:
        - { name: HOME, value: /data }
        - { name: AWS_DEFAULT_REGION, value: "${AWS_REGION}" }
        - { name: AWS_ACCESS_KEY_ID,     valueFrom: { secretKeyRef: { name: ${SECRET_NAME}, key: AWS_ACCESS_KEY_ID } } }
        - { name: AWS_SECRET_ACCESS_KEY, valueFrom: { secretKeyRef: { name: ${SECRET_NAME}, key: AWS_SECRET_ACCESS_KEY } } }
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: ["ALL"] }
      volumeMounts: [{ name: data, mountPath: /data }]
  containers:
    - name: seed
      image: "${SEED_IMAGE}"
      command: ["redis-server","--appendonly","no","--save","","--protected-mode","no","--dir","/data","--dbfilename","dump.rdb"]
      ports: [{ containerPort: 6379 }]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: ["ALL"] }
      volumeMounts: [{ name: data, mountPath: /data }]
  volumes:
    - name: data
      emptyDir: {}
YAML

say "waiting for the seed pod to be Ready"
kubectl -n "$SEED_NS" wait --for=condition=Ready "pod/${SEED_POD}" --timeout=180s \
  || die "seed pod ${SEED_NS}/${SEED_POD} did not become Ready (check: kubectl -n ${SEED_NS} logs ${SEED_POD})"
SEED_IP="$(kubectl -n "$SEED_NS" get pod "$SEED_POD" -o jsonpath='{.status.podIP}')"
[ -n "$SEED_IP" ] || die "could not read seed pod IP"
SEED_DBSIZE="$(kubectl -n "$SEED_NS" exec "$SEED_POD" -c seed -- redis-cli DBSIZE | tr -dc '0-9')"
ok "seed serving on ${SEED_IP}, loaded ${SEED_DBSIZE} keys from the dump"

# ---- 4. resync the target from the seed -------------------------------------
say "FLUSHALL + REPLICAOF on the target (${TARGET_POD})"
kubectl -n "$NS" exec "$TARGET_POD" -- redis-cli FLUSHALL >/dev/null
kubectl -n "$NS" exec "$TARGET_POD" -- redis-cli REPLICAOF "$SEED_IP" 6379 >/dev/null

say "waiting for the full resync to complete"
LINK=""
for _ in $(seq 1 60); do
  LINK="$(kubectl -n "$NS" exec "$TARGET_POD" -- redis-cli INFO replication 2>/dev/null | tr -d '\r')"
  echo "$LINK" | grep -q 'master_link_status:up' \
    && echo "$LINK" | grep -q 'master_sync_in_progress:0' && break
  sleep 2
done
echo "$LINK" | grep -q 'master_link_status:up' || die "resync did not reach master_link_status:up — inspect the target and seed"
ok "resync complete"

say "promoting the target back to a standalone master (REPLICAOF NO ONE)"
kubectl -n "$NS" exec "$TARGET_POD" -- redis-cli REPLICAOF NO ONE >/dev/null
TGT_DBSIZE="$(kubectl -n "$NS" exec "$TARGET_POD" -- redis-cli DBSIZE | tr -dc '0-9')"
[ "$TGT_DBSIZE" = "$SEED_DBSIZE" ] && ok "target now holds ${TGT_DBSIZE} keys (matches the dump)" \
  || bad "target has ${TGT_DBSIZE} keys but the dump had ${SEED_DBSIZE} — investigate"

# ---- 5. done (trap tears down the seed + netpols) ---------------------------
summary
[ "$FAIL" -eq 0 ]
