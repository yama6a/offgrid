#!/usr/bin/env bash
# DANGEROUS: one-shot first-time platform install onto a freshly built cluster. One confirmation up
# front, non-interactive after that. To re-deliver onto a RUNNING cluster use DANGEROUS_rebuild_cluster.sh.
#
# Why this re-seals AND backs up, where a rebuild does neither: a fresh controller mints a brand-new master
# key, so a SealedSecret committed against the OLD key is orphaned. A rebuild RESTORES the old key instead.
# Here there is no old key, so we re-seal and then back the new one up.
#
# The first steps abort on the first failure with a resume hint; everything from the SSO re-seal on is
# best-effort, so a slow ArgoCD never wedges the run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
cd "$REPO_ROOT" || exit 1           # git ops and relative hints below; set -e is off, so guard the cd

# ---- knobs ----
STEP=0; STEP_TOTAL=18               # common.sh step/run_step; bump TOTAL if you add or remove a step
STEP_DIR="$SCRIPT_DIR"              # every step script is a sibling of this orchestrator
INGRESS_GW_NS="gateway"             # namespace of the shared Gateway (ingress verify)
INGRESS_HOSTS=""                    # space-separated hosts to check; empty = derive from Gateways
CONTROLLER_WAIT=900                 # secs to wait for the sealed-secrets controller (ArgoCD wave 2)
INGRESS_WAIT=900                    # secs to wait for the ingress to actually serve (HTTP-01 is slow)
CONVERGE_WAIT=900                   # secs for the converge backstop to drive every app to Synced+Healthy
COMMIT_MSG_SYNC="bootstrap: sync config before ArgoCD bootstrap"
COMMIT_MSG_SEAL="bootstrap: re-seal SSO + argocd webhook secrets + CNPG/Redis S3 backup creds/values"

# ---- functions ----

check_prerequisites() {
  require git kubectl helm yq kubeseal
  ensure_cluster_dir
  docker info >/dev/null 2>&1 || die "docker not responding (start Rancher/Docker Desktop)"
  [ -f "${STEP_DIR}/01_cilium.sh" ] || die "missing 01_cilium.sh, run from the repo root"
  # Pinned BEFORE the banner, so the confirmation names the context this installs onto and an unset or typo'd
  # KUBE_CONTEXT fails here rather than after you have typed the confirmation word. Cheap (a config read); the
  # reachability probe waits until you have agreed to proceed.
  use_kubeconfig
}

confirm_bootstrap() {
cat <<EOF

This will install the ENTIRE platform onto the cluster KUBE_CONTEXT names in .env:
  context : ${KUBE_CONTEXT}
  config  : ${KUBECONFIG}
  flow    : 01 (CNI) -> 04_values -> commit/push -> 02a (ArgoCD) -> re-seal SSO/webhook/backup creds
            -> commit/push -> converge -> seed ntfy -> back up the new key -> verify ingress

Requires a Kubernetes cluster that already exists, with no CNI installed and kube-proxy disabled, and a
kubectl context pointing at it. See the README, "What this expects of your cluster".
To re-deliver onto a cluster that already has a platform, abort and use DANGEROUS_rebuild_cluster.sh.
EOF
  confirm_word_always BOOTSTRAP || { echo "aborted (phew!)."; exit 0; }
}

# This repo does not build the cluster, so the only preflight is that one exists and we can reach it. An
# unreachable API here means there is nothing to install onto, and every step below would fail obscurely.
assert_cluster_exists() {
  local node_count
  say "precondition: the cluster exists and is reachable"
  assert_api
  node_count="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [ "${node_count:-0}" -gt 0 ] || die "no nodes found via context ${KUBE_CONTEXT} (${KUBECONFIG}).
       Build a cluster first and point KUBE_CONTEXT at it. See the README, \"What this expects of your cluster\"."
  ok "${node_count} node(s) reachable (NotReady is expected until step 1 installs the CNI)"
}

commit_and_push_config() {
  step "git add + commit + push (config so far: LB range + every stamped chart value)"
  git add -A
  if git diff --cached --quiet; then
    ok "nothing new to commit"
  else
    git commit -m "$COMMIT_MSG_SYNC" >/dev/null && ok "committed local changes" || die "git commit failed"
  fi
  git push || die "git push failed, ArgoCD deploys the REMOTE; push manually then resume from 02a_argocd.sh by hand"
  ok "remote up to date"
}

# Every seal step and the key backup need the controller up. It is a wave-2 app, so ArgoCD creates it a bit
# after 02a. Aborts with a manual-recovery hint if it never comes up: the cluster is still fine, you would
# just re-seal and back up by hand later.
wait_for_sealed_secrets_controller() {
  local deadline
  step "waiting for the sealed-secrets controller (ArgoCD wave 2), up to ${CONTROLLER_WAIT}s"
  use_kubeconfig
  deadline=$(( $(date +%s) + CONTROLLER_WAIT ))
  until kubectl get pods -n "$SS_CONTROLLER_NS" -l "$SS_POD_SELECTOR" \
          -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; do
    [ "$(date +%s)" -lt "$deadline" ] || die "sealed-secrets controller not Ready within ${CONTROLLER_WAIT}s (kubectl -n ${SS_CONTROLLER_NS} get pods). Cluster is up; once the controller is Ready, re-seal by hand (04_google_sso, 02b_argocd_webhook) + commit/push, then 03_backup_sealed_secrets_key.sh."
    printf '.'; sleep 10
  done
  echo; ok "sealed-secrets controller Ready"
}

