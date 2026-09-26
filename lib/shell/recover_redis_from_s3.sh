#!/usr/bin/env bash
# Restores a standalone Redis instance in place from its S3 RDB dumps. The Redis CR stays as it is.
# It edits values.yaml and prints the git commands. It never runs git.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat << EOF
recover_redis_from_s3.sh [--namespace <ns>] [--instance <name>] [--target latest|<N>|<s3-key>] [--apply]
                                                                          (or: make restore-redis)
  Every flag is optional. The script prompts for anything missing.
  --target   latest (the default), a number from the printed list, or a full key relative to the bucket
  --apply    skip the confirmation prompts

Three phases:
  1  Find the instance to restore into. The script loads a dump into a running instance and cannot
     create one. If the alias is still in git, it waits for Argo CD and the operator. If no chart in git
     declares it, it names the two files to put back and stops. It stops on an uncommitted values.yaml,
     because Argo CD syncs the pushed remote, not your working tree.
  2  Pick a dump and load it. A temporary seed pod loads the RDB. Break-glass CiliumNetworkPolicies open
     port 6379 from the target to the seed. The script runs FLUSHALL on the target, then REPLICAOF so
     it replicates the seed. The full resync carries every type, TTL and score. Then it promotes the
     target back. A restore that ends with 0 keys fails.
  3  Protect the instance again. A restore usually follows a delete that set deletionProtection to false.
EOF
}

# ---- knobs ----
RB_VALUES="${PLATFORM_CHARTS}/07_redis_backup/values.yaml" # the one place that holds bucket and prefix
SEED_NS="redis-backup"                                     # the seed pod runs where the sealed creds live
SECRET_NAME="redis-backup-s3"                              # the sealed writer creds in SEED_NS
# renovate: datasource=docker
AWSCLI_IMAGE="public.ecr.aws/aws-cli/aws-cli:2.37.4" # init container of the seed pod that downloads from S3
REBUILD_WAIT=600                                     # seconds to wait for Argo CD and the operator to rebuild an instance
POLL=10
EMPTY_RDB_BYTES=250 # an RDB with no keys is about 90 to 200 bytes. A smaller dump holds no data.

# ---- state ----
NS="" # set by parse_args or prompt_for_instance
INSTANCE=""
TARGET="latest"
DO_APPLY="false"
BUCKET="" # set by read_backup_values
PREFIX=""
FOUND="" # set by resolve_git_state
VALUES=""
ALIAS=""
GIT_PROTECT="no"
DIRTY="no"
CR_EXISTS="no"
TARGET_POD="" # set by wait_for_target_pod
TARGET_CTR="" # set by resolve_target_container
SEED_IMAGE="" # set by read_seed_image
DEST=""       # set by list_dumps
KEYS=""
N=0
OBJECT="" # set by resolve_dump
SIZE=""
EMPTY_OK="false"
SEED_POD="" # set by resolve_dump
BG_NETPOL=""
SEED_IP="" # set by start_seed_pod
SEED_DBSIZE=0
BEFORE_DBSIZE=0 # set by resync_from_seed
TGT_DBSIZE=0
PROMOTED="no" # read by the EXIT trap

# ---- functions ----

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --namespace)
        NS="$2"
        shift 2
        ;;
      --instance)
        INSTANCE="$2"
        shift 2
        ;;
      --target)
        TARGET="$2"
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
      *) die "unknown arg: $1. See --help." ;;
    esac
  done
}

# The host lists S3 with the deploy creds from .env. The seed pod downloads with the sealed writer creds.
use_deploy_creds() {
  [ -n "$AWS_DEPLOY_ACCESS_KEY_ID" ] || die "AWS_DEPLOY_ACCESS_KEY_ID is empty in .env. It is needed to list the S3 backups."
  export_deploy_aws_creds
}

read_backup_values() {
  BUCKET="$(yq -r '.bucket' "$RB_VALUES")"
  PREFIX="$(yq -r '.prefix' "$RB_VALUES")"
  [ -n "$BUCKET" ] && [ "$BUCKET" != "null" ] || die "bucket is unset in ${RB_VALUES}. Run 10c_redis_backup.sh first."
  say "Redis restore from S3: seed pod and replication resync, in place. The Redis CR stays as it is."
}

