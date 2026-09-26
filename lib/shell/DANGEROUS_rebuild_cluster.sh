#!/usr/bin/env bash
# DANGEROUS: tears the platform down to bare Kubernetes and delivers it again. It asks once, up front.
# It does not touch the nodes. The tooling that built the machines wipes them.
#
# A rebuild wipes local data and the S3 backups. The empty clusters that ArgoCD creates under the same names
# then start a clean backup history, with no systemID conflict. To keep the old data, restore before rebuilding.
#
# The script restores the sealed-secrets key, so the committed SealedSecrets still decrypt. It does not back
# the key up, because that could overwrite a good backup with a key about to be wiped. Back up the key first.
# Without a backup the restore fails cleanly, and you seal again instead.
#
# The first steps abort on failure. From the key restore on, every step is best-effort.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
cd "$REPO_ROOT" || exit 1 # the git commands below need the repo root

# ---- knobs ----
STEP=0
STEP_TOTAL=9           # the number of step and run_step calls below. Change it when you add or remove a step.
STEP_DIR="$SCRIPT_DIR" # the step scripts sit next to this one
RESTORE="${STEP_DIR}/03_restore_sealed_secrets_key.sh"
INGRESS_GW_NS="gateway" # namespace of the shared Gateway
COMMIT_MSG="rebuild: sync working tree before cluster rebuild"
COMMIT_MSG_SYNC="rebuild: sync LB range written by 01_cilium"
INGRESS_WAIT=900    # seconds to wait for the ingress to serve. HTTP-01 is slow.
INGRESS_HOSTS=""    # space-separated hosts to check. Empty means all hosts on the Gateway listeners.
CONVERGE_SETTLE=120 # seconds for ArgoCD to create its apps and roll the early waves
CONVERGE_WAIT=900   # seconds to wait for every app to reach Synced and Healthy

# ---- functions ----

check_prerequisites() {
  require git kubectl helm yq kubeseal
  ensure_cluster_dir
  [ -f "$RESTORE" ] || die "missing ${RESTORE}"
  # Before the banner, so the prompt names the target context and a wrong KUBE_CONTEXT fails before you confirm.
  use_kubeconfig
}

confirm_rebuild() {
  cat << EOF

This delivers the whole platform again onto the cluster that KUBE_CONTEXT in .env names:
  context : ${KUBE_CONTEXT}
  config  : ${KUBECONFIG}
  steps   : commit and push, 01 CNI, commit and push, 02a ArgoCD, restore the sealed-secrets key,
            wipe the S3 backups, converge, seed ntfy, verify ingress
            ArgoCD deploys Cilium, cert-manager, Longhorn, the gateway, SSO and monitoring from git.
  note    : it wipes the S3 backups, so the databases come back empty. To keep the old data,
            restore from S3 with make restore-cnpg before you rebuild.
  nodes   : not touched. To wipe the machines, use the tooling that built them first, then come back here.

You need a current sealed-secrets key backup from 03_backup_sealed_secrets_key.sh.
Without it, SSO does not decrypt until you seal again with 04_google_sso.
06_ntfy_auth seeds ntfy alerting after boot either way.
EOF
  confirm_word_always REBUILD || {
    echo "aborted."
    exit 0
  }
}

commit_and_push_working_tree() {
  step "commit and push the working tree"
  git add -A
  if git diff --cached --quiet; then
    ok "nothing new to commit"
  else
    git commit -m "$COMMIT_MSG" > /dev/null && ok "committed local changes" || die "git commit failed"
  fi
  git push || die "git push failed. ArgoCD deploys the remote. Push by hand, then run this again."
  ok "remote up to date"
}

assert_cluster_exists() {
  local node_count
  say "precondition: the cluster exists and is reachable"
  assert_api
  node_count="$(kubectl get nodes --no-headers 2> /dev/null | wc -l | tr -d ' ')"
  [ "${node_count:-0}" -gt 0 ] || die "no nodes found through context ${KUBE_CONTEXT} (${KUBECONFIG}).
       Rebuild the cluster first with the tooling that built it, then point KUBE_CONTEXT at it."
  ok "${node_count} node(s) reachable"
}

# 01_cilium writes the LB-IPAM range into 00_cilium's values.yaml after the first commit.
# 02a refuses to continue with uncommitted changes under argo_apps/.
commit_and_push_lb_range() {
  step "commit and push the LB range from 01_cilium"
  git add -A
  if git diff --cached --quiet; then
    ok "nothing new to commit"
  else
    git commit -m "$COMMIT_MSG_SYNC" > /dev/null && ok "committed the LB range" || die "git commit failed"
  fi
  git push || die "git push failed. ArgoCD deploys the remote. Push by hand, then resume from 02a_argocd.sh by hand."
  ok "remote up to date"
}

restore_master_key() {
  run_step "restore the backed-up sealed-secrets master key" "$STEP_DIR" 03_restore_sealed_secrets_key.sh best-effort \
    "key restore did not complete. See above. When sealed-secrets is up, restore by hand, or seal again with 04_google_sso, then commit and push."
}