# Re-writes the shared clientID and re-seals google-oauth against the fresh key. No prompting: allowlists are
# per-ingress values already in git.
reseal_google_sso() {
  if [ -n "$GOOGLE_SSO_CLIENT_ID" ] && [ -n "$GOOGLE_SSO_CLIENT_SECRET" ]; then
    run_step "re-writes clientID + re-seals the client secret" "$STEP_DIR" 04_google_sso.sh best-effort \
      "04_google_sso didn't complete; re-run it by hand ('04_google_sso.sh') + commit/push"
  else
    step "re-seal Google SSO (skipped: .env creds empty)"
    warn "GOOGLE_SSO_CLIENT_ID/SECRET empty in .env -> skipping SSO re-seal (google-oauth stays orphaned until you set them + run 07)"
  fi
}

# Split from 04_values: sealing needs the LIVE controller (up now), but 04_values runs before ArgoCD. Skipped
# when the token is empty, in which case 04_values already forced the zones to [].
reseal_cloudflare_token() {
  if [ -n "$CLOUDFLARE_API_TOKEN_SECRET" ]; then
    run_step "re-seal the Cloudflare DNS-01 API token" "$STEP_DIR" 04_cloudflare_token.sh best-effort \
      "04_cloudflare_token didn't complete; re-run it by hand ('make configure-cloudflare-token') + commit/push"
  else
    step "re-seal Cloudflare DNS-01 token (skipped: .env token empty)"
  fi
}

# Not guarded on a .env secret: 02b GENERATES its own webhook secret and always runs. The GitHub webhook
# itself is a manual post-boot step (it needs public DNS + the prod cert); 02b prints the exact setup.
seal_argocd_webhook() {
  run_step "generate+seal the GitHub webhook secret + set poll cadence" "$STEP_DIR" 02b_argocd_webhook.sh best-effort \
    "02b_argocd_webhook didn't complete; re-run it by hand ('02b_argocd_webhook.sh') + commit/push"
}

