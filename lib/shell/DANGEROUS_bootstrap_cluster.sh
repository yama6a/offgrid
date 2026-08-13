#!/usr/bin/env bash
# One-shot orchestrator for a FIRST-TIME platform install. Assumes a freshly built Talos cluster and an
# active kubectl context pointing at it, and takes it to a fully delivered platform. One confirmation up front, non-interactive
# after that. To re-deliver onto a RUNNING cluster use DANGEROUS_rebuild_cluster.sh instead.
#
# Sequence (STEP N/18):
#   1. 01_cilium.sh                 : CNI + prometheus-operator CRDs + LB-IPAM/L2 + Hubble
#   2. 04_values.sh                 : write repo URL, domains, SSO allowlist, ingress IP + ACME into the chart values
#   3. git add/commit/push          : 02a refuses a dirty argo_apps/ tree; ArgoCD deploys the REMOTE
#   4. 02a_argocd.sh                 : bootstrap ArgoCD, which then delivers the platform from git
#   5. wait sealed-secrets ctrl     : every later seal step needs it up
#   6. 04_google_sso.sh             : write the clientID + RE-SEAL google-oauth against the NEW key
#   7. 04_cloudflare_token.sh       : RE-SEAL the DNS-01 token against the NEW key
#   8. 02b_argocd_webhook.sh         : mint + seal the GitHub webhook secret, set the poll cadence
#   9. 10a_s3_backup_bucket.sh       : Terraform, S3 bucket + scoped IAM writer
#  10. 10b_cnpg_backup.sh            : seal the writer creds + enable CNPG backups
#  11. 10c_redis_backup.sh           : seal the writer creds + enable the central Redis backup job
#  12. 10d_longhorn_backup.sh        : seal the writer creds + set the Longhorn backup target
#  13. 10e_vm_backup.sh              : seal the writer creds + enable the central VM/VL backup job
#  14. git add/commit/push          : push the re-sealed secrets + backup values
#  15. converge argocd apps         : pull the pushed commit, wait for Healthy (ntfy must be up for STEP 16)
#  16. 06_ntfy_auth.sh              : seed ntfy users, seal Grafana's token, push it, restart grafana
#  17. 03_backup_sealed_secrets_key.sh : back up the NEW master key so a future rebuild can restore it
#  18. verify ingress serving       : wait until each HTTPS host serves an LE cert
#
# PRECONDITION: a Talos cluster already exists and your kubectl context points at it. Building it is the OS
# repo's job (https://github.com/yama6a/talos-raspberry-pi5-cluster); run `make bootstrap-cluster` there, then
# `make merge-kubeconfig` to make it your active context. The two repos keep SEPARATE secrets/ stores, so that
# context is the only thing that crosses. This script checks for it and refuses to start otherwise.
#
# Why re-seal AND back up, where a rebuild does neither: a fresh controller mints a brand-new master key, so
# a SealedSecret committed against the OLD key is orphaned. A rebuild instead RESTORES the old key. Here
# there is no old key, so we re-seal and then back the new one up.
#
# Steps 1-5 abort on the first failure with a resume hint; 6-18 are best-effort, so a slow ArgoCD never
# wedges the run.
#
# Needs git, kubectl, helm, yq, kubeseal.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"   # say/die/warn/ok + CLUSTER_DIR + use_kubeconfig + secret .env keys + REPO_ROOT
cd "$REPO_ROOT" || exit 1           # run from the repo root (git ops, relative hints); set -e is off, so guard cd

# ---- knobs ------------------------------------------------------------------
STEP=0; STEP_TOTAL=18                          # shared step counter (common.sh step/run_step); bump TOTAL if you add/remove a step
STEP_DIR="$SCRIPT_DIR"                          # every step script is a sibling of this orchestrator in lib/shell/
INGRESS_GW_NS="gateway"                        # namespace of the shared Gateway (ingress verify)
INGRESS_HOSTS=""                               # space-separated hosts to check; empty = derive from Gateways
CONTROLLER_WAIT=900                            # secs to wait for the sealed-secrets controller (ArgoCD wave 2)
INGRESS_WAIT=900                               # secs to wait for the ingress to actually serve (HTTP-01 is slow)
CONVERGE_WAIT=900                              # secs for the converge backstop to drive every app to Synced+Healthy
COMMIT_MSG_SYNC="bootstrap: sync config before ArgoCD bootstrap"
COMMIT_MSG_SEAL="bootstrap: re-seal SSO + argocd webhook secrets + CNPG/Redis S3 backup creds/values"