# Sums the keys of all databases from INFO keyspace. DBSIZE counts only the selected db, but FLUSHALL and the
# seed cover every db. With DBSIZE, a dump that uses db1 or higher would still pass the equality check.
redis_keycount() { # redis_keycount <namespace> <pod> <container>
  kubectl -n "$1" exec "$2" -c "$3" -- redis-cli INFO keyspace 2> /dev/null \
    | tr -d '\r' | sed -n 's/^db[0-9][0-9]*:keys=\([0-9][0-9]*\),.*/\1/p' | awk '{s+=$1} END {print s+0}'
}

prompt_for_instance() {
  [ -n "$NS" ] || read -rp "Namespace: " NS
  [ -n "$INSTANCE" ] || read -rp "Redis instance name, the CR and Service name: " INSTANCE
  [ -n "$NS" ] && [ -n "$INSTANCE" ] || die "namespace and instance are required"
  kubectl -n "$SEED_NS" get secret "$SECRET_NAME" > /dev/null 2>&1 \
    || die "sealed creds ${SEED_NS}/${SECRET_NAME} missing. Turn on backups first: make configure-redis-backup"
}

resolve_git_state() {
  FOUND="$(wl_find_alias "$INSTANCE" redisVersion || true)"
  IFS=$'\t' read -r VALUES ALIAS <<< "$FOUND" || true
  if [ -n "$FOUND" ]; then
    [ "$(vy_read "$VALUES" "$ALIAS" deletionProtection)" = "true" ] && GIT_PROTECT="yes"
    git -C "$REPO_ROOT" diff --quiet -- "$VALUES" 2> /dev/null || DIRTY="yes"
  fi
  kubectl -n "$NS" get redis "$INSTANCE" > /dev/null 2>&1 && CR_EXISTS="yes"
  say "State"
  echo "    instance            : ${NS}/${INSTANCE}"
  echo "    live Redis CR       : ${CR_EXISTS}"
  if [ -n "$FOUND" ]; then
    echo "    owning chart        : ${VALUES#"${REPO_ROOT}"/}, alias '${ALIAS}'"
    echo "    git deletionProtection: ${GIT_PROTECT}"
    echo "    uncommitted edits to that values.yaml: ${DIRTY}"
  else
    echo "    owning chart        : not in git"
  fi
}

wait_for_target_cr() {
  local deadline
  say "phase 1/3, target instance"
  if [ -z "$FOUND" ] && [ "$CR_EXISTS" = "no" ]; then
    die "$(printf 'no Redis instance %s/%s, and no workload chart in git declares it.\n' "$NS" "$INSTANCE")
Restore it in git first. Then run this script again, and it waits for Argo CD to build the instance:
  1. Put back its values block and its Chart.yaml alias entry. The values alone do not name the alias.
  2. Commit and push.
  3. Run make restore-redis.
The instance comes back empty on a new PVC. This script then loads the dump into it. See docs/09_redis.md."
  fi
  if [ "$DIRTY" = "yes" ]; then
    warn "${VALUES#"${REPO_ROOT}"/} has uncommitted changes. Argo CD syncs the pushed remote, not your working tree."
    die "commit and push first, then run again."
  fi
  [ "$CR_EXISTS" = "no" ] || return 0
  say "alias '${ALIAS}' is in git, but the instance is not up yet. Waiting up to ${REBUILD_WAIT}s for Argo CD."
  deadline=$(($(date +%s) + REBUILD_WAIT))
  while :; do
    kubectl -n "$NS" get redis "$INSTANCE" > /dev/null 2>&1 && {
      ok "Redis CR ${INSTANCE} exists"
      break
    }
    [ "$(date +%s)" -ge "$deadline" ] && die "no Redis CR ${NS}/${INSTANCE} after ${REBUILD_WAIT}s. Was the commit pushed? Check: kubectl -n argocd get app"
    printf '    waiting for the CR...\n'
    sleep "$POLL"
  done
}

# The pod appears some time after the CR, once the operator has built the StatefulSet.
wait_for_target_pod() {
  local deadline
  deadline=$(($(date +%s) + REBUILD_WAIT))
  while :; do
    TARGET_POD="$(kubectl -n "$NS" get pod -l "app=${INSTANCE}" \
      --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2> /dev/null || true)"
    if [ -n "$TARGET_POD" ] \
      && [ "$(kubectl -n "$NS" get pod "$TARGET_POD" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2> /dev/null)" = "True" ]; then
      ok "pod ${TARGET_POD} is Ready"
      break
    fi
    [ "$(date +%s)" -ge "$deadline" ] && die "no Ready pod with label app=${INSTANCE} in ${NS} after ${REBUILD_WAIT}s. Inspect: kubectl -n ${NS} get pods -l app=${INSTANCE}"
    printf '    waiting for a Ready pod...\n'
    sleep "$POLL"
  done
}

