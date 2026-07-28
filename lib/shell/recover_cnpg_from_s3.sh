#!/usr/bin/env bash
#
# recover_cnpg_from_s3.sh  (macOS)
#
# THE CNPG recovery runbook, executable. Restores a Postgres database from the off-cluster S3 backups
# (continuous WAL + daily base, written by the Barman Cloud plugin). Two modes, one entry point:
#
#   in-place  the DB is GONE and you want it back AS ITSELF: same name, same -rw Service, still GitOps-managed.
#             Drives the pg-cluster `restore` knob, so it spans your git commits and is RESUMABLE: run it,
#             commit+push what it edited, run it again. It prints the phase it is in every time.
#   side      the DB is FINE (or you only want to look): bootstraps a SEPARATE, unmanaged single-instance
#             cluster from the same catalog to verify a backup, read old rows, or test a PITR target.
#
# A Cluster merely removed from git is NOT deleted (orphan-not-delete): restore its files and Argo re-adopts the
# running DB, no recovery needed. Use this script when the data is actually gone: disk/node loss, corruption, a
# rewind, a deliberate two-commit delete, or a full rebuild. See docs/13_backups.md.
#
# Follows the repo rule that a script never runs git: it edits values.yaml and prints the commit for you.
#
# Usage (flags optional, prompts for anything missing):
#   bash recover_cnpg_from_s3.sh [--mode in-place|side] [--namespace NS] [--source CLUSTER]
#                                [--target latest|"YYYY-MM-DD HH:MM:SS+ZZ"] [--name RECOVERY_NAME] [--yes]
#   make restore-cnpg
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
STORAGE_CLASS="local-path"        # side mode: same node-local class the pg-cluster wrapper uses
STORAGE_SIZE="45Gi"               # side mode: matches the wrapper (a no-op under local-path; it statfs's the partition)
PLUGIN="barman-cloud.cloudnative-pg.io"
SYNC_WAIT=600                     # in-place: seconds to wait for Argo to sync the pushed commit
READY_WAIT=1200                   # in-place: seconds to wait for the recovered cluster to reach full readiness
POLL=10

MODE=""; NS=""; SOURCE=""; RECOVERY_NAME=""; TARGET="latest"; ASSUME_YES="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)      MODE="$2"; shift 2 ;;
    --namespace) NS="$2"; shift 2 ;;
    --source)    SOURCE="$2"; shift 2 ;;
    --name)      RECOVERY_NAME="$2"; shift 2 ;;
    --target)    TARGET="$2"; shift 2 ;;
    --yes|--apply) ASSUME_YES="true"; shift ;;
    *) die "unknown arg: $1 (see the usage header)" ;;
  esac
done

require kubectl yq
use_kubeconfig
assert_api

# ---- values.yaml editing (CNPG-specific; the shared pieces live in common.sh) ----------------
# vy_read / vy_protect_on / wl_find_alias / confirm are in common.sh, along with the reasoning for the
# line-surgical awk (yq -i reformats the whole hand-written document). The two below stay here because they
# are specific to the pg-cluster `restore` knob and its marker comment; redis-instance has no equivalent.