require git kubectl helm yq kubeseal
docker info >/dev/null 2>&1 || die "docker not responding (start Rancher/Docker Desktop)"
[ -f "${STEP_DIR}/01_cilium.sh" ] || die "missing 01_cilium.sh, run from the repo root"

# Pin the target cluster BEFORE the banner, so the confirmation names the context this will install onto, and
# so an unset/typo'd KUBE_CONTEXT fails here rather than after you have typed the confirmation word.
# Cheap (a config read); the reachability probe stays below, after you have agreed to proceed.
use_kubeconfig

cat <<EOF

This will install the ENTIRE platform onto the cluster KUBE_CONTEXT names in .env:
  context : ${KUBE_CONTEXT}
  config  : ${KUBECONFIG}
  flow    : 01 (CNI) -> 04_values -> commit/push -> 02a (ArgoCD) -> re-seal SSO/webhook/backup creds
            -> commit/push -> converge -> seed ntfy -> back up the new key -> verify ingress

Requires a Talos cluster that already exists, built in the OS repo:
  https://github.com/yama6a/talos-raspberry-pi5-cluster
  there:  make bootstrap-cluster && make merge-kubeconfig
To re-deliver onto a cluster that already has a platform, abort and use DANGEROUS_rebuild_cluster.sh.
EOF
confirm_word_always BOOTSTRAP || { echo "aborted (phew!)."; exit 0; }

# This repo does not build the cluster, so the only preflight is that one exists and we can reach it. An
# unreachable API here means the OS repo has not run, and every step below would fail obscurely.
say "precondition: the cluster exists and is reachable"
assert_api
NODE_COUNT="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
[ "${NODE_COUNT:-0}" -gt 0 ] || die "no nodes found via context ${KUBE_CONTEXT} (${KUBECONFIG}).
       Build the cluster first, in the OS repo:  https://github.com/yama6a/talos-raspberry-pi5-cluster
       there:  make bootstrap-cluster && make merge-kubeconfig"
ok "${NODE_COUNT} node(s) reachable (NotReady is expected until step 1 installs the CNI)"

run_step "CNI + monitoring CRDs + LB/L2 + Hubble" "$STEP_DIR" 01_cilium.sh

run_step "propagate .env into every chart value ArgoCD renders" "$STEP_DIR" 04_values.sh

step "git add + commit + push (config so far: LB range + every stamped chart value)"
git add -A
if git diff --cached --quiet; then
  ok "nothing new to commit"
else
  git commit -m "$COMMIT_MSG_SYNC" >/dev/null && ok "committed local changes" || die "git commit failed"
fi
git push || die "git push failed, ArgoCD deploys the REMOTE; push manually then resume from 02a_argocd.sh by hand"
ok "remote up to date"

run_step "bootstrap ArgoCD; it delivers the rest from git" "$STEP_DIR" 02a_argocd.sh

# kubeseal (the SSO/webhook/backup + ntfy-seal steps) + the key backup all need the controller up. It's a wave-2 app, so ArgoCD
# creates it a bit after 02a; poll until a controller pod is Ready. Abort with a manual-recovery hint if
# it never comes up (the cluster is still fine, you'd just re-seal + back up by hand later).
step "waiting for the sealed-secrets controller (ArgoCD wave 2), up to ${CONTROLLER_WAIT}s"
use_kubeconfig
deadline=$(( $(date +%s) + CONTROLLER_WAIT ))
until kubectl get pods -n "$SS_CONTROLLER_NS" -l "$SS_POD_SELECTOR" \
        -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; do
  [ "$(date +%s)" -lt "$deadline" ] || die "sealed-secrets controller not Ready within ${CONTROLLER_WAIT}s (kubectl -n ${SS_CONTROLLER_NS} get pods). Cluster is up; once the controller is Ready, re-seal by hand (04_google_sso, 02b_argocd_webhook) + commit/push, then 03_backup_sealed_secrets_key.sh."
  printf '.'; sleep 10
done
echo; ok "sealed-secrets controller Ready"

# 04_google_sso.sh no longer prompts (allowlists are per-ingress values already in git); it just re-writes
# the shared clientID + re-seals google-oauth against the fresh key. Skipped if the .env creds are empty.
if [ -n "$GOOGLE_SSO_CLIENT_ID" ] && [ -n "$GOOGLE_SSO_CLIENT_SECRET" ]; then
  run_step "re-writes clientID + re-seals the client secret" "$STEP_DIR" 04_google_sso.sh best-effort \
    "04_google_sso didn't complete; re-run it by hand ('04_google_sso.sh') + commit/push"