# An older Redis cannot load a newer RDB, so the seed uses the image of the live CR.
read_seed_image() {
  SEED_IMAGE="$(kubectl -n "$NS" get redis "$INSTANCE" -o jsonpath='{.spec.kubernetesConfig.image}')"
  [ -n "$SEED_IMAGE" ] || die "could not read .spec.kubernetesConfig.image from redis ${NS}/${INSTANCE}"
}

# Shows size and age of each dump, because the next step runs FLUSHALL. `latest` alone hides an old or empty dump.
list_dumps() {
  local listing now d t sz k epoch age flag
  DEST="s3://${BUCKET}/${PREFIX}${NS}/${INSTANCE}/"
  say "phase 2/3, pick a dump and load it"
  say "dumps available under ${DEST}"
  # With no match grep exits 1, and `set -e` would stop the script before the die below explains why.
  listing="$(aws s3 ls "$DEST" 2> /dev/null | grep -E '\.rdb$' | sort -k1,2 || true)"
  [ -n "$listing" ] || die "$(printf 'no .rdb objects under %s. Nothing to restore.\n' "$DEST")
Either this instance never had a backup, or the dumps are under a different prefix.
The backup job finds only instances with persistence: true. Check: aws s3 ls s3://${BUCKET}/${PREFIX} --recursive"

  now="$(date -u +%s)"
  printf '    %-3s %-24s %10s  %s\n' "#" "KEY" "BYTES" "AGE"
  while read -r d t sz k; do
    [ -n "$k" ] || continue
    N=$((N + 1))
    KEYS="${KEYS}${k}"$'\n'
    # GNU date first, then BSD date for a stock macOS. `aws s3 ls` prints local time, so neither call passes -u.
    epoch="$(date -d "${d} ${t}" +%s 2> /dev/null || date -j -f '%Y-%m-%d %H:%M:%S' "${d} ${t}" +%s 2> /dev/null || echo 0)"
    if [ "$epoch" != "0" ]; then age="$(((now - epoch) / 3600))h"; else age="?"; fi
    flag=""
    [ "$sz" -lt "$EMPTY_RDB_BYTES" ] 2> /dev/null && flag="  looks empty"
    printf '    %-3s %-24s %10s  %s%s\n' "$N" "$k" "$sz" "$age" "$flag"
  done <<< "$listing"
}

# head-object needs the exact key. `s3 ls` matches a prefix, so a truncated key would pass.
resolve_dump() {
  local pick key obj_key head
  if [ "$TARGET" = "latest" ] && [ "$DO_APPLY" != "true" ] && [ "$N" -gt 1 ]; then
    read -rp "Which dump? [1-${N}, or Enter for the newest]: " pick
    [ -n "$pick" ] && TARGET="$pick"
  fi
  case "$TARGET" in
    latest)
      key="$(printf '%s' "$KEYS" | tail -1)"
      OBJECT="${DEST}${key}"
      ;;
    '' | *[!0-9]*) OBJECT="s3://${BUCKET}/${TARGET#/}" ;; # a full key, relative to the bucket
    *)
      [ "$TARGET" -ge 1 ] && [ "$TARGET" -le "$N" ] || die "pick 1 to ${N}, got ${TARGET}"
      key="$(printf '%s' "$KEYS" | sed -n "${TARGET}p")"
      OBJECT="${DEST}${key}"
      ;;
  esac
  obj_key="${OBJECT#s3://"${BUCKET}"/}"
  head="$(aws s3api head-object --bucket "$BUCKET" --key "$obj_key" 2> /dev/null || true)"
  [ -n "$head" ] || die "no such object: ${OBJECT}. The key must match exactly. Pick one from the list above."
  SIZE="$(printf '%s' "$head" | sed -n 's/.*"ContentLength"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"
  ok "restoring from: ${OBJECT}, ${SIZE:-?} bytes"
  SEED_POD="redis-restore-${INSTANCE}"
  BG_NETPOL="redis-restore-breakglass-${INSTANCE}"
}

# An empty dump after FLUSHALL loses all data and still looks like a successful restore. It needs an explicit yes.
guard_empty_dump() {
  local answer
  [ -n "${SIZE:-}" ] && [ "$SIZE" -lt "$EMPTY_RDB_BYTES" ] 2> /dev/null || return 0
  warn "that dump is only ${SIZE} bytes. It is an empty Redis dump with no keys."
  warn "The restore runs FLUSHALL on the instance and puts nothing back. The data is gone, and the run looks fine."
  if [ "$DO_APPLY" = "true" ]; then
    die "refusing to restore an empty dump without a prompt. Pick another with --target, or run again without --apply to confirm."
  fi
  read -rp "Wipe the instance with an empty dump anyway? [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || {
    warn "Aborted."
    exit 0
  }
  EMPTY_OK="true"
}

