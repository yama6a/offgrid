#!/usr/bin/env bash
# Restores a standalone Redis instance from its S3 RDB dumps. Resolves state first (what git declares vs what
# the cluster has), prints it, then runs three phases:
#
#   PHASE 1  get an instance to restore into. This replays a dump INTO a running instance and cannot create
#            one, so if the alias is still in git it WAITS for Argo and the operator. If nothing in git
#            declares it, it names the two files to put back (the Chart.yaml alias is not recoverable from
#            values.yaml alone) and stops. Refuses on an uncommitted values.yaml: Argo syncs the pushed
#            remote, not your working tree.
#   PHASE 2  pick a dump and replay it. An RDB under 250 bytes is EMPTY and takes an explicit yes, because
#            restoring one FLUSHALLs the instance and puts nothing back. That is data loss, and the script
#            still exits 0, so nothing tells you it happened. A temporary seed pod loads the RDB, break-glass CiliumNetworkPolicies open
#            target-to-seed on 6379, the target is FLUSHALLed and made a REPLICAOF of the seed so a full
#            resync carries every type, TTL and score, then it is promoted back. FAILS a 0-key restore.
#   PHASE 3  re-protect. A restore usually follows a delete that set deletionProtection false.
#
# The trap promotes the target back BEFORE tearing the seed down, so bailing out mid-restore cannot leave it
# a read-only replica of a deleted pod.
# Never runs git: it edits values.yaml and prints the commit for you.
#
# Usage (flags optional, prompts for anything missing):
#   bash recover_redis_from_s3.sh [--namespace NS] [--instance NAME] [--target latest|<N>|<s3-key>] [--apply]
#   make restore-redis
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
RB_VALUES="${REPO_ROOT}/argo_apps/platform/charts/07_redis_backup/values.yaml"  # single source for bucket/prefix
SEED_NS="redis-backup"                                            # the seed runs where the sealed creds live
SECRET_NAME="redis-backup-s3"                                     # the sealed writer creds in SEED_NS
# renovate: datasource=docker
AWSCLI_IMAGE="public.ecr.aws/aws-cli/aws-cli:2.36.14"             # the seed's S3-download initContainer
REBUILD_WAIT=600                  # phase 1: seconds to wait for Argo + the operator to rebuild a deleted instance
POLL=10

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
# download uses the sealed WRITER creds already in ns redis-backup, so no host writer creds are needed.
[ -n "$AWS_DEPLOY_ACCESS_KEY_ID" ] || die "AWS_DEPLOY_ACCESS_KEY_ID empty in .env, needed to list S3 backups"
export AWS_ACCESS_KEY_ID="$AWS_DEPLOY_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$AWS_DEPLOY_SECRET_ACCESS_KEY_SECRET"
export AWS_DEFAULT_REGION="$AWS_REGION"

BUCKET="$(yq -r '.bucket' "$RB_VALUES")"
PREFIX="$(yq -r '.prefix' "$RB_VALUES")"
[ -n "$BUCKET" ] && [ "$BUCKET" != "null" ] || die "bucket is unset in ${RB_VALUES}: run 15_redis_backup.sh first"

say "Redis restore from S3: seed pod + replication resync (in-place, non-destructive to the CR)"

# Total keys across ALL databases. DBSIZE counts only the currently selected db, but FLUSHALL clears every db
# and the seed loads every db the RDB contains, so a dump using db1+ would be under-counted on BOTH sides and
# the equality check would still "match". Sums the keys=N fields of INFO keyspace; prints 0 when empty.
redis_keycount() {  # redis_keycount <namespace> <pod> <container>
  kubectl -n "$1" exec "$2" -c "$3" -- redis-cli INFO keyspace 2>/dev/null \
    | tr -d '\r' | sed -n 's/^db[0-9][0-9]*:keys=\([0-9][0-9]*\),.*/\1/p' | awk '{s+=$1} END {print s+0}'
}

[ -n "$NS" ]       || read -rp "Namespace: " NS
[ -n "$INSTANCE" ] || read -rp "Redis instance name (the CR / Service name): " INSTANCE
[ -n "$NS" ] && [ -n "$INSTANCE" ] || die "namespace and instance are required"