else
  step "re-seal Google SSO (skipped: .env creds empty)"
  warn "GOOGLE_SSO_CLIENT_ID/SECRET empty in .env -> skipping SSO re-seal (google-oauth stays orphaned until you set them + run 07)"
fi

# Split from 04_values (STEP 2): sealing needs the LIVE controller (up now), but 04_values runs before
# ArgoCD. Seals CLOUDFLARE_API_TOKEN_SECRET into cert-manager so the dns01 ClusterIssuer solver authenticates.
# Skipped if the .env token is empty (DNS-01 off; 04_values already forced the zones to []).
if [ -n "$CLOUDFLARE_API_TOKEN_SECRET" ]; then
  run_step "re-seal the Cloudflare DNS-01 API token" "$STEP_DIR" 04_cloudflare_token.sh best-effort \
    "04_cloudflare_token didn't complete; re-run it by hand ('make configure-cloudflare-token') + commit/push"
else
  step "re-seal Cloudflare DNS-01 token (skipped: .env token empty)"
fi

# Not guarded on a .env secret: 08 GENERATES its own webhook secret (into secrets/) and always runs. It
# seals webhook.github.secret into argocd-secret (patch-merge; 05 marked the live secret patch-managed) and
# writes timeout.reconciliation from .env POLL_SYNC_ENABLED. The GitHub webhook itself is a manual post-boot
# step (it needs public DNS + the prod cert); 08 prints the exact setup. See 02_gitops.md.
run_step "generate+seal the GitHub webhook secret + set poll cadence" "$STEP_DIR" 02b_argocd_webhook.sh best-effort \
  "02b_argocd_webhook didn't complete; re-run it by hand ('02b_argocd_webhook.sh') + commit/push"

