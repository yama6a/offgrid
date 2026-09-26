#!/usr/bin/env bash
# DANGEROUS: first-time platform install onto a freshly built cluster. It asks once, then runs unattended.
# For a cluster that already runs the platform, use DANGEROUS_rebuild_cluster.sh.
#
# A fresh controller mints a new master key, and SealedSecrets sealed with an old key do not decrypt.
# A rebuild restores the old key. Here no old key exists, so this script seals again and backs up the new key.
#
# The first steps abort on failure with a resume hint. From the SSO seal on, every step is best-effort,
# so a slow ArgoCD cannot block the run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
cd "$REPO_ROOT" || exit 1

# ---- knobs ----
STEP=0
STEP_TOTAL=18           # the number of step and run_step calls below. Change it when you add or remove a step.
STEP_DIR="$SCRIPT_DIR"  # the step scripts sit next to this one
INGRESS_GW_NS="gateway" # namespace of the shared Gateway
INGRESS_HOSTS=""        # space-separated hosts to check. Empty means all hosts on the Gateways.
CONTROLLER_WAIT=900     # seconds to wait for the wave-2 sealed-secrets controller
INGRESS_WAIT=900        # seconds to wait for the ingress to serve. HTTP-01 is slow.
CONVERGE_WAIT=900       # seconds to wait for every app to reach Synced and Healthy
COMMIT_MSG_SYNC="bootstrap: sync config before ArgoCD bootstrap"
COMMIT_MSG_SEAL="bootstrap: seal SSO, webhook and S3 backup secrets again"

# ---- functions ----

check_prerequisites() {
  require git kubectl helm yq kubeseal
  ensure_cluster_dir
  docker info > /dev/null 2>&1 || die "docker is not responding. Start Rancher Desktop or Docker Desktop."
  [ -f "${STEP_DIR}/01_cilium.sh" ] || die "missing 01_cilium.sh. Run this from the repo root."
  # Before the banner, so the prompt names the target context and a wrong KUBE_CONTEXT fails before you confirm.
  use_kubeconfig
}

confirm_bootstrap() {
  cat << EOF

This installs the whole platform onto the cluster that KUBE_CONTEXT in .env names:
  context : ${KUBE_CONTEXT}
  config  : ${KUBECONFIG}
  steps   : 01 CNI, 04_values, commit and push, 02a ArgoCD, seal SSO, webhook and backup creds,
            commit and push, converge, seed ntfy, back up the new key, verify ingress

It needs an existing Kubernetes cluster with no CNI and kube-proxy disabled, and a kubectl context for it.
See "What this expects of your cluster" in the README.
If the cluster already runs the platform, abort and use DANGEROUS_rebuild_cluster.sh.
EOF
  confirm_word_always BOOTSTRAP || {
    echo "aborted."
    exit 0
  }
}

# Without a reachable API, every later step fails with an unclear error.
assert_cluster_exists() {
  local node_count
  say "precondition: the cluster exists and is reachable"
  assert_api
  node_count="$(kubectl get nodes --no-headers 2> /dev/null | wc -l | tr -d ' ')"
  [ "${node_count:-0}" -gt 0 ] || die "no nodes found through context ${KUBE_CONTEXT} (${KUBECONFIG}).
       Build a cluster first and point KUBE_CONTEXT at it. See \"What this expects of your cluster\" in the README."
  ok "${node_count} node(s) reachable. They stay NotReady until step 1 installs the CNI."
}

commit_and_push_config() {
  step "commit and push the LB range and every chart value written so far"
  git add -A
  if git diff --cached --quiet; then
    ok "nothing new to commit"
  else
    git commit -m "$COMMIT_MSG_SYNC" > /dev/null && ok "committed local changes" || die "git commit failed"
  fi
  git push || die "git push failed. ArgoCD deploys the remote. Push by hand, then resume from 02a_argocd.sh by hand."
  ok "remote up to date"
}