# vy_restore_on <file> <alias> [targetTime]: append a `restore:` block at the end of the alias block.
# Buffers the block so the insert goes after its last INDENTED line, not after the column-0 comment block that
# introduces the NEXT alias (which is where a naive append lands, reading as if it belonged to that one).
vy_restore_on() {
  local f="$1" alias="$2" tt="${3:-}" tmp; tmp="$(mktemp)"
  awk -v alias="$alias" -v tt="$tt" '
    function emit() {
      print "  # TRANSIENT (DR restore): rebuild from S3 instead of initdb. Removed again once verified."
      print "  restore:"
      print "    enabled: true"
      if (tt != "") printf "    targetTime: \"%s\"\n", tt
    }
    function flush() {
      last = 0
      for (i = 1; i <= n; i++) if (buf[i] ~ /^[[:space:]]/) last = i
      for (i = 1; i <= last; i++) print buf[i]
      emit()
      for (i = last + 1; i <= n; i++) print buf[i]
      n = 0
    }
    $0 ~ "^"alias":" { print; inb=1; next }
    inb && /^[^[:space:]#]/ { flush(); inb=0 }
    inb { buf[++n] = $0; next }
    { print }
    END { if (inb) flush() }
  ' "$f" > "$tmp" && mv "$tmp" "$f"
}

# vy_restore_off <file> <alias>: drop the `restore:` block plus the comment line above it
vy_restore_off() {
  local f="$1" alias="$2" tmp; tmp="$(mktemp)"
  awk -v alias="$alias" '
    $0 ~ "^"alias":" { inb=1; print; next }
    inb && /^[^[:space:]#]/ { inb=0 }
    inb && /^  # TRANSIENT \(DR restore\)/ { next }
    inb && /^  restore:/ { skip=1; next }
    skip { if (/^    /) next; skip=0 }
    { print }
  ' "$f" > "$tmp" && mv "$tmp" "$f"
}


# === 1. pick a mode ==========================================================
if [ -z "$MODE" ]; then
  say "CNPG recovery from S3"
  cat <<'MODES'
  in-place   the DB is GONE; bring it back as itself, under its own name, GitOps-managed.
             Edits the workload's values.yaml; you commit+push; re-run to continue. Resumable.
  side       the DB is fine, or you just want to look: build a separate throwaway cluster
             from the same catalog to verify a backup / read old data / test a PITR target.
MODES
  read -rp "Mode [in-place/side]: " MODE
fi
case "$MODE" in in-place|side) ;; *) die "mode must be 'in-place' or 'side'" ;; esac

# === 2. shared discovery + preflight ========================================
kubectl get crd objectstores.barmancloud.cnpg.io >/dev/null 2>&1 \
  || die "ObjectStore CRD missing: is the barman plugin (platform app 03_barman_cloud_plugin) synced?"

say "Backed-up databases the cluster knows about (an ObjectStore == a catalog):"
kubectl get objectstores.barmancloud.cnpg.io -A \
  -o custom-columns='NAMESPACE:.metadata.namespace,OBJECTSTORE:.metadata.name,DESTINATION:.spec.configuration.destinationPath,RECOVERY WINDOW:.status.serverRecoveryWindow' \
  2>/dev/null || warn "could not list ObjectStores"
echo
warn "In a real DR the ObjectStore may be gone too; the catalog in S3 is what matters, not this list."
echo

[ -n "$NS" ]     || read -rp "Namespace: " NS
[ -n "$SOURCE" ] || read -rp "Database (CNPG cluster) name: " SOURCE
{ [ -n "$NS" ] && [ -n "$SOURCE" ]; } || die "namespace and database name are both required"
OBJECTSTORE="${SOURCE}-backups"   # the chart always names it <cluster>-backups

# A restore needs a COMPLETED BASE BACKUP; WAL alone has no recovery point and the recovery job hangs. Prefer
# the ObjectStore's own status, fall back to listing S3 (the store is often gone in a real DR).
RECOVERABLE="unknown"
if kubectl -n "$NS" get objectstore.barmancloud.cnpg.io "$OBJECTSTORE" >/dev/null 2>&1; then
  FRP="$(kubectl -n "$NS" get objectstore.barmancloud.cnpg.io "$OBJECTSTORE" \
         -o jsonpath="{.status.serverRecoveryWindow.${SOURCE}.firstRecoverabilityPoint}" 2>/dev/null)"
  DEST="$(kubectl -n "$NS" get objectstore.barmancloud.cnpg.io "$OBJECTSTORE" \
          -o jsonpath='{.spec.configuration.destinationPath}' 2>/dev/null)"
  SEC="$(kubectl -n "$NS" get objectstore.barmancloud.cnpg.io "$OBJECTSTORE" \
         -o jsonpath='{.spec.configuration.s3Credentials.accessKeyId.name}' 2>/dev/null)"
  [ -n "$SEC" ] && { kubectl -n "$NS" get secret "$SEC" >/dev/null 2>&1 \
    && ok "S3 creds secret ${SEC} present" \
    || bad "S3 creds secret ${NS}/${SEC} missing: restore the sealed-secrets key (make restore-secrets-key) or re-run 14_cnpg_backup.sh"; }
  if [ -n "$FRP" ]; then RECOVERABLE="yes"; ok "recovery point in the catalog: ${FRP}"
  else RECOVERABLE="no";  bad "ObjectStore reports NO recovery point (no completed base backup) for ${SOURCE}"; fi