kubectl -n "$SEED_NS" get secret "$SECRET_NAME" >/dev/null 2>&1 \
  || die "sealed creds ${SEED_NS}/${SECRET_NAME} missing: enable backups first (make configure-redis-backup)"

# Same shape as recover_cnpg_from_s3.sh: resolve everything first, print it, then decide. redisVersion is the
# kind discriminator so this can never bind to a pg-cluster alias of the same name.
FOUND="$(wl_find_alias "$INSTANCE" redisVersion || true)"
VALUES=""; ALIAS=""; IFS=$'\t' read -r VALUES ALIAS <<< "$FOUND" || true   # tab-separated, split explicitly
GIT_PROTECT="no"; DIRTY="no"
if [ -n "$FOUND" ]; then
  [ "$(vy_read "$VALUES" "$ALIAS" deletionProtection)" = "true" ] && GIT_PROTECT="yes"
  git -C "$REPO_ROOT" diff --quiet -- "$VALUES" 2>/dev/null || DIRTY="yes"
fi
CR_EXISTS="no"; kubectl -n "$NS" get redis "$INSTANCE" >/dev/null 2>&1 && CR_EXISTS="yes"

say "State"
echo "    instance            : ${NS}/${INSTANCE}"
echo "    live Redis CR       : ${CR_EXISTS}"
if [ -n "$FOUND" ]; then
  echo "    owning chart        : ${VALUES#${REPO_ROOT}/} (alias '${ALIAS}')"
  echo "    git deletionProtection: ${GIT_PROTECT}"
  echo "    uncommitted edits to that values.yaml: ${DIRTY}"
else
  echo "    owning chart        : NOT IN GIT"
fi

# This script replays a dump INTO a running instance; it cannot create one. But when the alias is still in git
# the instance is already on its way back, so wait for Argo instead of making the operator poll by hand.
say "PHASE 1/3, target instance"
if [ -z "$FOUND" ] && [ "$CR_EXISTS" = "no" ]; then
  die "$(printf 'no Redis instance %s/%s, and no workload chart in git declares it.\n' "$NS" "$INSTANCE")
Restore it in git FIRST, then re-run this and it will wait for Argo to build it:
  1. put back its values block AND its Chart.yaml alias entry (the alias is not recoverable from values alone)
  2. git add/commit/push
  3. make restore-redis
It comes back EMPTY on a fresh PVC; this script then loads the dump into it. See docs/12_redis.md."
fi
if [ "$DIRTY" = "yes" ]; then
  warn "${VALUES#${REPO_ROOT}/} has uncommitted changes: ArgoCD syncs the pushed remote, not your working tree."
  die "commit + push first, then re-run."
fi
if [ "$CR_EXISTS" = "no" ]; then
  say "alias '${ALIAS}' is in git but the instance is not up yet; waiting up to ${REBUILD_WAIT}s for Argo"
  DEADLINE=$(( $(date +%s) + REBUILD_WAIT ))
  while :; do
    kubectl -n "$NS" get redis "$INSTANCE" >/dev/null 2>&1 && { ok "Redis CR ${INSTANCE} exists"; break; }
    [ "$(date +%s)" -ge "$DEADLINE" ] && die "no Redis CR ${NS}/${INSTANCE} after ${REBUILD_WAIT}s. Did the commit get pushed? Check: kubectl -n argocd get app"
    printf '    waiting for the CR...\n'; sleep "$POLL"
  done
fi

# The pod is what we exec into, and it lags the CR by the time the operator needs to build the StatefulSet.
TARGET_POD=""
DEADLINE=$(( $(date +%s) + REBUILD_WAIT ))
while :; do
  TARGET_POD="$(kubectl -n "$NS" get pod -l "app=${INSTANCE}" \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "$TARGET_POD" ] \
     && [ "$(kubectl -n "$NS" get pod "$TARGET_POD" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]; then
    ok "pod ${TARGET_POD} is Ready"; break
  fi
  [ "$(date +%s)" -ge "$DEADLINE" ] && die "no Ready pod with label app=${INSTANCE} in ${NS} after ${REBUILD_WAIT}s; inspect: kubectl -n ${NS} get pods -l app=${INSTANCE}"
  printf '    waiting for a Ready pod...\n'; sleep "$POLL"
