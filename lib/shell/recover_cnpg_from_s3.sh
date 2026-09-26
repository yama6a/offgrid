#!/usr/bin/env bash
# Restores a CNPG Postgres database from the S3 backups. It edits values.yaml and prints the git commands.
# A Cluster removed from git keeps running. Put its files back and Argo CD adopts it again, no restore needed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat << EOF
recover_cnpg_from_s3.sh [--mode in-place|side] [--namespace <ns>] [--source <cluster>]
                        [--target latest|"YYYY-MM-DD HH:MM:SS+ZZ"] [--name <recovery-name>]
                        [--server <serverName>] [--yes]
                                                                          (or: make restore-cnpg)
  Every flag is optional. The script prompts for anything missing.

  --server  the S3 catalog to read. The default is <cluster>-pg<major>, as the chart writes it.
            To go back to before a major upgrade, name the previous major, for example mydb-pg17.
            For a catalog written before the prefix carried the major, name the bare <cluster>.

Two modes:
  in-place  The DB is gone or broken, and you want it back under its own name and -rw Service, still
            managed by GitOps. It sets the pg-cluster restore and deletionProtection knobs, so it runs
            across your git commits. First run: it edits values.yaml, and you commit and push.
            Second run: it deletes the old Cluster and watches the rebuild. It prints its phase each time.
  side      The DB is fine, or you only want to look. It creates a separate single-instance cluster
            from the same catalog, outside GitOps. Use it to check a backup, read old rows, or test a
            PITR target.
EOF
}

# ---- knobs ----
STORAGE_CLASS="longhorn-r2-ephemeral" # side mode: the same class that the pg-cluster chart uses
STORAGE_SIZE="10Gi"                   # side mode: size limit of the clone. Thin, so it uses only what it writes.
PLUGIN="barman-cloud.cloudnative-pg.io"
SYNC_WAIT=600   # in-place: seconds to wait for Argo CD to sync the pushed commit
READY_WAIT=1200 # in-place: seconds to wait until all instances of the restored cluster are ready
POLL=10

# ---- state ----
MODE="" # set by parse_args or prompt_for_mode
NS=""
SOURCE=""
RECOVERY_NAME=""
TARGET="latest"
ASSUME_YES="false"
OBJECTSTORE="" # set by prompt_for_database
SERVER=""      # barman catalog prefix, from --server or resolve_server
IMAGE=""       # side mode: Postgres image for the major of the catalog
DEST=""        # set by check_objectstore
RECOVERABLE="unknown"
FOUND="" # set by resolve_owning_chart
VALUES=""
ALIAS=""
APP_NAME=""
GIT_RESTORE="" # set by resolve_state
GIT_PROTECT=""
LIVE_EXISTS="no"
LIVE_READY=""
LIVE_WANT=""
LIVE_CREATED=""
ENABLED_AT=""
RECOVERED="no"
DIRTY="no"
PRIMARY="" # set by verify_restored_data

# ---- functions ----

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode)
        MODE="$2"
        shift 2
        ;;
      --namespace)
        NS="$2"
        shift 2
        ;;
      --source)
        SOURCE="$2"
        shift 2
        ;;
      --name)
        RECOVERY_NAME="$2"
        shift 2
        ;;
      --target)
        TARGET="$2"
        shift 2
        ;;
      --server)
        SERVER="$2"
        shift 2
        ;;
      --yes | --apply)
        ASSUME_YES="true"
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

# vy_restore_on <file> <alias> [targetTime]: append a `restore:` block after the last indented line of <alias>.
# A plain append would land below the comment block of the next alias.
vy_restore_on() {
  local f="$1" alias="$2" tt="${3:-}" tmp
  tmp="$(mktemp)"
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
  ' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
}

