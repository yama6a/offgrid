#!/usr/bin/env bash
# Backs up the Sealed Secrets controller's RSA private key(s) to the gitignored secrets/ dir.
# LOSE THIS KEY AND EVERY SEALED SECRET IN THIS REPO IS UNRECOVERABLE.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
NS="$SS_CONTROLLER_NS"                                          # controller namespace (Application destination)
KEY_LABEL="$SS_KEY_LABEL"                                       # label the controller stamps on its key Secrets
BACKUP_FILE="${CLUSTER_DIR}/sealed-secrets-master.key"          # gitignored dir

# ---- functions ----

check_prerequisites() {
  say "prerequisites"
  require kubectl
  use_kubeconfig
  assert_api
  ok "kubectl present, API reachable"
}

# The whole labelled set, not just the active key: the controller rotates roughly monthly and KEEPS the old
# ones, which still decrypt older SealedSecrets. Re-run after each rotation.
count_key_secrets() {
  local keys count
  say "looking for key Secrets in ns/${NS} (label ${KEY_LABEL})"
  keys="$(kubectl get secret -n "$NS" -l "$KEY_LABEL" -o name 2>/dev/null)"
  if [ -z "$keys" ]; then
    bad "no Secrets with label ${KEY_LABEL} in ns/${NS}, is the controller running? (kubectl -n ${NS} get pods)"
    summary; exit 1
  fi
  count="$(printf '%s\n' "$keys" | grep -c .)"
  ok "found ${count} key Secret(s)"
}

# `-o yaml` of the labelled Secrets is the official restore-able form (re-applied with kubectl apply).
write_backup() {
  say "writing backup -> ${BACKUP_FILE}"
  mkdir -p "$CLUSTER_DIR"
  if kubectl get secret -n "$NS" -l "$KEY_LABEL" -o yaml > "$BACKUP_FILE" 2>/dev/null; then
    chmod 600 "$BACKUP_FILE"
    ok "key(s) written and chmod 600"
  else
    bad "kubectl get/dump failed, backup NOT written"
  fi
}

verify_backup() {
  say "verifying the backup"
  [ -s "$BACKUP_FILE" ] && ok "backup file is non-empty" || bad "backup file is empty"
  grep -q 'kind: Secret' "$BACKUP_FILE" 2>/dev/null \
    && ok "backup contains Secret manifests" || bad "backup does not contain 'kind: Secret'"
}

print_result() {
  if [ "$FAIL" -ne 0 ]; then
    echo "Backup did NOT complete cleanly, do not rely on ${BACKUP_FILE}. Check the controller is up:"
    echo "  kubectl -n ${NS} get pods"
    return 0
  fi
cat <<EOF
Sealed Secrets master key backed up to:
  ${BACKUP_FILE}
This file lives in the gitignored secrets/ dir, it is NEVER committed. Store a copy somewhere
safe off-cluster: a copy that only exists on this cluster is useless the day you lose the cluster.
Re-run after each key rotation.

RESTORE (after a rebuild):
  kubectl apply -f ${BACKUP_FILE}
  kubectl delete pod -n ${NS} -l app.kubernetes.io/name=sealed-secrets   # restart to load the key
EOF
}

# ---- main ----

check_prerequisites
count_key_secrets
write_backup
verify_backup

summary
print_result
[ "$FAIL" -eq 0 ]