# Every seal step and the key backup need this wave-2 controller, which ArgoCD creates shortly after 02a.
wait_for_sealed_secrets_controller() {
  local deadline
  step "waiting up to ${CONTROLLER_WAIT}s for the wave-2 sealed-secrets controller"
  use_kubeconfig
  deadline=$(($(date +%s) + CONTROLLER_WAIT))
  until kubectl get pods -n "$SS_CONTROLLER_NS" -l "$SS_POD_SELECTOR" \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2> /dev/null | grep -q True; do
    [ "$(date +%s)" -lt "$deadline" ] || die "sealed-secrets controller not Ready within ${CONTROLLER_WAIT}s. Check: kubectl -n ${SS_CONTROLLER_NS} get pods. The cluster is up. When the controller is Ready, run 04_google_sso and 02b_argocd_webhook by hand, commit and push, then run 03_backup_sealed_secrets_key.sh."
    printf '.'
    sleep 10
  done
  echo
  ok "sealed-secrets controller Ready"
}

reseal_google_sso() {
  if [ -n "$GOOGLE_SSO_CLIENT_ID" ] && [ -n "$GOOGLE_SSO_CLIENT_SECRET" ]; then
    run_step "write the clientID and seal the client secret" "$STEP_DIR" 04_google_sso.sh best-effort \
      "04_google_sso did not complete. Run 04_google_sso.sh by hand, then commit and push."
  else
    step "seal Google SSO: skipped, the .env creds are empty"
    warn "GOOGLE_SSO_CLIENT_ID or GOOGLE_SSO_CLIENT_SECRET is empty in .env. google-oauth stays undecryptable until you set them and run 04_google_sso.sh."
  fi
}

# Sealing needs the live controller, and 04_values runs before ArgoCD. An empty token means 04_values set no zones.
reseal_cloudflare_token() {
  if [ -n "$CLOUDFLARE_API_TOKEN_SECRET" ]; then
    run_step "seal the Cloudflare DNS-01 API token" "$STEP_DIR" 04_cloudflare_token.sh best-effort \
      "04_cloudflare_token did not complete. Run 'make configure-cloudflare-token', then commit and push."
  else
    step "seal the Cloudflare DNS-01 token: skipped, the .env token is empty"
  fi
}

# 02b generates its own webhook secret, so it always runs. The GitHub side needs public DNS and the prod cert,
# so it stays a manual step. 02b prints the setup.
seal_argocd_webhook() {
  run_step "generate and seal the GitHub webhook secret, set the poll interval" "$STEP_DIR" 02b_argocd_webhook.sh best-effort \
    "02b_argocd_webhook did not complete. Run 02b_argocd_webhook.sh by hand, then commit and push."
}

# run_backup_step <script> <label> <hint> <skip-label>. Every S3 step shares one .env check, so none runs half set up.
run_backup_step() {
  if [ -n "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
    run_step "$2" "$STEP_DIR" "$1" best-effort "$3"
  else
    step "$4"
  fi
}

enable_s3_backups() {
  run_backup_step 10a_s3_backup_bucket.sh "Terraform: S3 backup bucket and scoped IAM writer" \
    "10a_s3_backup_bucket did not complete. Run 'make s3-backup-bucket' by hand." \
    "S3 backup bucket: skipped, the .env AWS creds are empty"
  [ -n "$AWS_DEPLOY_ACCESS_KEY_ID" ] \
    || warn "AWS_DEPLOY_ACCESS_KEY_ID is empty in .env. Skipping S3 backups: no bucket, and every backup stays off."
  run_backup_step 10b_cnpg_backup.sh "seal the S3 creds and turn on backups in pg-cluster" \
    "10b_cnpg_backup did not complete. Run 'make configure-cnpg-backup', then commit and push." \
    "CNPG S3 backups: skipped, the .env AWS creds are empty"
  run_backup_step 10c_redis_backup.sh "turn on Redis S3 backups: seal creds, write chart values" \
    "10c_redis_backup did not complete. Run 'make configure-redis-backup', then commit and push." \
    "Redis S3 backups: skipped, the .env AWS creds are empty"
  run_backup_step 10d_longhorn_backup.sh "turn on Longhorn volume S3 backups: seal creds, write backup target" \
    "10d_longhorn_backup did not complete. Run 'make configure-longhorn-backup', then commit and push." \
    "Longhorn volume S3 backups: skipped, the .env AWS creds are empty"
  run_backup_step 10e_vm_backup.sh "turn on VictoriaMetrics and VictoriaLogs S3 backups: seal creds, write chart values" \
    "10e_vm_backup did not complete. Run 'make configure-vm-backup', then commit and push." \
    "VictoriaMetrics and VictoriaLogs S3 backups: skipped, the .env AWS creds are empty"
}

commit_and_push_sealed_secrets() {
  step "commit and push the sealed secrets and backup values, for ArgoCD to unseal"
  git add -A
  if git diff --cached --quiet; then
    ok "nothing new to commit"
  else
    git commit -m "$COMMIT_MSG_SEAL" > /dev/null && ok "committed the sealed secrets" || warn "commit failed. Commit and push by hand."
  fi
  git push || warn "push failed. Push by hand, so ArgoCD gets the sealed secrets."
}

# The GitHub webhook is not set up yet and the poll runs every 300s, so ArgoCD would miss the push for minutes.
# A hard refresh of every app applies the sealed secrets now. The wave-5 ntfy app is up when this returns.
converge_after_seal() {
  step "converge ArgoCD: apply the sealed secrets and heal stuck apps, up to ${CONVERGE_WAIT}s"
  converge_argocd_apps "$CONVERGE_WAIT" || true
}

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
    git commit -m "bootstrap: seal Grafana ntfy token" > /dev/null && ok "committed the sealed ntfy token" || warn "commit failed. Commit by hand."
  fi
  git push || warn "push failed. Push the sealed grafana-ntfy token by hand."
  converge_argocd_apps "$CONVERGE_WAIT" || true
  kubectl -n "$MONITORING_NS" rollout restart deploy/grafana > /dev/null 2>&1 \
    && ok "Grafana restarted and reads GF_NTFY_TOKEN" || warn "restart Grafana by hand, so it reads GF_NTFY_TOKEN"
}