# vy_restore_off <file> <alias>: remove the `restore:` block and its marker comment.
vy_restore_off() {
  local f="$1" alias="$2" tmp
  tmp="$(mktemp)"
  awk -v alias="$alias" '
    $0 ~ "^"alias":" { inb=1; print; next }
    inb && /^[^[:space:]#]/ { inb=0 }
    inb && /^  # TRANSIENT \(DR restore\)/ { next }
    inb && /^  restore:/ { skip=1; next }
    skip { if (/^    /) next; skip=0 }
    { print }
  ' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
}

prompt_for_mode() {
  if [ -z "$MODE" ]; then
    say "CNPG recovery from S3"
    cat << 'MODES'
  in-place   The DB is gone or broken. Bring it back under its own name, managed by GitOps.
             It edits the workload values.yaml. You commit and push, then run it again to continue.
  side       The DB is fine, or you only want to look. Build a separate throwaway cluster from the
             same catalog to check a backup, read old data, or test a PITR target.
MODES
    read -rp "Mode [in-place/side]: " MODE
  fi
  case "$MODE" in in-place | side) ;; *) die "mode must be 'in-place' or 'side'" ;; esac
}

list_catalogs() {
  kubectl get crd objectstores.barmancloud.cnpg.io > /dev/null 2>&1 \
    || die "ObjectStore CRD missing. Is the platform app 03_barman_cloud_plugin synced?"
  say "Backed-up databases in the cluster. Each ObjectStore is one catalog:"
  kubectl get objectstores.barmancloud.cnpg.io -A \
    -o custom-columns='NAMESPACE:.metadata.namespace,OBJECTSTORE:.metadata.name,DESTINATION:.spec.configuration.destinationPath,RECOVERY WINDOW:.status.serverRecoveryWindow' \
    2> /dev/null || warn "could not list ObjectStores"
  echo
  warn "In a real disaster the ObjectStore may be gone too. The catalog in S3 counts, not this list."
  echo
}

prompt_for_database() {
  [ -n "$NS" ] || read -rp "Namespace: " NS
  [ -n "$SOURCE" ] || read -rp "Database (CNPG cluster) name: " SOURCE
  { [ -n "$NS" ] && [ -n "$SOURCE" ]; } || die "namespace and database name are both required"
  OBJECTSTORE="${SOURCE}-backups" # the chart always names it <cluster>-backups
}

# The catalog prefix is <cluster>-pg<major>. After a major upgrade you usually want the previous major.
resolve_server() {
  local values="" alias="" v=""
  [ -n "$SERVER" ] && {
    ok "catalog serverName: ${SERVER} (--server)"
    return 0
  }
  SERVER="$(kubectl -n "$NS" get cluster.postgresql.cnpg.io "$SOURCE" \
    -o jsonpath="{.spec.plugins[?(@.name=='${PLUGIN}')].parameters.serverName}" 2> /dev/null)"
  [ -n "$SERVER" ] && {
    ok "catalog serverName: ${SERVER} (from the live Cluster)"
    return 0
  }
  IFS=$'\t' read -r values alias <<< "$(wl_find_alias "$SOURCE" postgresVersion || true)"
  if [ -n "$values" ]; then
    v="$(ALIAS="$alias" yq -r '.[strenv(ALIAS)].postgresVersion // ""' "$values" 2> /dev/null)"
    [ -n "$v" ] && {
      SERVER="${SOURCE}-pg${v}"
      ok "catalog serverName: ${SERVER} (from ${values#"${REPO_ROOT}"/})"
      return 0
    }
  fi
  SERVER="$SOURCE"
  warn "no live Cluster and no chart values for ${SOURCE}. Using the bare prefix ${SERVER}."
  warn "if that is wrong, pass --server. List what is in S3 with:"
  warn "  aws s3 ls s3://${S3_BACKUP_BUCKET:-<bucket>}/cnpg/${NS}/"
}