else
  warn "ObjectStore ${NS}/${OBJECTSTORE} is absent (expected in a real DR); it is re-created from git on an in-place restore."
  DEST=""
fi

# Independent check straight against S3, using the .env deployer creds. Also the only check that catches a
# destinationPath change having orphaned the old catalog.
if [ -n "${AWS_DEPLOY_ACCESS_KEY_ID:-}" ] && command -v aws >/dev/null 2>&1; then
  PREFIX="${DEST:-s3://${S3_BACKUP_BUCKET}/cnpg/${NS}/}"
  PREFIX="${PREFIX%/}/${SOURCE}/base/"
  say "Base backups in the catalog (${PREFIX})"
  if AWS_ACCESS_KEY_ID="$AWS_DEPLOY_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AWS_DEPLOY_SECRET_ACCESS_KEY_SECRET" \
     AWS_REGION="${AWS_REGION}" aws s3 ls "$PREFIX" 2>/dev/null | grep -q .; then
    AWS_ACCESS_KEY_ID="$AWS_DEPLOY_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AWS_DEPLOY_SECRET_ACCESS_KEY_SECRET" \
      AWS_REGION="${AWS_REGION}" aws s3 ls "$PREFIX" | sed 's/^/    /'
    ok "at least one base backup is in S3"
    RECOVERABLE="yes"
  else
    bad "NO base backup under ${PREFIX}"
    warn "if the DB used to be backed up, the catalog may be at an OLD prefix (a destinationPath change orphans it):"
    warn "  aws s3 ls s3://${S3_BACKUP_BUCKET}/cnpg/ --recursive | grep base/"
    RECOVERABLE="no"
  fi
else
  warn "skipping the direct S3 check (no aws cli, or AWS_DEPLOY_ACCESS_KEY_ID unset in .env)"
fi

if [ "$RECOVERABLE" = "no" ]; then
  warn "Without a base backup there is nothing to restore to. Fix that FIRST (a Backup CR, method: plugin),"
  warn "or point at the catalog that does have one."
  confirm "Continue anyway?" || { summary; exit 1; }
fi

# === 3a. mode: side cluster ==================================================
if [ "$MODE" = "side" ]; then
  [ -z "$RECOVERY_NAME" ] && RECOVERY_NAME="${SOURCE}-restore"
  kubectl -n "$NS" get cluster.postgresql.cnpg.io "$RECOVERY_NAME" >/dev/null 2>&1 \
    && die "Cluster ${NS}/${RECOVERY_NAME} already exists: pick another --name (this never overwrites a live cluster)"
  kubectl -n "$NS" get objectstore.barmancloud.cnpg.io "$OBJECTSTORE" >/dev/null 2>&1 \
    || die "side mode reads the live ObjectStore ${NS}/${OBJECTSTORE}, which is absent; use --mode in-place, or restore the workload's files first"

  [ "$TARGET" = "latest" ] || RT=$(printf '\n      recoveryTarget:\n        targetTime: "%s"' "$TARGET")
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
      source: ${SOURCE}${RT:-}
  externalClusters:
    - name: ${SOURCE}
      plugin:
        name: ${PLUGIN}
        parameters:
          barmanObjectName: ${OBJECTSTORE}
          serverName: ${SOURCE}
YAML
)
  say "Plan: read catalog ${OBJECTSTORE} (serverName ${SOURCE}), target ${TARGET}, into NEW cluster ${RECOVERY_NAME} (1 instance, no re-archiving)"
  echo "----- manifest -----"; echo "$MANIFEST"; echo "--------------------"
  confirm "Apply it?" || { warn "not applied"; exit 0; }
  echo "$MANIFEST" | kubectl apply -f - || die "apply failed"
  ok "side cluster ${NS}/${RECOVERY_NAME} created"
  cat <<INSTRUCTIONS

Watch it pull the base backup and replay WAL:
    kubectl -n ${NS} get pods -l cnpg.io/cluster=${RECOVERY_NAME} -w
    kubectl cnpg status ${RECOVERY_NAME} -n ${NS}

