#!/usr/bin/env bash
# Backs up the Sealed Secrets controller's RSA private keys to the gitignored secrets/ dir.
# Without these keys, no SealedSecret in this repo can be decrypted.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
NS="$SS_CONTROLLER_NS"                                 # controller namespace
KEY_LABEL="$SS_KEY_LABEL"                              # label the controller stamps on its key Secrets
BACKUP_FILE="${CLUSTER_DIR}/sealed-secrets-master.key" # in the gitignored secrets/ dir

# ---- functions ----

check_prerequisites() {
  say "prerequisites"
  require kubectl
  ensure_cluster_dir
  use_kubeconfig
  assert_api
  ok "kubectl present, API reachable"
}

# The controller rotates its key about monthly and keeps the old keys, which still decrypt older SealedSecrets.
count_key_secrets() {
  local keys count
  say "looking for key Secrets in ns/${NS} (label ${KEY_LABEL})"
  keys="$(kubectl get secret -n "$NS" -l "$KEY_LABEL" -o name 2> /dev/null)"
  if [ -z "$keys" ]; then
    bad "no Secrets with label ${KEY_LABEL} in ns/${NS}. Is the controller running? Check: kubectl -n ${NS} get pods"
    summary
    exit 1
  fi
  count="$(printf '%s\n' "$keys" | grep -c .)"
  ok "found ${count} key Secret(s)"
}

# The upstream restore procedure applies this -o yaml dump with kubectl apply.
write_backup() {
  say "writing the backup to ${BACKUP_FILE}"
  # A direct redirect truncates first, so a failed dump would empty a good backup. mktemp is 0600 and mv keeps it.
  local tmp
  tmp="$(mktemp "${BACKUP_FILE}.XXXXXX")" || {
    bad "could not write next to ${BACKUP_FILE}"
    return
  }
  if kubectl get secret -n "$NS" -l "$KEY_LABEL" -o yaml > "$tmp" 2> /dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$BACKUP_FILE"
    ok "keys written with mode 600"
  else
    rm -f "$tmp"
    bad "kubectl get failed. Backup not written. Any previous backup is unchanged."
  fi
}

verify_backup() {
  say "verifying the backup"
  [ -s "$BACKUP_FILE" ] && ok "backup file is non-empty" || bad "backup file is empty"
  grep -q 'kind: Secret' "$BACKUP_FILE" 2> /dev/null \
    && ok "backup contains Secret manifests" || bad "backup does not contain 'kind: Secret'"
}

print_result() {
  if [ "$FAIL" -ne 0 ]; then
    echo "Backup failed. Do not rely on ${BACKUP_FILE}. Check that the controller is up:"
    echo "  kubectl -n ${NS} get pods"
    return 0
  fi
  cat << EOF
Sealed Secrets master key backed up to:
  ${BACKUP_FILE}
This file is in the gitignored secrets/ dir and is never committed.
Keep a copy off the cluster. A copy that exists only on this cluster is lost with the cluster.
Run this script again after each key rotation.

Restore after a rebuild:
  kubectl apply -f ${BACKUP_FILE}
  kubectl delete pod -n ${NS} -l app.kubernetes.io/name=sealed-secrets   # the restart loads the key
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