# A later DANGEROUS_rebuild_cluster.sh restores this key, so the committed SealedSecrets still decrypt.
backup_new_master_key() {
  run_step "back up the new sealed-secrets master key" "$STEP_DIR" 03_backup_sealed_secrets_key.sh best-effort \
    "key backup did not complete. When the controller is up, run 03_backup_sealed_secrets_key.sh by hand."
}

# HTTP-01 issuance takes minutes, so this polls each HTTPS host until it serves with a Let's Encrypt cert.
verify_ingress_serving() {
  step "verify that the ingress serves HTTPS with a Let's Encrypt cert, up to ${INGRESS_WAIT}s"
  verify_ingress "$INGRESS_GW_NS" "$INGRESS_WAIT" "$INGRESS_HOSTS" || true
}

print_handoff() {
  cat << EOF

=============== cluster bootstrapped ===============
ArgoCD is up and reconciles every app from git. Watch it:
  kubectl get applications -n argocd -w

Notes:
  - If step 17 succeeded, the new sealed-secrets master key is backed up to ${CLUSTER_DIR}/sealed-secrets-master.key.
    Keep a copy off the cluster. A later rebuild restores from it.
  - If the SSO seal in step 6 was skipped or failed, set the .env creds, run 04_google_sso.sh </dev/null,
    then commit and push.
  - If NTFY_PHONE_PASSWORD_SECRET was set, step 16 set up ntfy phone alerts. On your phone, add server
    https://ntfy.${OPS_DOMAIN}, log in as 'phone' and subscribe to 'cluster-alerts'. If the step was skipped or
    failed, set the .env password, run 'make configure-ntfy-auth', commit and push, and restart Grafana.
  - The ArgoCD git poll is now a slow fallback for the webhook. Finish the GitHub webhook: paste
    ${CLUSTER_DIR}/argocd-github-webhook-secret.txt into the repo's webhook, with Payload URL
    https://argocd.<domain>/api/webhook, content type application/json and the push event. See docs/runbooks/02_gitops.md.
  - TLS certs come from HTTP-01, and the first issuance takes a few minutes. The platform ingress uses
    letsencrypt-prod, because GitHub webhook SSL verification needs a trusted cert. Mind the prod rate limits.
EOF
}

# ---- main ----

check_prerequisites
confirm_bootstrap
assert_cluster_exists

run_step "CNI, monitoring CRDs, LB-IPAM, L2 and Hubble" "$STEP_DIR" 01_cilium.sh
run_step "write .env into every chart value ArgoCD renders" "$STEP_DIR" 04_values.sh
commit_and_push_config
run_step "install ArgoCD, which delivers the rest from git" "$STEP_DIR" 02a_argocd.sh

wait_for_sealed_secrets_controller
reseal_google_sso
reseal_cloudflare_token
seal_argocd_webhook
enable_s3_backups
commit_and_push_sealed_secrets
converge_after_seal
seed_ntfy_and_push_token
backup_new_master_key
verify_ingress_serving
print_handoff