Its data is served at ${RECOVERY_NAME}-rw.${NS}. It does NOT archive WAL and is NOT a GitOps object, so
delete it when you are done:
    kubectl -n ${NS} delete cluster.postgresql.cnpg.io ${RECOVERY_NAME}
INSTRUCTIONS
  summary; exit 0
fi

# === 3b. mode: in-place ======================================================
# Find the workload chart + the dependency alias that owns this database, so we can drive its `restore` knob.
# Find the workload chart + the dependency alias that owns this database, so we can drive its `restore` knob.
# postgresVersion is the kind discriminator: it keeps this from ever matching a redis alias, whose chart has no
# restore knob and would silently swallow the block.
FOUND="$(wl_find_alias "$SOURCE" postgresVersion || true)"
VALUES=""; ALIAS=""; IFS=$'\t' read -r VALUES ALIAS <<< "$FOUND" || true   # tab-separated, split explicitly
[ -n "$FOUND" ] || die "no workload chart under ${WORKLOAD_CHARTS} has a pg-cluster instance named ${SOURCE}. In-place restore drives that chart's values; add the instance back to git first, or use --mode side."
ok "owning chart: ${VALUES#${REPO_ROOT}/} (alias '${ALIAS}')"

GIT_RESTORE="$(yq -r ".${ALIAS}.restore.enabled // false" "$VALUES")"
GIT_PROTECT="$(yq -r ".${ALIAS}.deletionProtection // false" "$VALUES")"
LIVE_READY="$(kubectl -n "$NS" get cluster.postgresql.cnpg.io "$SOURCE" -o jsonpath='{.status.readyInstances}' 2>/dev/null)"
LIVE_WANT="$(kubectl -n "$NS" get cluster.postgresql.cnpg.io "$SOURCE" -o jsonpath='{.status.instances}' 2>/dev/null)"
LIVE_EXISTS="no"; kubectl -n "$NS" get cluster.postgresql.cnpg.io "$SOURCE" >/dev/null 2>&1 && LIVE_EXISTS="yes"
DIRTY="no"; git -C "$REPO_ROOT" diff --quiet -- "$VALUES" 2>/dev/null || DIRTY="yes"

APP_NAME="$(basename "$(dirname "$VALUES")" | tr '_' '-')"

say "State"
echo "    database          : ${NS}/${SOURCE}"
echo "    live Cluster      : ${LIVE_EXISTS} (ready ${LIVE_READY:-0}/${LIVE_WANT:-?})"
echo "    git restore.enabled: ${GIT_RESTORE}"
echo "    git deletionProtection: ${GIT_PROTECT}"
echo "    uncommitted edits to that values.yaml: ${DIRTY}"

# --- phase A: turn the restore on -------------------------------------------
if [ "$GIT_RESTORE" != "true" ]; then
  if [ "$LIVE_EXISTS" = "yes" ]; then
    warn "Cluster ${NS}/${SOURCE} is still live. An in-place restore only bootstraps a cluster that does NOT exist:"
    warn "CNPG reads spec.bootstrap once, at create time, so turning restore on now would change nothing."
    warn "To rewind a LIVE database you must delete it first (deletionProtection false, then remove it: docs/13_backups.md),"
    warn "or read the old data with --mode side and copy across."
    summary; exit 1
  fi
  say "PHASE 1/3, enable the restore"
  if [ "$TARGET" = "latest" ]; then
    echo "    target: latest (newest base backup, then replay every WAL in the catalog)"
    vy_restore_on "$VALUES" "$ALIAS" || die "edit failed"
  else
    echo "    target: PITR ${TARGET}"
    vy_restore_on "$VALUES" "$ALIAS" "$TARGET" || die "edit failed"
  fi
  [ "$(vy_read "$VALUES" "$ALIAS" restore)" != "" ] || die "post-edit check failed: ${ALIAS}.restore is not set in ${VALUES}"
  ok "set ${ALIAS}.restore.enabled=true in ${VALUES#${REPO_ROOT}/}"
  git -C "$REPO_ROOT" --no-pager diff --stat -- "$VALUES" | sed 's/^/    /'
  cat <<NEXT