# The pod also runs a redis-exporter sidecar and has no default-container annotation. So name the container.
resolve_target_container() {
  TARGET_CTR="$(kubectl -n "$NS" get pod "$TARGET_POD" \
    -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}' 2> /dev/null | grep -v '^redis-exporter$' | head -1)"
  [ -n "$TARGET_CTR" ] || die "could not find the redis container in pod ${NS}/${TARGET_POD}"
}

confirm_restore() {
  local answer
  echo
  say "Restore plan"
  echo "    Target      : ${NS}/${INSTANCE}, pod ${TARGET_POD}"
  echo "    From        : ${OBJECT}"
  echo "    Seed pod    : ${SEED_NS}/${SEED_POD}, image ${SEED_IMAGE}"
  echo "    Method      : FLUSHALL the target, REPLICAOF the seed, then promote the target back. A clean replace."
  echo
  warn "This erases the current data of the target and replaces it with the dump. It cannot be undone."
  [ "$DO_APPLY" = "true" ] && return 0
  read -rp "Proceed? [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || {
    warn "Aborted."
    exit 0
  }
}

# Promote first, then clean up. A replica without its master refuses writes, and no alert fires for that.
# Promoting is always safe, also on an instance that was never a replica.
cleanup() {
  if [ "$PROMOTED" != "yes" ] && [ -n "${TARGET_POD:-}" ]; then
    warn "promoting ${TARGET_POD} back to a standalone master, because the restore stopped early"
    kubectl -n "$NS" exec "$TARGET_POD" -c "$TARGET_CTR" -- redis-cli REPLICAOF NO ONE > /dev/null 2>&1 \
      || warn "could not promote ${TARGET_POD}. It may still be a read-only replica. Fix it with: kubectl -n ${NS} exec ${TARGET_POD} -c ${TARGET_CTR} -- redis-cli REPLICAOF NO ONE"
  fi
  warn "removing the seed pod and the break-glass network policies"
  kubectl -n "$SEED_NS" delete pod "$SEED_POD" --ignore-not-found --wait=false > /dev/null 2>&1 || true
  kubectl -n "$SEED_NS" delete ciliumnetworkpolicy "${BG_NETPOL}-seed" --ignore-not-found > /dev/null 2>&1 || true
  kubectl -n "$NS" delete ciliumnetworkpolicy "${BG_NETPOL}-target" --ignore-not-found > /dev/null 2>&1 || true
}

apply_breakglass_netpols() {
  say "applying break-glass network policies"
  kubectl apply -f - > /dev/null << YAML
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
  ok "break-glass network policies applied"
}

start_seed_pod() {
  say "creating the seed pod. It downloads the RDB and serves it as a master."
  kubectl -n "$SEED_NS" delete pod "$SEED_POD" --ignore-not-found > /dev/null 2>&1 || true
  kubectl apply -f - > /dev/null << YAML
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
    || die "seed pod ${SEED_NS}/${SEED_POD} did not become Ready. Check: kubectl -n ${SEED_NS} logs ${SEED_POD}"
  SEED_IP="$(kubectl -n "$SEED_NS" get pod "$SEED_POD" -o jsonpath='{.status.podIP}')"
  [ -n "$SEED_IP" ] || die "could not read the seed pod IP"
  SEED_DBSIZE="$(redis_keycount "$SEED_NS" "$SEED_POD" seed)"
  ok "seed serving on ${SEED_IP}, loaded ${SEED_DBSIZE} keys from the dump"
}

resync_from_seed() {
  local link="" _
  BEFORE_DBSIZE="$(redis_keycount "$NS" "$TARGET_POD" "$TARGET_CTR")"
  say "FLUSHALL and REPLICAOF on the target ${TARGET_POD}. It holds ${BEFORE_DBSIZE} keys now."
  kubectl -n "$NS" exec "$TARGET_POD" -c "$TARGET_CTR" -- redis-cli FLUSHALL > /dev/null
  kubectl -n "$NS" exec "$TARGET_POD" -c "$TARGET_CTR" -- redis-cli REPLICAOF "$SEED_IP" 6379 > /dev/null

  say "waiting for the full resync to complete"
  for _ in $(seq 1 60); do
    link="$(kubectl -n "$NS" exec "$TARGET_POD" -c "$TARGET_CTR" -- redis-cli INFO replication 2> /dev/null | tr -d '\r')"
    echo "$link" | grep -q 'master_link_status:up' \
      && echo "$link" | grep -q 'master_sync_in_progress:0' && break
    sleep 2
  done
  echo "$link" | grep -q 'master_link_status:up' || die "resync did not reach master_link_status:up. Inspect the target and the seed."
  ok "resync complete"
}