# run_backup_step <script> <label> <hint> <skip-label>: every S3 step shares the same .env gate, and they are
# kept paired so none runs half-configured. 10a needs no cluster (pure AWS) but is grouped here so the commit
# below carries any resulting state note.
run_backup_step() {
  if [ -n "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
    run_step "$2" "$STEP_DIR" "$1" best-effort "$3"
  else
    step "$4"
  fi
}

enable_s3_backups() {
  run_backup_step 10a_s3_backup_bucket.sh "Terraform: S3 backup bucket + scoped IAM writer" \
    "10a_s3_backup_bucket didn't complete; re-run it by hand ('make s3-backup-bucket')" \
    "S3 backup bucket (skipped: .env AWS creds empty)"
  [ -n "$AWS_DEPLOY_ACCESS_KEY_ID" ] \
    || warn "AWS_DEPLOY_ACCESS_KEY_ID empty in .env -> skipping S3 backups (no bucket; CNPG backups stay off)"
  run_backup_step 10b_cnpg_backup.sh "seal S3 creds per CNPG ns + enable backups in pg-cluster" \
    "10b_cnpg_backup didn't complete; re-run it by hand ('make configure-cnpg-backup') + commit/push" \
    "enable CNPG S3 backups (skipped: .env AWS creds empty)"
  run_backup_step 10c_redis_backup.sh "enable central Redis S3 backups (seal creds + chart values)" \
    "10c_redis_backup didn't complete; re-run it by hand ('make configure-redis-backup') + commit/push" \
    "enable Redis S3 backups (skipped: .env AWS creds empty)"
  run_backup_step 10d_longhorn_backup.sh "enable Longhorn volume S3 backups (seal creds + backup target)" \
    "10d_longhorn_backup didn't complete; re-run it by hand ('make configure-longhorn-backup') + commit/push" \
    "enable Longhorn volume S3 backups (skipped: .env AWS creds empty)"
  run_backup_step 10e_vm_backup.sh "enable central VM/VL S3 backups (seal creds + chart values)" \
    "10e_vm_backup didn't complete; re-run it by hand ('make configure-vm-backup') + commit/push" \
    "enable VM/VL S3 backups (skipped: .env AWS creds empty)"
}

commit_and_push_sealed_secrets() {
  step "git add + commit + push the re-sealed secrets + backup creds/values (ArgoCD unseals them; waves 2,4,7,8 + argocd)"
  git add -A
  if git diff --cached --quiet; then
    ok "nothing new to commit"
  else
    git commit -m "$COMMIT_MSG_SEAL" >/dev/null && ok "committed re-sealed secrets" || warn "commit failed; commit + push by hand"
  fi
  git push || warn "push failed; push by hand so ArgoCD picks up the re-sealed secrets"
}

# The git poll is a 300s fallback and the GitHub webhook is not configured yet, so ArgoCD would not pick up the
# push above on its own for minutes. converge_argocd_apps hard-refreshes EVERY app so it re-compares against
# the pushed commit and applies the re-sealed secrets now, then nudges stragglers.
# Best-effort: never fails the bootstrap. ntfy (wave 5) is up once this returns.
converge_after_seal() {
  step "converge ArgoCD (pull re-sealed secrets + self-heal backstop, up to ${CONVERGE_WAIT}s)"
  converge_argocd_apps "$CONVERGE_WAIT" || true
}

# 06_ntfy_auth execs the running pod to create the phone/grafana users + ACLs and seal Grafana's write token.
# Then push it (so ArgoCD applies the SealedSecret) and restart Grafana to pick up GF_NTFY_TOKEN.
seed_ntfy_and_push_token() {
  if [ -z "$NTFY_PHONE_PASSWORD_SECRET" ]; then
    step "seed ntfy auth (skipped: .env NTFY_PHONE_PASSWORD_SECRET empty)"
    warn "NTFY_PHONE_PASSWORD_SECRET empty in .env -> ntfy alerting off; set it + run 'make configure-ntfy-auth' later"
    return 0
  fi
  run_step "seed ntfy users + seal Grafana's ntfy token" "$STEP_DIR" 06_ntfy_auth.sh best-effort \
    "06_ntfy_auth didn't complete; re-run 'make configure-ntfy-auth' + commit/push once ntfy is up" || return 0
  git add -A
  if git diff --cached --quiet; then ok "no ntfy token change to commit"; else
    git commit -m "bootstrap: seal Grafana ntfy token" >/dev/null && ok "committed sealed ntfy token" || warn "commit failed; commit by hand"
  fi
  git push || warn "push failed; push the sealed grafana-ntfy token by hand"
  converge_argocd_apps "$CONVERGE_WAIT" || true                                   # apply the pushed SealedSecret
  kubectl -n "$MONITORING_NS" rollout restart deploy/grafana >/dev/null 2>&1 \
    && ok "grafana restarted (picks up GF_NTFY_TOKEN)" || warn "restart grafana by hand to pick up GF_NTFY_TOKEN"
}

# So a future DANGEROUS_rebuild_cluster.sh can RESTORE it instead of orphaning these SealedSecrets again.
backup_new_master_key() {
  run_step "back up the new sealed-secrets master key" "$STEP_DIR" 03_backup_sealed_secrets_key.sh best-effort \
    "key backup didn't complete; run 03_backup_sealed_secrets_key.sh by hand once the controller is up"
}

# ArgoCD brings the ingress stack up ASYNC and HTTP-01 issuance takes minutes, so verify_ingress polls each
# HTTPS host until it serves a REAL, LE-backed response. Best-effort: warns, never fails the bootstrap.
verify_ingress_serving() {
  step "verify ingress serving (LE cert + HTTPS response), up to ${INGRESS_WAIT}s"
  verify_ingress "$INGRESS_GW_NS" "$INGRESS_WAIT" $INGRESS_HOSTS || true
}

print_handoff() {
cat <<EOF

=============== cluster bootstrapped ===============
ArgoCD is bootstrapped and reconciling every app from git. Watch it:
  kubectl get applications -n argocd -w

Notes:
  - A NEW sealed-secrets master key was backed up to ${CLUSTER_DIR}/sealed-secrets-master.key
    (if STEP 17 succeeded). Keep a copy off-cluster; a future rebuild restores from it.
  - If the SSO re-seal (STEP 6) was skipped or failed, set the .env creds and re-run
    04_google_sso.sh </dev/null, then commit + push.
  - ntfy mobile-push alerting: STEP 16 seeded it automatically (if NTFY_PHONE_PASSWORD_SECRET was set). On your
    phone, add server https://ntfy.ops.example.com, log in as 'phone', subscribe 'cluster-alerts'. If it was
    skipped/failed, set the .env password + run 'make configure-ntfy-auth' + commit/push + restart grafana.
  - ArgoCD git-poll is a slow fallback now (webhook-driven). Finish the GitHub webhook: paste
    ${CLUSTER_DIR}/argocd-github-webhook-secret.txt into the repo's webhook (Payload URL
    https://argocd.<domain>/api/webhook, content-type application/json, push event). See 02_gitops.md.
  - TLS certs issue via HTTP-01; first issuance takes a few minutes. NB the platform ingress is on
    letsencrypt-PROD now (GitHub webhook SSL verification needs a trusted cert). Mind the prod rate limits.
EOF
}

# ---- main ----

check_prerequisites
confirm_bootstrap
assert_cluster_exists

run_step "CNI + monitoring CRDs + LB/L2 + Hubble" "$STEP_DIR" 01_cilium.sh
run_step "propagate .env into every chart value ArgoCD renders" "$STEP_DIR" 04_values.sh
commit_and_push_config
run_step "bootstrap ArgoCD; it delivers the rest from git" "$STEP_DIR" 02a_argocd.sh

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