# A restore needs a completed base backup. WAL alone has no recovery point, and the recovery job hangs.
check_objectstore() {
  local frp sec
  if ! kubectl -n "$NS" get objectstore.barmancloud.cnpg.io "$OBJECTSTORE" > /dev/null 2>&1; then
    warn "ObjectStore ${NS}/${OBJECTSTORE} is absent, as expected in a real disaster. An in-place restore creates it again from git."
    DEST=""
    return 0
  fi
  frp="$(kubectl -n "$NS" get objectstore.barmancloud.cnpg.io "$OBJECTSTORE" \
    -o jsonpath="{.status.serverRecoveryWindow.${SERVER}.firstRecoverabilityPoint}" 2> /dev/null)"
  DEST="$(kubectl -n "$NS" get objectstore.barmancloud.cnpg.io "$OBJECTSTORE" \
    -o jsonpath='{.spec.configuration.destinationPath}' 2> /dev/null)"
  sec="$(kubectl -n "$NS" get objectstore.barmancloud.cnpg.io "$OBJECTSTORE" \
    -o jsonpath='{.spec.configuration.s3Credentials.accessKeyId.name}' 2> /dev/null)"
  [ -n "$sec" ] && { kubectl -n "$NS" get secret "$sec" > /dev/null 2>&1 \
    && ok "S3 creds secret ${sec} present" \
    || bad "S3 creds secret ${NS}/${sec} missing. Restore the sealed-secrets key with make restore-secrets-key, or run 10b_cnpg_backup.sh again."; }
  if [ -n "$frp" ]; then
    RECOVERABLE="yes"
    ok "recovery point in the catalog: ${frp}"
  else
    RECOVERABLE="no"
    bad "ObjectStore reports no recovery point for ${SERVER}. No base backup has completed."
  fi
}

# Checks S3 directly with the deploy creds from .env. Only this check catches a catalog that a
# destinationPath change left behind.
check_s3_catalog() {
  local prefix
  if [ -z "${AWS_DEPLOY_ACCESS_KEY_ID:-}" ] || ! command -v aws > /dev/null 2>&1; then
    warn "skipping the direct S3 check: no aws CLI, or AWS_DEPLOY_ACCESS_KEY_ID unset in .env"
    return 0
  fi
  prefix="${DEST:-s3://${S3_BACKUP_BUCKET}/cnpg/${NS}/}"
  prefix="${prefix%/}/${SERVER}/base/"
  say "Base backups in the catalog at ${prefix}"
  export_deploy_aws_creds
  if aws s3 ls "$prefix" 2> /dev/null | grep -q .; then
    aws s3 ls "$prefix" | sed 's/^/    /'
    ok "at least one base backup is in S3"
    RECOVERABLE="yes"
  else
    bad "no base backup under ${prefix}"
    warn "if the DB had backups, the catalog may be at an old prefix. A major upgrade changes the prefix,"
    warn "for example -pg17 to -pg18. A destinationPath change leaves it behind. List it, then pass --server:"
    warn "  aws s3 ls s3://${S3_BACKUP_BUCKET}/cnpg/${NS}/"
    RECOVERABLE="no"
  fi
}

gate_on_recoverability() {
  [ "$RECOVERABLE" = "no" ] || return 0
  warn "Without a base backup there is nothing to restore to. Fix that first with a Backup CR, method: plugin."
  warn "Or point at a catalog that has one."
  confirm "Continue anyway?" || {
    summary
    exit 1
  }
}

# Postgres cannot replay a catalog from a different major. An unset imageName follows the operator default,
# which changes with each operator release. So the major in the prefix wins, then the image of the live cluster.
resolve_operand_image() {
  local major="" images="${REPO_ROOT}/lib/helm/pg-cluster/files/postgres-images.yaml"
  case "$SERVER" in *-pg[0-9]*) major="${SERVER##*-pg}" ;; esac
  if [ -n "$major" ] && [ -f "$images" ]; then
    IMAGE="$(MAJOR="$major" yq -r '.[strenv(MAJOR)] // ""' "$images" 2> /dev/null)"
  fi
  [ -n "$IMAGE" ] || IMAGE="$(kubectl -n "$NS" get cluster.postgresql.cnpg.io "$SOURCE" \
    -o jsonpath='{.spec.imageName}' 2> /dev/null)"
  if [ -n "$IMAGE" ]; then
    ok "operand image: ${IMAGE}"
  else warn "could not find an image for this catalog. The clone gets the operator default, and the restore fails if its major differs."; fi
}