# Old backups make the new clusters of the same name fail archiving on a systemID mismatch.
# This runs before the workloads start archiving. run_step cannot pass the `wipe` argument.
wipe_s3_backups() {
  if [ -z "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
    step "wipe S3 backups: skipped, the .env AWS creds are empty"
    return 0
  fi
  step "wipe the S3 backups. The bucket and IAM writer stay."
  if ASSUME_YES=1 bash "${STEP_DIR}/10a_s3_backup_bucket.sh" wipe < /dev/null; then
    ok "S3 backups wiped"
  else
    warn "S3 wipe did not complete. Run 'make s3-backup-wipe' before the new clusters start archiving."
  fi
}

# Each app's unbounded retry converges it on its own. The webhook is not up yet and the poll runs every 300s,
# so a hard refresh of every app applies this rebuild's commit and the restored key now.
converge_apps() {
  use_kubeconfig
  step "wait ${CONVERGE_SETTLE}s for ArgoCD, then converge all apps to Synced and Healthy, up to ${CONVERGE_WAIT}s"
  sleep "$CONVERGE_SETTLE"
  converge_argocd_apps "$CONVERGE_WAIT" || true
}

# A node reset before this run wipes the ntfy PVC, so ntfy starts with an empty auth DB and the committed token
# is stale. 06_ntfy_auth creates the users and ACLs again and seals a new token.
seed_ntfy_and_push_token() {
  if [ -z "$NTFY_PHONE_PASSWORD_SECRET" ]; then
    step "seed ntfy auth: skipped, NTFY_PHONE_PASSWORD_SECRET in .env is empty"
    warn "NTFY_PHONE_PASSWORD_SECRET is empty in .env, so ntfy alerting is off. Set it and run 'make configure-ntfy-auth' later."
    return 0
  fi
  run_step "seed ntfy users and seal the Grafana ntfy token" "$STEP_DIR" 06_ntfy_auth.sh best-effort \
    "06_ntfy_auth did not complete. When ntfy is up, run 'make configure-ntfy-auth', then commit and push." || return 0
  git add -A
  if git diff --cached --quiet; then ok "no ntfy token change to commit"; else
    git commit -m "rebuild: seal the Grafana ntfy token again" > /dev/null && ok "committed the sealed ntfy token" || warn "commit failed. Commit by hand."
  fi
  git push || warn "push failed. Push the sealed grafana-ntfy token by hand."
  converge_argocd_apps "$CONVERGE_WAIT" || true
  kubectl -n "$MONITORING_NS" rollout restart deploy/grafana > /dev/null 2>&1 \
    && ok "Grafana restarted and reads GF_NTFY_TOKEN" || warn "restart Grafana by hand, so it reads GF_NTFY_TOKEN"
}

# HTTP-01 issuance takes minutes, so the sites can still be down after 02a finishes.
verify_ingress_serving() {
  step "verify that the ingress serves HTTPS with a Let's Encrypt cert, up to ${INGRESS_WAIT}s"
  verify_ingress "$INGRESS_GW_NS" "$INGRESS_WAIT" "$INGRESS_HOSTS" || true
}

print_handoff() {
  cat << EOF

=============== cluster rebuilt ===============
ArgoCD is up and reconciles every app from git: Cilium, cert-manager, Longhorn, envoy-gateway, the gateway,
SSO and monitoring. Watch it:
  kubectl get applications -n argocd -w

Notes:
  - If the key restore in step 5 did not run, run lib/shell/03_restore_sealed_secrets_key.sh when sealed-secrets
    is up. Or seal again with 04_google_sso, then commit and push.
  - If NTFY_PHONE_PASSWORD_SECRET was set, step 8 seeded ntfy alerting again. A node reset before this run
    wipes the ntfy PVC, so step 8 sealed a new token. If the step was skipped or failed, run
    'make configure-ntfy-auth', commit and push, and restart Grafana.
    On your phone, subscribe to 'cluster-alerts' at https://ntfy.${OPS_DOMAIN} again.
  - Step 6 cleared the S3 backups, and a node reset before this run cleared every volume. The databases come back
    empty and start a clean backup history. The old data is gone unless you restored it before the rebuild.
    The bucket and IAM writer stay. Only \`make s3-backup-destroy\` removes them. See docs/10_backups.md.
  - TLS certs come again from HTTP-01, and the first issuance takes a few minutes. After many rebuilds, test hosts
    on letsencrypt-staging before you switch to prod, because the prod rate limits are tight.
EOF
}

# ---- main ----

check_prerequisites
confirm_rebuild
commit_and_push_working_tree
assert_cluster_exists

run_step "CNI, monitoring CRDs, LB-IPAM, L2 and Hubble" "$STEP_DIR" 01_cilium.sh
commit_and_push_lb_range
run_step "install ArgoCD, which deploys the rest from git" "$STEP_DIR" 02a_argocd.sh

restore_master_key
wipe_s3_backups
converge_apps
seed_ntfy_and_push_token
verify_ingress_serving
print_handoff