done

# Seed image == the image THIS instance actually runs, read off its live CR. An RDB is forward-only, so the seed
# that loads it must match the instance's version, and redisVersion is per-workload (no global tag to grep).
SEED_IMAGE="$(kubectl -n "$NS" get redis "$INSTANCE" -o jsonpath='{.spec.kubernetesConfig.image}')"
[ -n "$SEED_IMAGE" ] || die "could not read .spec.kubernetesConfig.image from redis ${NS}/${INSTANCE}"

DEST="s3://${BUCKET}/${PREFIX}${NS}/${INSTANCE}/"
EMPTY_OK="false"
EMPTY_RDB_BYTES=250   # an empty RDB is ~90-200 bytes (header + metadata, no keys); under this it holds no data

# Show what is restorable, with size and age. `latest` on its own hides both an ancient dump and an EMPTY one,
# and the next step FLUSHALLs the instance, so the choice needs evidence in front of it.
say "PHASE 2/3, pick a dump and replay it"
say "dumps available under ${DEST}"
# `|| true`: no matching objects makes grep exit 1, and under `set -e` a failing command substitution kills the
# script silently, before the die below can explain what is wrong.
LISTING="$(aws s3 ls "$DEST" 2>/dev/null | grep -E '\.rdb$' | sort -k1,2 || true)"
[ -n "$LISTING" ] || die "$(printf 'no .rdb objects under %s: nothing to restore.\n' "$DEST")
Either this instance was never backed up (is it persistence:true, so the central job discovers it?), or the
dumps are under a different prefix. Check:  aws s3 ls s3://${BUCKET}/${PREFIX} --recursive"

NOW="$(date -u +%s)"
KEYS=""; SIZES=""; N=0
printf '    %-3s %-24s %10s  %s\n' "#" "KEY" "BYTES" "AGE"
while read -r D T SZ K; do
  [ -n "$K" ] || continue
  N=$((N+1)); KEYS="${KEYS}${K}"$'\n'; SIZES="${SIZES}${SZ}"$'\n'
  # GNU date first, then BSD: a mac with homebrew coreutils on PATH has GNU, a stock one has BSD. `aws s3 ls`
  # prints LastModified in LOCAL time, so neither call passes -u. Age just prints "?" if both fail.
  EPOCH="$(date -d "${D} ${T}" +%s 2>/dev/null || date -j -f '%Y-%m-%d %H:%M:%S' "${D} ${T}" +%s 2>/dev/null || echo 0)"
  if [ "$EPOCH" != "0" ]; then AGE="$(( (NOW - EPOCH) / 3600 ))h"; else AGE="?"; fi
  FLAG=""; [ "$SZ" -lt "$EMPTY_RDB_BYTES" ] 2>/dev/null && FLAG="  <-- looks EMPTY"
  printf '    %-3s %-24s %10s  %s%s\n' "$N" "$K" "$SZ" "$AGE" "$FLAG"
done <<< "$LISTING"

# Resolve the selection: latest (default) | an index from the list above | a full key relative to the bucket.
if [ "$TARGET" = "latest" ] && [ "$DO_APPLY" != "true" ] && [ "$N" -gt 1 ]; then
  read -rp "Which dump? [1-${N}, or Enter for the newest]: " PICK
  [ -n "$PICK" ] && TARGET="$PICK"
fi
case "$TARGET" in
  latest) KEY="$(printf '%s' "$KEYS" | tail -1)"; SIZE="$(printf '%s' "$SIZES" | tail -1)"; OBJECT="${DEST}${KEY}" ;;
  ''|*[!0-9]*) OBJECT="s3://${BUCKET}/${TARGET#/}"   # a full key relative to the bucket
               SIZE="$(aws s3 ls "$OBJECT" 2>/dev/null | awk '{print $3}' | head -1)" ;;
  *) [ "$TARGET" -ge 1 ] && [ "$TARGET" -le "$N" ] || die "pick 1-${N}, got ${TARGET}"
     KEY="$(printf '%s' "$KEYS" | sed -n "${TARGET}p")"; SIZE="$(printf '%s' "$SIZES" | sed -n "${TARGET}p")"
     OBJECT="${DEST}${KEY}" ;;