run_side_restore() {
  local rt="" img="" manifest
  [ -z "$RECOVERY_NAME" ] && RECOVERY_NAME="${SOURCE}-restore"
  kubectl -n "$NS" get cluster.postgresql.cnpg.io "$RECOVERY_NAME" > /dev/null 2>&1 \
    && die "Cluster ${NS}/${RECOVERY_NAME} already exists. Pick another --name. This script never overwrites a live cluster."
  kubectl -n "$NS" get objectstore.barmancloud.cnpg.io "$OBJECTSTORE" > /dev/null 2>&1 \
    || die "side mode reads the live ObjectStore ${NS}/${OBJECTSTORE}, which is absent. Use --mode in-place, or restore the workload files first."

  [ "$TARGET" = "latest" ] || rt="$(printf '\n      recoveryTarget:\n        targetTime: "%s"' "$TARGET")"
  resolve_operand_image
  [ -z "$IMAGE" ] || img="$(printf '\n  imageName: %s' "$IMAGE")"
  manifest="$(
    cat << YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${RECOVERY_NAME}
  namespace: ${NS}
spec:
  instances: 1${img}
  storage:
    storageClass: ${STORAGE_CLASS}
    size: ${STORAGE_SIZE}
  affinity:
    topologyKey: kubernetes.io/hostname
  bootstrap:
    recovery:
      source: ${SOURCE}${rt}
  externalClusters:
    - name: ${SOURCE}
      plugin:
        name: ${PLUGIN}
        parameters:
          barmanObjectName: ${OBJECTSTORE}
          serverName: ${SERVER}
YAML
  )"
  say "Plan: restore catalog ${OBJECTSTORE}, serverName ${SERVER}, target ${TARGET}, into the new cluster ${RECOVERY_NAME}. 1 instance, no WAL archiving."
  echo "----- manifest -----"
  echo "$manifest"
  echo "--------------------"
  confirm "Apply it?" || {
    warn "not applied"
    exit 0
  }
  echo "$manifest" | kubectl apply -f - || die "apply failed"
  ok "side cluster ${NS}/${RECOVERY_NAME} created"
  cat << INSTRUCTIONS

Watch it pull the base backup and replay WAL:
    kubectl -n ${NS} get pods -l cnpg.io/cluster=${RECOVERY_NAME} -w
    kubectl cnpg status ${RECOVERY_NAME} -n ${NS}

Its data is served at ${RECOVERY_NAME}-rw.${NS}. It does not archive WAL, and GitOps does not manage it.
Delete it when you are done:
    kubectl -n ${NS} delete cluster.postgresql.cnpg.io ${RECOVERY_NAME}
INSTRUCTIONS
  summary
  exit 0
}

resolve_owning_chart() {
  FOUND="$(wl_find_alias "$SOURCE" postgresVersion || true)"
  IFS=$'\t' read -r VALUES ALIAS <<< "$FOUND" || true
  [ -n "$FOUND" ] || die "no workload chart under ${WORKLOAD_CHARTS} has a pg-cluster instance named ${SOURCE}. An in-place restore edits that chart's values. Add the instance back to git first, or use --mode side."
  ok "owning chart: ${VALUES#"${REPO_ROOT}"/}, alias '${ALIAS}'"
  APP_NAME="$(basename "$(dirname "$VALUES")" | tr '_' '-')"
}