# Equal key counts are not enough. 0 equals 0, so an empty dump would pass.
promote_and_verify() {
  say "promoting the target back to a standalone master with REPLICAOF NO ONE"
  kubectl -n "$NS" exec "$TARGET_POD" -c "$TARGET_CTR" -- redis-cli REPLICAOF NO ONE > /dev/null
  PROMOTED="yes" # from here on the trap does not need to promote the target
  TGT_DBSIZE="$(redis_keycount "$NS" "$TARGET_POD" "$TARGET_CTR")"
  if [ "$TGT_DBSIZE" != "$SEED_DBSIZE" ]; then
    bad "target has ${TGT_DBSIZE} keys, but the dump had ${SEED_DBSIZE}. Investigate."
  elif [ "$TGT_DBSIZE" = "0" ]; then
    if [ "$EMPTY_OK" = "true" ]; then
      warn "target is empty: 0 keys replaced ${BEFORE_DBSIZE}. You confirmed an empty dump, so this is expected."
    else
      bad "restored 0 keys over ${BEFORE_DBSIZE}. The dump was empty, and this instance is now empty too."
    fi
  else
    ok "${TGT_DBSIZE} keys replaced ${BEFORE_DBSIZE}. This matches the dump."
  fi
}

# A key count says nothing about types or TTLs. Those are why this restores by replication, so sample a few.
sample_fidelity() {
  [ "$TGT_DBSIZE" != "0" ] || return 0
  say "sample of restored keys: key, type, ttl"
  kubectl -n "$NS" exec "$TARGET_POD" -c "$TARGET_CTR" -- sh -c \
    'for k in $(redis-cli --scan --count 5 | head -5); do printf "    %-44s %-10s ttl=%s\n" "$k" "$(redis-cli TYPE "$k")" "$(redis-cli TTL "$k")"; done' 2> /dev/null \
    || warn "could not sample keys"
}

# A restore usually follows a deliberate delete in two commits, which left deletionProtection false.
reprotect() {
  say "phase 3/3, protect the instance again"
  if [ -z "$FOUND" ]; then
    warn "no workload chart declares this instance, so there is no deletionProtection to set"
    return 0
  fi
  if [ "$GIT_PROTECT" = "yes" ]; then
    ok "${ALIAS}.deletionProtection is already true in git. Nothing to do."
    return 0
  fi
  if [ "$FAIL" -ne 0 ]; then
    warn "the restore reported failures, so deletionProtection stays off. Fix the data, then set ${ALIAS}.deletionProtection=true."
    return 0
  fi
  vy_protect_on "$VALUES" "$ALIAS" || die "edit failed"
  [ "$(vy_read "$VALUES" "$ALIAS" deletionProtection)" = "true" ] \
    && ok "set ${ALIAS}.deletionProtection=true in ${VALUES#"${REPO_ROOT}"/}. It was false. Never leave an instance unprotected." \
    || die "check after edit failed: ${ALIAS}.deletionProtection is not true"
  git -C "$REPO_ROOT" --no-pager diff --stat -- "$VALUES" | sed 's/^/    /'
  cat << NEXT

Last step, commit and push:

    git add ${VALUES#"${REPO_ROOT}"/}
    git commit -m "${INSTANCE}: restore done, re-protect"
    git push

This change restarts the pod for about 20s. The operator copies the CR annotations onto the pod template,
so the sync-options annotation changes the pod. The data survives in the AOF. See docs/09_redis.md.
NEXT
}

# ---- main ----

parse_args "$@"
require kubectl aws yq
use_kubeconfig
assert_api

use_deploy_creds
read_backup_values
prompt_for_instance
resolve_git_state

wait_for_target_cr
wait_for_target_pod
read_seed_image

list_dumps
resolve_dump
guard_empty_dump
resolve_target_container
confirm_restore

trap cleanup EXIT
apply_breakglass_netpols
start_seed_pod
resync_from_seed
promote_and_verify
sample_fidelity

reprotect

summary
[ "$FAIL" -eq 0 ]