esac
# head-object, not `s3 ls`: ls is a PREFIX listing, so a truncated or mistyped key that happens to prefix a real
# object would pass. This also returns the authoritative size for the empty-dump guard below.
OBJ_KEY="${OBJECT#s3://${BUCKET}/}"
HEAD="$(aws s3api head-object --bucket "$BUCKET" --key "$OBJ_KEY" 2>/dev/null || true)"
[ -n "$HEAD" ] || die "no such object: ${OBJECT} (exact key match; pick one from the list above)"
SIZE="$(printf '%s' "$HEAD" | sed -n 's/.*"ContentLength"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"
ok "restoring from: ${OBJECT} (${SIZE:-?} bytes)"

# The one guard that matters: this sits in front of a FLUSHALL. Restoring an empty dump is a data-loss event
# dressed up as a successful restore, so it takes an explicit yes.
if [ -n "${SIZE:-}" ] && [ "$SIZE" -lt "$EMPTY_RDB_BYTES" ] 2>/dev/null; then
  warn "that dump is only ${SIZE} bytes, which is an EMPTY redis dump (no keys)."
  warn "Restoring it FLUSHALLs the instance and puts nothing back: the data is gone, and the run would look fine."
  if [ "$DO_APPLY" = "true" ]; then
    die "refusing to restore an empty dump non-interactively; pick another with --target, or re-run without --apply to confirm"
  fi
  read -rp "Wipe the instance with an EMPTY dump anyway? [y/N]: " EOK
  [[ "$EOK" =~ ^[Yy]$ ]] || { warn "Aborted."; exit 0; }
  EMPTY_OK="true"
fi

# The pod runs the redis container alongside a redis-exporter sidecar and carries no default-container
# annotation, so a bare `exec` silently depends on container ordering. Name it: anything but the exporter.
TARGET_CTR="$(kubectl -n "$NS" get pod "$TARGET_POD" \
  -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null | grep -v '^redis-exporter$' | head -1)"
[ -n "$TARGET_CTR" ] || die "could not find the redis container in pod ${NS}/${TARGET_POD}"

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