# RECOVERED=yes means the restore already rebuilt the Cluster. The `-full-recovery-` job marks a running restore,
# and a Cluster newer than the restore commit marks a finished one. The commit time is formatted in UTC, because
# plain `format:` uses the commit's own zone and makes a fresh Cluster look older than the commit.
resolve_state() {
  GIT_RESTORE="$(yq -r ".${ALIAS}.restore.enabled // false" "$VALUES")"
  GIT_PROTECT="$(yq -r ".${ALIAS}.deletionProtection // false" "$VALUES")"
  LIVE_READY="$(kubectl -n "$NS" get cluster.postgresql.cnpg.io "$SOURCE" -o jsonpath='{.status.readyInstances}' 2> /dev/null)"
  LIVE_WANT="$(kubectl -n "$NS" get cluster.postgresql.cnpg.io "$SOURCE" -o jsonpath='{.status.instances}' 2> /dev/null)"
  kubectl -n "$NS" get cluster.postgresql.cnpg.io "$SOURCE" > /dev/null 2>&1 && LIVE_EXISTS="yes"
  git -C "$REPO_ROOT" diff --quiet -- "$VALUES" 2> /dev/null || DIRTY="yes"
  LIVE_CREATED="$(kubectl -n "$NS" get cluster.postgresql.cnpg.io "$SOURCE" -o jsonpath='{.metadata.creationTimestamp}' 2> /dev/null)"
  ENABLED_AT="$(TZ=UTC git -C "$REPO_ROOT" log -1 --format=%cd --date=format-local:'%Y-%m-%dT%H:%M:%SZ' -- "$VALUES" 2> /dev/null)"
  kubectl -n "$NS" get job -l "cnpg.io/cluster=${SOURCE}" -o name 2> /dev/null | grep -q -- '-full-recovery' && RECOVERED="yes"
  [ -n "$LIVE_CREATED" ] && [ -n "$ENABLED_AT" ] && [[ "$LIVE_CREATED" > "$ENABLED_AT" ]] && RECOVERED="yes"

  say "State"
  echo "    database          : ${NS}/${SOURCE}"
  echo "    live Cluster      : ${LIVE_EXISTS}, ready ${LIVE_READY:-0}/${LIVE_WANT:-?}"
  echo "    Cluster is post-restore: ${RECOVERED}, created ${LIVE_CREATED:-n/a}, restore enabled ${ENABLED_AT:-n/a}"
  echo "    git restore.enabled: ${GIT_RESTORE}"
  echo "    git deletionProtection: ${GIT_PROTECT}"
  echo "    uncommitted edits to that values.yaml: ${DIRTY}"
  return 0
}