Now commit and push, so ArgoCD builds the recovered cluster:

    git add ${VALUES#${REPO_ROOT}/}
    git commit -m "restore ${SOURCE} from S3"
    git push

Then re-run this script (same answers) to watch it and finish up:

    make restore-cnpg

What the next run does: waits for the sync, watches the base-backup pull and WAL replay, clears the recovery
job if it is stuck, verifies the data, rolls the consumers, and turns the restore flag back off.
NEXT
  summary; exit 0
fi

# --- phase B: wait for the recovery to land ---------------------------------
if [ "$LIVE_READY" != "$LIVE_WANT" ] || [ -z "$LIVE_READY" ]; then
  say "PHASE 2/3, wait for the restore"
  [ "$DIRTY" = "yes" ] && { warn "${VALUES#${REPO_ROOT}/} has uncommitted changes: ArgoCD syncs the pushed remote, not your working tree."; warn "commit + push first, then re-run."; summary; exit 1; }

  # The recovery job is one-shot: once it has failed, the operator does NOT retry it. Nearly always a stale
  # attempt from before a fix landed, so clear it and let a fresh one run.
  FAILED="$(kubectl -n "$NS" get job -l "cnpg.io/cluster=${SOURCE}" \
            -o jsonpath='{range .items[?(@.status.failed)]}{.metadata.name}{" "}{end}' 2>/dev/null)"
  if [ -n "${FAILED// }" ]; then
    warn "failed recovery job(s): ${FAILED}"
    kubectl -n "$NS" logs -l "cnpg.io/cluster=${SOURCE}" --all-containers --tail=8 2>/dev/null \
      | grep -iE "error|expected empty archive|fail" | tail -5 | sed 's/^/    /'
    if confirm "Delete them so the operator starts a fresh recovery?"; then
      kubectl -n "$NS" delete job -l "cnpg.io/cluster=${SOURCE}" --wait=false >/dev/null 2>&1
      ok "cleared; a new recovery job will be created"
    fi
  fi

  say "watching (up to ${READY_WAIT}s): base-backup pull, WAL replay, promotion, replica join"
  DEADLINE=$(( $(date +%s) + READY_WAIT ))
  while :; do
    R="$(kubectl -n "$NS" get cluster.postgresql.cnpg.io "$SOURCE" -o jsonpath='{.status.readyInstances}' 2>/dev/null)"
    W="$(kubectl -n "$NS" get cluster.postgresql.cnpg.io "$SOURCE" -o jsonpath='{.status.instances}' 2>/dev/null)"
    P="$(kubectl -n "$NS" get cluster.postgresql.cnpg.io "$SOURCE" -o jsonpath='{.status.phase}' 2>/dev/null)"
    printf '    ready=%s/%s  %s\n' "${R:-0}" "${W:-?}" "${P:-<no Cluster yet>}"
    [ -n "$R" ] && [ "$R" = "$W" ] && { ok "cluster ${SOURCE} is fully ready (${R}/${W})"; break; }
    case "$P" in *unrecoverable*) warn "operator reports the cluster unrecoverable; check the recovery job logs:";
      warn "  kubectl -n ${NS} logs -l cnpg.io/cluster=${SOURCE} --all-containers --tail=40" ;; esac
    [ "$(date +%s)" -ge "$DEADLINE" ] && { bad "not ready within ${READY_WAIT}s"; warn "re-run to keep waiting, or inspect: kubectl cnpg status ${SOURCE} -n ${NS}"; summary; exit 1; }
    sleep "$POLL"
  done
fi

# --- phase C: verify, roll consumers, turn the flag back off ----------------
say "PHASE 3/3, verify and finish"
PRIMARY="$(kubectl -n "$NS" get pods -l "cnpg.io/cluster=${SOURCE},cnpg.io/instanceRole=primary" \
           -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[ -n "$PRIMARY" ] || PRIMARY="$(kubectl -n "$NS" get cluster.postgresql.cnpg.io "$SOURCE" -o jsonpath='{.status.currentPrimary}' 2>/dev/null)"

kubectl cnpg status "$SOURCE" -n "$NS" 2>/dev/null | sed -n '1,20p' | sed 's/^/    /' \
  || warn "kubectl cnpg plugin not installed; skipping the status block"

