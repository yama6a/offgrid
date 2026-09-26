#!/usr/bin/env bash
# Restores the Sealed Secrets master key from the 03_backup dump and restarts the controller to load it.
# Without it, a rebuilt cluster's controller mints a new key and no committed SealedSecret decrypts.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
NS="$SS_CONTROLLER_NS"
CONTROLLER_LABEL="$SS_POD_SELECTOR"
KEY_LABEL="$SS_KEY_LABEL"                              # label the controller stamps on its key Secrets
BACKUP_FILE="${CLUSTER_DIR}/sealed-secrets-master.key" # written by 03_backup_sealed_secrets_key.sh
WAIT=900                                               # seconds to wait for the wave-2 controller

# ---- functions ----

check_prerequisites() {
  say "prerequisites"
  require kubectl
  ensure_cluster_dir
  use_kubeconfig
  [ -f "$BACKUP_FILE" ] || die "no backup at ${BACKUP_FILE}. Run 03_backup_sealed_secrets_key.sh on a cluster that holds the key, or seal again with 04_google_sso and 06_ntfy_auth."
  [ -s "$BACKUP_FILE" ] || die "backup ${BACKUP_FILE} is empty. Do not trust it."
  grep -q 'kind: Secret' "$BACKUP_FILE" 2> /dev/null || die "backup ${BACKUP_FILE} has no 'kind: Secret'. Wrong or corrupt file."
  assert_api
  ok "kubectl present, API reachable, backup looks valid"
}

# On a fresh rebuild the controller can still be starting.
wait_for_controller() {
  local deadline
  say "waiting for the sealed-secrets controller in ns/${NS} (up to ${WAIT}s)"
  deadline=$(($(date +%s) + WAIT))
  until kubectl get pods -n "$NS" -l "$CONTROLLER_LABEL" 2> /dev/null | grep -q ' Running'; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      bad "controller not Running after ${WAIT}s. Is ArgoCD past wave 2? Check: kubectl -n ${NS} get pods"
      summary
      exit 1
    fi
    printf '.'
    sleep 5
  done
  echo
  ok "controller is Running"
}

apply_backup_key() {
  say "applying ${BACKUP_FILE} into ns/${NS}"
  if kubectl apply -f "$BACKUP_FILE" > /dev/null 2>&1; then
    ok "key Secret(s) applied"
  else
    bad "kubectl apply failed. Key not restored."
  fi
}

# The fresh controller minted its own key, and new seals use the key with the latest cert NotBefore.
# Left in place, that key would seal new secrets and die with the next wipe.
remove_foreign_keys() {
  local backup_keys removed=0 s name
  say "removing keys that are not in the backup"
  backup_keys="$(kubectl create --dry-run=client -f "$BACKUP_FILE" -o name 2> /dev/null | sed 's#^.*/##')"
  if [ -z "$backup_keys" ]; then
    bad "could not read key names from ${BACKUP_FILE}. Left other keys in place, so the active sealing key can be one the next wipe destroys."
    return 0
  fi
  for s in $(kubectl get secret -n "$NS" -l "$KEY_LABEL" -o name 2> /dev/null); do
    name="${s#secret/}"
    grep -qx "$name" <<< "$backup_keys" && continue
    if kubectl delete -n "$NS" "$s" > /dev/null 2>&1; then
      printf '  removed key %s\n' "$name"
      removed=$((removed + 1))
    else
      bad "could not delete key ${name}. It can still be the active sealing key."
    fi
  done
  ok "removed ${removed} key(s). The backup key is now the active sealing key."
}

restart_controller() {
  say "restarting the controller to load the key"
  if kubectl delete pod -n "$NS" -l "$CONTROLLER_LABEL" > /dev/null 2>&1; then
    ok "controller pod(s) deleted. They restart now."
  else
    bad "could not restart the controller. Restart it by hand: kubectl delete pod -n ${NS} -l ${CONTROLLER_LABEL}"
  fi
  kubectl wait --for=condition=Ready pod -n "$NS" -l "$CONTROLLER_LABEL" --timeout=120s > /dev/null 2>&1 || true
}

print_result() {
  if [ "$FAIL" -ne 0 ]; then
    echo "Restore failed. If the controller was not up, wait for ArgoCD wave 2 and run this again."
    echo "Or seal again with 04_google_sso and 06_ntfy_auth, then commit and push."
    return 0
  fi
  cat << EOF
Sealed Secrets master key restored from:
  ${BACKUP_FILE}
The controller is up with the old key. The committed SealedSecrets decrypt into Secrets as ArgoCD applies them.
Verify:
  kubectl get sealedsecret -A
  kubectl get secret -A | grep -E 'google-oauth|grafana-ntfy'
EOF
}

# ---- main ----

check_prerequisites
wait_for_controller
apply_backup_key
remove_foreign_keys
restart_controller

summary
print_result
[ "$FAIL" -eq 0 ]