# A healthy live DB gets a prompt. A restore rewinds it and loses every write after the last archived WAL segment.
enable_restore() {
  say "phase 1/3, turn on the restore"
  if [ "$LIVE_EXISTS" = "yes" ] && [ -n "$LIVE_READY" ] && [ "$LIVE_READY" = "$LIVE_WANT" ]; then
    warn "Cluster ${NS}/${SOURCE} is live and serving, ${LIVE_READY}/${LIVE_WANT} ready."
    warn "An in-place restore deletes it and rebuilds it from the catalog. Anything not yet archived is lost."
    warn "To read old rows without touching the running DB, answer no and run again with --mode side."
    confirm "Rewind it to the catalog?" || {
      warn "nothing changed"
      summary
      exit 0
    }
  fi
  if [ "$TARGET" = "latest" ]; then
    echo "    target: latest. Newest base backup, then every WAL segment in the catalog."
    vy_restore_on "$VALUES" "$ALIAS" || die "edit failed"
  else
    echo "    target: PITR ${TARGET}"
    vy_restore_on "$VALUES" "$ALIAS" "$TARGET" || die "edit failed"
  fi
  [ "$(vy_read "$VALUES" "$ALIAS" restore)" != "" ] || die "check after edit failed: ${ALIAS}.restore is not set in ${VALUES}"
  ok "set ${ALIAS}.restore.enabled=true in ${VALUES#"${REPO_ROOT}"/}"
  # The Prune=false,Delete=false annotations do not block the delete in the next run. They should still not
  # claim protection during a deliberate delete.
  if [ "$GIT_PROTECT" = "true" ]; then
    vy_protect_off "$VALUES" "$ALIAS" || die "edit failed"
    # Not vy_read: yq `//` also replaces false, so a correct `false` would read as empty.
    [ "$(ALIAS="$ALIAS" yq -r '.[strenv(ALIAS)].deletionProtection' "$VALUES")" = "false" ] \
      || die "check after edit failed: ${ALIAS}.deletionProtection is not false in ${VALUES}"
    ok "set ${ALIAS}.deletionProtection=false. Phase 3 sets it back."
  fi
  git -C "$REPO_ROOT" --no-pager diff --stat -- "$VALUES" | sed 's/^/    /'
  cat << NEXT

Now commit and push, so Argo CD renders the recovery bootstrap:

    git add ${VALUES#"${REPO_ROOT}"/}
    git commit -m "restore ${SOURCE} from S3"
    git push

Then run this script again with the same answers to finish:

    make restore-cnpg

The next run:
  1. Waits until the sync reaches the live Cluster.
  2. Deletes the Cluster, so Argo CD creates it again with bootstrap.recovery.
  3. Watches the base backup download and the WAL replay. Clears a stuck recovery job.
  4. Checks the data, restarts the consumers, and sets both flags back.
NEXT
  summary
  exit 0
}

# CNPG reads spec.bootstrap only at create time, so the running Cluster must be deleted and created again.
# The chart sets the skipEmptyWalArchiveCheck annotation only when restore is on, so it proves the sync landed.
delete_stale_cluster() {
  local synced was_yes
  [ "$LIVE_EXISTS" = "yes" ] && [ "$RECOVERED" != "yes" ] || return 0
  synced="$(kubectl -n "$NS" get cluster.postgresql.cnpg.io "$SOURCE" \
    -o jsonpath='{.metadata.annotations.cnpg\.io/skipEmptyWalArchiveCheck}' 2> /dev/null)"
  if [ "$synced" != "enabled" ]; then
    bad "the live Cluster has no cnpg.io/skipEmptyWalArchiveCheck annotation, so Argo CD has not synced the restore yet"
    warn "push the phase 1 commit, then watch the sync. It can take up to ${SYNC_WAIT}s: kubectl -n argocd get app ${APP_NAME} -w"
    summary
    exit 1
  fi
  ok "Argo CD has synced the restore onto the live Cluster"
  warn "deleting Cluster ${NS}/${SOURCE}. Its PVCs go with it. The restore reads the S3 catalog, which stays intact."
  # A serving Cluster is either the rewind from phase 1 or a restore this run misjudged. Only about 30s of
  # clock can separate the two, so --yes never deletes a serving database.
  was_yes="$ASSUME_YES"
  if [ -n "$LIVE_READY" ] && [ "$LIVE_READY" = "$LIVE_WANT" ]; then
    warn "it is serving, ${LIVE_READY}/${LIVE_WANT} ready. This needs a typed answer even with --yes."
    ASSUME_YES=false
  fi
  if ! confirm "Delete it so Argo CD creates it again with bootstrap.recovery?"; then
    warn "not deleted, so nothing happens. The running Cluster can never become the restored one."
    summary
    exit 1
  fi
  ASSUME_YES="$was_yes"
  kubectl -n "$NS" delete cluster.postgresql.cnpg.io "$SOURCE" || die "delete failed"
  ok "deleted"
  kubectl -n argocd annotate app "$APP_NAME" argocd.argoproj.io/refresh=hard --overwrite > /dev/null 2>&1 \
    && ok "asked Argo CD to refresh ${APP_NAME} now, not on its next poll" \
    || warn "could not refresh Argo CD. It creates the Cluster again on its next reconciliation."
}

# The operator never retries a failed recovery job. Such a job is nearly always from before a fix, so delete it.
clear_failed_recovery_jobs() {
  local failed
  failed="$(kubectl -n "$NS" get job -l "cnpg.io/cluster=${SOURCE}" \
    -o jsonpath='{range .items[?(@.status.failed)]}{.metadata.name}{" "}{end}' 2> /dev/null)"
  [ -n "${failed// /}" ] || return 0
  warn "failed recovery jobs: ${failed}"
  kubectl -n "$NS" logs -l "cnpg.io/cluster=${SOURCE}" --all-containers --tail=8 2> /dev/null \
    | grep -iE "error|expected empty archive|fail" | tail -5 | sed 's/^/    /'
  if confirm "Delete them so the operator starts a fresh recovery?"; then
    kubectl -n "$NS" delete job -l "cnpg.io/cluster=${SOURCE}" --wait=false > /dev/null 2>&1
    ok "deleted. The operator creates a new recovery job."
  fi
}

wait_for_recovery() {
  local deadline r w p
  say "watching for up to ${READY_WAIT}s: base backup download, WAL replay, promotion, replica join"
  deadline=$(($(date +%s) + READY_WAIT))
  while :; do
    r="$(kubectl -n "$NS" get cluster.postgresql.cnpg.io "$SOURCE" -o jsonpath='{.status.readyInstances}' 2> /dev/null)"
    w="$(kubectl -n "$NS" get cluster.postgresql.cnpg.io "$SOURCE" -o jsonpath='{.status.instances}' 2> /dev/null)"
    p="$(kubectl -n "$NS" get cluster.postgresql.cnpg.io "$SOURCE" -o jsonpath='{.status.phase}' 2> /dev/null)"
    printf '    ready=%s/%s  %s\n' "${r:-0}" "${w:-?}" "${p:-<no Cluster yet>}"
    [ -n "$r" ] && [ "$r" = "$w" ] && {
      ok "cluster ${SOURCE} is fully ready, ${r}/${w}"
      break
    }
    case "$p" in *unrecoverable*)
      warn "the operator reports the cluster unrecoverable. Check the recovery job logs:"
      warn "  kubectl -n ${NS} logs -l cnpg.io/cluster=${SOURCE} --all-containers --tail=40"
      ;;
    esac
    [ "$(date +%s)" -ge "$deadline" ] && {
      bad "not ready after ${READY_WAIT}s"
      warn "run again to keep waiting, or inspect: kubectl cnpg status ${SOURCE} -n ${NS}"
      summary
      exit 1
    }
    sleep "$POLL"
  done
}