# Needs NO cluster (pure AWS), but grouped here so the commit below carries any resulting state note. Skipped
# when the .env deployer creds are empty (backups off). Idempotent (terraform apply), so a re-run reconciles.
if [ -n "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
  run_step "Terraform: S3 backup bucket + scoped IAM writer" "$STEP_DIR" 10a_s3_backup_bucket.sh best-effort \
    "10a_s3_backup_bucket didn't complete; re-run it by hand ('make s3-backup-bucket')"
else
  step "S3 backup bucket (skipped: .env AWS creds empty)"
  warn "AWS_DEPLOY_ACCESS_KEY_ID empty in .env -> skipping S3 backups (no bucket; CNPG backups stay off)"
fi

# Needs the controller (STEP 5) + the Terraform outputs from STEP 9. Seals the writer creds into each CNPG
# namespace and flips backups on in the shared pg-cluster values; the commit below pushes both. Skipped when
# creds empty (kept paired with STEP 9 so neither runs half-configured).
if [ -n "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
  run_step "seal S3 creds per CNPG ns + enable backups in pg-cluster" "$STEP_DIR" 10b_cnpg_backup.sh best-effort \
    "10b_cnpg_backup didn't complete; re-run it by hand ('make configure-cnpg-backup') + commit/push"
else
  step "enable CNPG S3 backups (skipped: .env AWS creds empty)"
fi

# Needs the controller (STEP 5) + the Terraform outputs from STEP 9. Writes bucket/region into the central
# 07_redis_backup chart and seals ONE writer-creds secret into ns redis-backup; the commit below pushes both.
# Skipped when creds empty (kept paired with STEP 9/10 so nothing runs half-configured).
if [ -n "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
  run_step "enable central Redis S3 backups (seal creds + chart values)" "$STEP_DIR" 10c_redis_backup.sh best-effort \
    "10c_redis_backup didn't complete; re-run it by hand ('make configure-redis-backup') + commit/push"
else
  step "enable Redis S3 backups (skipped: .env AWS creds empty)"
fi

# Needs the controller (STEP 5) + the Terraform outputs from STEP 9. Seals the writer creds into
# longhorn-system and writes the backup target into the 02_longhorn values (which renders the -with-backups SC +
# RecurringJobs); the commit below pushes both. Skipped when creds empty (paired with STEP 9-11).
if [ -n "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
  run_step "enable Longhorn volume S3 backups (seal creds + backup target)" "$STEP_DIR" 10d_longhorn_backup.sh best-effort \
    "10d_longhorn_backup didn't complete; re-run it by hand ('make configure-longhorn-backup') + commit/push"
else
  step "enable Longhorn volume S3 backups (skipped: .env AWS creds empty)"
fi

# Needs the controller (STEP 5) + the Terraform outputs from STEP 9. Writes bucket/region into the central
# 08_vm_backup chart and seals ONE writer-creds secret into ns monitoring; the commit below pushes both.
# Skipped when creds empty (paired with STEP 9-12 so nothing runs half-configured).
if [ -n "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
  run_step "enable central VM/VL S3 backups (seal creds + chart values)" "$STEP_DIR" 10e_vm_backup.sh best-effort \
    "10e_vm_backup didn't complete; re-run it by hand ('make configure-vm-backup') + commit/push"
else
  step "enable VM/VL S3 backups (skipped: .env AWS creds empty)"
fi

step "git add + commit + push the re-sealed secrets + backup creds/values (ArgoCD unseals them; waves 2,4,7,8 + argocd)"
git add -A
if git diff --cached --quiet; then
  ok "nothing new to commit"
else
  git commit -m "$COMMIT_MSG_SEAL" >/dev/null && ok "committed re-sealed secrets" || warn "commit failed; commit + push by hand"
fi
git push || warn "push failed; push by hand so ArgoCD picks up the re-sealed secrets"

# The git poll is a 300s fallback and the GitHub webhook isn't configured yet, so ArgoCD won't pick up STEP
# 19's push (re-sealed google-oauth/argocd secrets + backup creds/values) on its own for up to ~5 min.
# converge_argocd_apps hard-refreshes EVERY app first (so they re-compare against the pushed commit and apply
# the re-sealed secrets now), then nudges any straggler to Synced+Healthy (unbounded per-app retry converges
# the rest on its own).
# Best-effort: never fails the bootstrap. ntfy (wave 5) is up once this returns, so STEP 16 can seed it.
step "converge ArgoCD (pull re-sealed secrets + self-heal backstop, up to ${CONVERGE_WAIT}s)"
converge_argocd_apps "$CONVERGE_WAIT" || true

# ntfy (05_ntfy, wave 5) is up now that STEP 15 converged the platform, so seed it: 06_ntfy_auth.sh execs the
# running pod to create the phone/grafana users + ACLs and seal Grafana's write token into grafana-ntfy. Then push
# it (so ArgoCD applies the SealedSecret) and restart Grafana to pick up GF_NTFY_TOKEN. Skipped when the .env
# password is empty. Best-effort: a slow/absent ntfy never wedges the run. See docs/06_monitoring.md.
if [ -n "$NTFY_PHONE_PASSWORD_SECRET" ]; then
  if run_step "seed ntfy users + seal Grafana's ntfy token" "$STEP_DIR" 06_ntfy_auth.sh best-effort \
       "06_ntfy_auth didn't complete; re-run 'make configure-ntfy-auth' + commit/push once ntfy is up"; then
    git add -A
    if git diff --cached --quiet; then ok "no ntfy token change to commit"; else
      git commit -m "bootstrap: seal Grafana ntfy token" >/dev/null && ok "committed sealed ntfy token" || warn "commit failed; commit by hand"
    fi
    git push || warn "push failed; push the sealed grafana-ntfy token by hand"
    converge_argocd_apps "$CONVERGE_WAIT" || true                                   # apply the pushed SealedSecret
    kubectl -n "$MONITORING_NS" rollout restart deploy/grafana >/dev/null 2>&1 \
      && ok "grafana restarted (picks up GF_NTFY_TOKEN)" || warn "restart grafana by hand to pick up GF_NTFY_TOKEN"
  fi
else
  step "seed ntfy auth (skipped: .env NTFY_PHONE_PASSWORD_SECRET empty)"
  warn "NTFY_PHONE_PASSWORD_SECRET empty in .env -> ntfy alerting off; set it + run 'make configure-ntfy-auth' later"
fi

# So a future DANGEROUS_rebuild_cluster.sh can RESTORE it instead of orphaning these SealedSecrets again.
run_step "back up the new sealed-secrets master key" "$STEP_DIR" 03_backup_sealed_secrets_key.sh best-effort \
  "key backup didn't complete; run 03_backup_sealed_secrets_key.sh by hand once the controller is up"

# ArgoCD brings up the ingress stack ASYNC after STEP 4 and HTTP-01 issuance takes minutes; verify_ingress
# (lib/shell/common.sh) polls each HTTPS host until it serves a REAL, LE-backed HTTPS response.
# Best-effort: warns, never fails the bootstrap.
step "verify ingress serving (LE cert + HTTPS response), up to ${INGRESS_WAIT}s"
verify_ingress "$INGRESS_GW_NS" "$INGRESS_WAIT" $INGRESS_HOSTS || true

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