# Restored content, per table. The script cannot know your schema, so it reports every table with its live
# row count: that is the evidence that the base backup AND the WAL replay landed.
if [ -n "$PRIMARY" ]; then
  say "Restored tables in database 'app' (row counts are live COUNT(*))"
  kubectl -n "$NS" exec "$PRIMARY" -c postgres -- psql -U postgres -d app -Atc "
    SELECT table_schema||'.'||table_name||' = '||
           (xpath('/row/c/text()', query_to_xml('SELECT count(*) AS c FROM '||quote_ident(table_schema)||'.'||quote_ident(table_name), false, true, '')))[1]::text||' rows'
    FROM information_schema.tables WHERE table_type='BASE TABLE' AND table_schema NOT IN ('pg_catalog','information_schema')
    ORDER BY 1;" 2>/dev/null | sed 's/^/    /' || warn "could not list tables"
  TL="$(kubectl -n "$NS" exec "$PRIMARY" -c postgres -- psql -U postgres -Atc "SELECT timeline_id FROM pg_control_checkpoint()" 2>/dev/null)"
  [ -n "$TL" ] && ok "recovered onto timeline ${TL} (a restore always advances it)"
fi

FRP="$(kubectl -n "$NS" get objectstore.barmancloud.cnpg.io "$OBJECTSTORE" \
       -o jsonpath="{.status.serverRecoveryWindow.${SOURCE}.firstRecoverabilityPoint}" 2>/dev/null)"
[ -n "$FRP" ] && ok "the restored cluster is itself backed up again (recovery point ${FRP})" \
              || warn "no recovery point yet on the new timeline; a base backup runs on the ScheduledBackup's next tick (force one with a Backup CR if you want it now)"

# Deleting the Cluster took its <cluster>-app Secret with it, so the operator minted a new password. Pods read
# a secretKeyRef only at start, so every consumer of that Secret needs a restart.
say "Consumers of the regenerated ${SOURCE}-app Secret"
CONSUMERS="$(kubectl -n "$NS" get deploy,statefulset -o json 2>/dev/null \
  | yq -r --input-format=json '.items[] | select([.. | select(tag == "!!map") | select(.secretKeyRef != null) | .secretKeyRef.name] | contains(["'"${SOURCE}"'-app"])) | (.kind|downcase)+"/"+.metadata.name' 2>/dev/null | sort -u)"
if [ -n "${CONSUMERS// }" ]; then
  echo "$CONSUMERS" | sed 's/^/    /'
  if confirm "Roll them so they pick up the new password?"; then
    while read -r c; do [ -z "$c" ] && continue
      kubectl -n "$NS" rollout restart "$c" >/dev/null 2>&1 && ok "rolled ${c}" || bad "could not roll ${c}"
    done <<< "$CONSUMERS"
  fi
else
  warn "none found referencing ${SOURCE}-app; if something connects with those creds, restart it by hand"
fi

# Turn the knob back off: leaving it on would make any future re-create silently restore instead of initdb.
say "Final edit: turn the restore flag off"
vy_restore_off "$VALUES" "$ALIAS" || die "edit failed"
[ "$(vy_read "$VALUES" "$ALIAS" restore)" = "" ] || die "post-edit check failed: ${ALIAS}.restore still set in ${VALUES}"
ok "removed ${ALIAS}.restore from ${VALUES#${REPO_ROOT}/}"
if [ "$GIT_PROTECT" != "true" ]; then
  vy_protect_on "$VALUES" "$ALIAS" || die "edit failed"
  [ "$(vy_read "$VALUES" "$ALIAS" deletionProtection)" = "true" ] \
    && ok "set ${ALIAS}.deletionProtection=true (it was false; never leave a DB unprotected)" \
    || die "post-edit check failed: ${ALIAS}.deletionProtection is not true"
fi
git -C "$REPO_ROOT" --no-pager diff --stat -- "$VALUES" | sed 's/^/    /'
cat <<NEXT

Last step, commit and push:

    git add ${VALUES#${REPO_ROOT}/}
    git commit -m "${SOURCE}: restore done, re-protect"
    git push

Both flips are inert on the running DB: CNPG reads spec.bootstrap only when it builds a cluster, so nothing
restarts. Confirm afterwards:

    kubectl -n argocd get app ${APP_NAME}
    kubectl -n ${NS} get cluster ${SOURCE} -o jsonpath='{.metadata.annotations}'
NEXT
summary