run_restore_phase() {
  say "phase 2/3, wait for the restore"
  [ "$DIRTY" = "yes" ] && {
    warn "${VALUES#"${REPO_ROOT}"/} has uncommitted changes. Argo CD syncs the pushed remote, not your working tree."
    warn "commit and push first, then run again."
    summary
    exit 1
  }
  delete_stale_cluster
  clear_failed_recovery_jobs
  wait_for_recovery
}

# Prints every table with its live row count, which shows that the base backup and the WAL replay landed.
verify_restored_data() {
  local tl frp now # now: where the rebuilt cluster archives to. It differs from $SERVER after a restore across majors.
  say "phase 3/3, check and finish"
  PRIMARY="$(kubectl -n "$NS" get pods -l "cnpg.io/cluster=${SOURCE},cnpg.io/instanceRole=primary" \
    -o jsonpath='{.items[0].metadata.name}' 2> /dev/null)"
  [ -n "$PRIMARY" ] || PRIMARY="$(kubectl -n "$NS" get cluster.postgresql.cnpg.io "$SOURCE" -o jsonpath='{.status.currentPrimary}' 2> /dev/null)"

  kubectl cnpg status "$SOURCE" -n "$NS" 2> /dev/null | sed -n '1,20p' | sed 's/^/    /' \
    || warn "kubectl cnpg plugin not installed, skipping the status block"

  if [ -n "$PRIMARY" ]; then
    say "Restored tables in database 'app'. Row counts are live COUNT(*)."
    kubectl -n "$NS" exec "$PRIMARY" -c postgres -- psql -U postgres -d app -Atc "
    SELECT table_schema||'.'||table_name||' = '||
           (xpath('/row/c/text()', query_to_xml('SELECT count(*) AS c FROM '||quote_ident(table_schema)||'.'||quote_ident(table_name), false, true, '')))[1]::text||' rows'
    FROM information_schema.tables WHERE table_type='BASE TABLE' AND table_schema NOT IN ('pg_catalog','information_schema')
    ORDER BY 1;" 2> /dev/null | sed 's/^/    /' || warn "could not list tables"
    tl="$(kubectl -n "$NS" exec "$PRIMARY" -c postgres -- psql -U postgres -Atc "SELECT timeline_id FROM pg_control_checkpoint()" 2> /dev/null)"
    [ -n "$tl" ] && ok "restored onto timeline ${tl}. A restore always advances the timeline."
  fi

  now="$(kubectl -n "$NS" get cluster.postgresql.cnpg.io "$SOURCE" \
    -o jsonpath="{.spec.plugins[?(@.name=='${PLUGIN}')].parameters.serverName}" 2> /dev/null)"
  [ -n "$now" ] || now="$SERVER"
  frp="$(kubectl -n "$NS" get objectstore.barmancloud.cnpg.io "$OBJECTSTORE" \
    -o jsonpath="{.status.serverRecoveryWindow.${now}.firstRecoverabilityPoint}" 2> /dev/null)"
  [ -n "$frp" ] && ok "the restored cluster has backups again: recovery point ${frp} under ${now}" \
    || warn "no recovery point yet on the new timeline. The next ScheduledBackup run takes a base backup. Create a Backup CR to take one now."
  return 0
}