# PROMOTE FIRST, then tear down. A replica whose master is gone keeps serving reads but refuses writes, so
# bailing out between FLUSHALL and the promote would leave the instance up, empty and write-refusing: worse
# than down, and nothing alerts on it (no replication-role rule in redis-health.yaml).
# Promoting is safe to run unconditionally, including when the instance was never made a replica.
PROMOTED="no"
cleanup() {
  if [ "$PROMOTED" != "yes" ] && [ -n "${TARGET_POD:-}" ]; then
    warn "promoting ${TARGET_POD} back to a standalone master (bailing out mid-restore)"
    kubectl -n "$NS" exec "$TARGET_POD" -c "$TARGET_CTR" -- redis-cli REPLICAOF NO ONE >/dev/null 2>&1 \
      || warn "could not promote ${TARGET_POD}: it may still be a read-only replica, fix with: kubectl -n ${NS} exec ${TARGET_POD} -c ${TARGET_CTR} -- redis-cli REPLICAOF NO ONE"
  fi
  warn "cleaning up seed pod + break-glass netpols"
  kubectl -n "$SEED_NS" delete pod "$SEED_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$SEED_NS" delete ciliumnetworkpolicy "${BG_NETPOL}-seed" --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$NS" delete ciliumnetworkpolicy "${BG_NETPOL}-target" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

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
SEED_DBSIZE="$(redis_keycount "$SEED_NS" "$SEED_POD" seed)"
ok "seed serving on ${SEED_IP}, loaded ${SEED_DBSIZE} keys from the dump"

BEFORE_DBSIZE="$(redis_keycount "$NS" "$TARGET_POD" "$TARGET_CTR")"
say "FLUSHALL + REPLICAOF on the target (${TARGET_POD}); it currently holds ${BEFORE_DBSIZE} keys"
kubectl -n "$NS" exec "$TARGET_POD" -c "$TARGET_CTR" -- redis-cli FLUSHALL >/dev/null
kubectl -n "$NS" exec "$TARGET_POD" -c "$TARGET_CTR" -- redis-cli REPLICAOF "$SEED_IP" 6379 >/dev/null

say "waiting for the full resync to complete"
LINK=""
for _ in $(seq 1 60); do
  LINK="$(kubectl -n "$NS" exec "$TARGET_POD" -c "$TARGET_CTR" -- redis-cli INFO replication 2>/dev/null | tr -d '\r')"
  echo "$LINK" | grep -q 'master_link_status:up' \
    && echo "$LINK" | grep -q 'master_sync_in_progress:0' && break
  sleep 2
done
echo "$LINK" | grep -q 'master_link_status:up' || die "resync did not reach master_link_status:up, inspect the target and seed"
ok "resync complete"

say "promoting the target back to a standalone master (REPLICAOF NO ONE)"
kubectl -n "$NS" exec "$TARGET_POD" -c "$TARGET_CTR" -- redis-cli REPLICAOF NO ONE >/dev/null
PROMOTED="yes"   # past here the trap no longer needs to rescue the target
TGT_DBSIZE="$(redis_keycount "$NS" "$TARGET_POD" "$TARGET_CTR")"
# Key COUNT equality alone is not a pass: 0 == 0 is equal, so wiping an instance with an empty dump would
# report success. Judge the outcome, not just the arithmetic.
if [ "$TGT_DBSIZE" != "$SEED_DBSIZE" ]; then
  bad "target has ${TGT_DBSIZE} keys but the dump had ${SEED_DBSIZE}, investigate"
elif [ "$TGT_DBSIZE" = "0" ]; then
  if [ "$EMPTY_OK" = "true" ]; then
    warn "target is EMPTY (${BEFORE_DBSIZE} keys replaced by 0); you confirmed an empty dump, so this is expected"
  else
    bad "restored 0 keys over ${BEFORE_DBSIZE}: the dump was empty and this instance is now empty too"
  fi
else
  ok "${BEFORE_DBSIZE} keys replaced by ${TGT_DBSIZE} (matches the dump)"
fi

# DBSIZE says nothing about types or TTLs, which is the whole reason this restores by replication rather than
# copying keys. Sample a few so the operator sees fidelity, not just a count.
if [ "$TGT_DBSIZE" != "0" ]; then
  say "fidelity sample (key, type, ttl)"
  kubectl -n "$NS" exec "$TARGET_POD" -c "$TARGET_CTR" -- sh -c \
    'for k in $(redis-cli --scan --count 5 | head -5); do printf "    %-44s %-10s ttl=%s\n" "$k" "$(redis-cli TYPE "$k")" "$(redis-cli TTL "$k")"; done' 2>/dev/null \
    || warn "could not sample keys"
fi

# A restore usually follows a deliberate two-commit delete, which left deletionProtection false. Put it back the
# same way the CNPG script does: edit, assert, print the commit. No script here runs git.
say "PHASE 3/3, re-protect"
if [ -z "$FOUND" ]; then
  warn "instance is not declared in any workload chart, so there is no deletionProtection to restore"
elif [ "$GIT_PROTECT" = "yes" ]; then
  ok "${ALIAS}.deletionProtection is already true in git, nothing to do"
elif [ "$FAIL" -ne 0 ]; then
  warn "restore reported failures, so NOT re-protecting; fix the data first, then set ${ALIAS}.deletionProtection=true"
else
  vy_protect_on "$VALUES" "$ALIAS" || die "edit failed"
  [ "$(vy_read "$VALUES" "$ALIAS" deletionProtection)" = "true" ] \
    && ok "set ${ALIAS}.deletionProtection=true in ${VALUES#${REPO_ROOT}/} (it was false; never leave an instance unprotected)" \
    || die "post-edit check failed: ${ALIAS}.deletionProtection is not true"
  git -C "$REPO_ROOT" --no-pager diff --stat -- "$VALUES" | sed 's/^/    /'
  cat <<NEXT

Last step, commit and push:

    git add ${VALUES#${REPO_ROOT}/}
    git commit -m "${INSTANCE}: restore done, re-protect"
    git push

NB this flip is NOT inert: the operator copies the CR's annotations onto its StatefulSet pod template, so adding
the sync-options back RESTARTS the pod (~20s). The data survives on the AOF. See docs/12_redis.md.
NEXT
fi

summary
[ "$FAIL" -eq 0 ]