# The delete removed the <cluster>-app Secret, so the operator made a new password. Pods read secretKeyRef
# only at start, so every consumer needs a restart.
roll_secret_consumers() {
  local consumers c
  say "Consumers of the regenerated ${SOURCE}-app Secret"
  consumers="$(kubectl -n "$NS" get deploy,statefulset -o json 2> /dev/null \
    | yq -r --input-format=json '.items[] | select([.. | select(tag == "!!map") | select(.secretKeyRef != null) | .secretKeyRef.name] | contains(["'"${SOURCE}"'-app"])) | (.kind|downcase)+"/"+.metadata.name' 2> /dev/null | sort -u)"
  if [ -z "${consumers// /}" ]; then
    warn "nothing references ${SOURCE}-app. If something connects with those creds, restart it by hand."
    return 0
  fi
  printf '%s\n' "$consumers" | sed 's/^/    /'
  if confirm "Restart them so they pick up the new password?"; then
    while read -r c; do
      [ -z "$c" ] && continue
      kubectl -n "$NS" rollout restart "$c" > /dev/null 2>&1 && ok "restarted ${c}" || bad "could not restart ${c}"
    done <<< "$consumers"
  fi
}

# With the restore knob left on, the next create of this Cluster would restore instead of running initdb.
disable_restore_and_reprotect() {
  say "Last edit: turn the restore flag off"
  vy_restore_off "$VALUES" "$ALIAS" || die "edit failed"
  [ "$(vy_read "$VALUES" "$ALIAS" restore)" = "" ] || die "check after edit failed: ${ALIAS}.restore still set in ${VALUES}"
  ok "removed ${ALIAS}.restore from ${VALUES#"${REPO_ROOT}"/}"
  if [ "$GIT_PROTECT" != "true" ]; then
    vy_protect_on "$VALUES" "$ALIAS" || die "edit failed"
    [ "$(vy_read "$VALUES" "$ALIAS" deletionProtection)" = "true" ] \
      && ok "set ${ALIAS}.deletionProtection=true. It was false. Never leave a DB unprotected." \
      || die "check after edit failed: ${ALIAS}.deletionProtection is not true"
  fi
  git -C "$REPO_ROOT" --no-pager diff --stat -- "$VALUES" | sed 's/^/    /'
  cat << NEXT

Last step, commit and push:

    git add ${VALUES#"${REPO_ROOT}"/}
    git commit -m "${SOURCE}: restore done, re-protect"
    git push

Neither change restarts the running DB. CNPG reads spec.bootstrap only when it creates a cluster.
Confirm afterwards:

    kubectl -n argocd get app ${APP_NAME}
    kubectl -n ${NS} get cluster ${SOURCE} -o jsonpath='{.metadata.annotations}'
NEXT
}

# ---- main ----

parse_args "$@"
require kubectl yq
use_kubeconfig
assert_api

prompt_for_mode
list_catalogs
prompt_for_database
resolve_server
check_objectstore
check_s3_catalog
gate_on_recoverability

[ "$MODE" = "side" ] && run_side_restore

resolve_owning_chart
resolve_state

if [ "$GIT_RESTORE" != "true" ]; then
  enable_restore
fi

if [ "$RECOVERED" != "yes" ] || [ "$LIVE_READY" != "$LIVE_WANT" ] || [ -z "$LIVE_READY" ]; then
  run_restore_phase
fi

verify_restored_data
roll_secret_consumers
disable_restore_and_reprotect
summary
