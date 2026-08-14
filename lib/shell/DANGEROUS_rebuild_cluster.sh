#!/usr/bin/env bash
# DANGEROUS: tears the platform down to bare Kubernetes and redelivers it. One confirmation, up front.
# It does NOT touch the nodes: wiping Talos itself is the OS repo's `make reset-cluster`.
#
# A rebuild is a FULL fresh start: it wipes local data AND the S3 backups, so the empty same-named clusters
# ArgoCD recreates begin a clean backup history with no old-vs-new systemID conflict. To keep the OLD data,
# restore BEFORE rebuilding.
#
# The sealed-secrets key is RESTORED, not re-sealed, so the committed SealedSecrets still decrypt. This script
# does NOT back the key up: doing that here would risk overwriting a good backup with the about-to-be-wiped
# cluster's key. Back up DELIBERATELY beforehand so the restore step has something to restore; with no backup
# it fails cleanly and you re-seal instead.
#
# The first steps abort on the first failure; the key restore onwards is best-effort.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
cd "$REPO_ROOT" || exit 1           # git ops below; set -e is off, so guard the cd

# ---- knobs ----
STEP=0; STEP_TOTAL=9                # common.sh step/run_step; bump TOTAL if you add or remove a step
STEP_DIR="$SCRIPT_DIR"              # every step script is a sibling of this orchestrator
RESTORE="${STEP_DIR}/03_restore_sealed_secrets_key.sh"
INGRESS_GW_NS="gateway"             # namespace of the shared Gateway
COMMIT_MSG="rebuild: sync working tree before cluster rebuild"
COMMIT_MSG_SYNC="rebuild: sync LB range written by 01_cilium"
INGRESS_WAIT=900                    # secs to wait for the ingress to actually serve (HTTP-01 is slow)
INGRESS_HOSTS=""                    # space-separated hosts to check; empty = derive from the Gateway's listeners
CONVERGE_SETTLE=120                 # secs to let ArgoCD create its apps + roll the early waves first
CONVERGE_WAIT=900                   # secs for the converge backstop to drive every app to Synced+Healthy

# ---- functions ----

check_prerequisites() {
  require git kubectl helm yq kubeseal
  [ -f "$RESTORE" ] || die "missing ${RESTORE}"
  # Pinned BEFORE the banner, so the confirmation names the context this redelivers onto and an unset or
  # typo'd KUBE_CONTEXT fails here rather than after you have typed the confirmation word. Cheap (a config
  # read); the reachability probe waits until after the commit+push.
  use_kubeconfig
}

confirm_rebuild() {
cat <<EOF

This will REDELIVER the entire platform onto the cluster KUBE_CONTEXT names in .env:
  context : ${KUBE_CONTEXT}
  config  : ${KUBECONFIG}
  flow  : commit+push -> 01 (CNI) -> commit+push -> 02a (ArgoCD) -> restore sealed-secrets key
          -> WIPE S3 backups -> converge -> seed ntfy -> verify ingress
          (ArgoCD redeploys cilium/cert-manager/longhorn/gateway/SSO/monitoring from git)
  note  : it WIPES the S3 backups, so the DBs come back EMPTY. If you want the old data, restore from S3
          BEFORE rebuilding (make restore-cnpg); a rebuild discards it.
  nodes : NOT touched. To wipe Talos itself, do that first in the OS repo:
          https://github.com/yama6a/talos-raspberry-pi5-cluster  ->  make reset-cluster && make bootstrap-cluster

Have a CURRENT sealed-secrets key backup (03_backup_sealed_secrets_key.sh), else SSO won't decrypt
until you re-seal (04_google_sso). ntfy alerting is seeded post-boot via 06_ntfy_auth regardless.
EOF
  confirm_word_always REBUILD || { echo "aborted (phew!)."; exit 0; }
}

commit_and_push_working_tree() {
  step "git add + commit + push"
  git add -A
  if git diff --cached --quiet; then
    ok "nothing new to commit"
  else
    git commit -m "$COMMIT_MSG" >/dev/null && ok "committed local changes" || die "git commit failed"
  fi
  git push || die "git push failed, ArgoCD deploys the REMOTE; push manually then re-run"
  ok "remote up to date"
}

# The nodes are the OS repo's to wipe. All this needs is a cluster that answers.
assert_cluster_exists() {
  local node_count
  say "precondition: the cluster exists and is reachable"
  assert_api
  node_count="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [ "${node_count:-0}" -gt 0 ] || die "no nodes found via context ${KUBE_CONTEXT} (${KUBECONFIG}).
       Wipe and rebuild the cluster first, in the OS repo:  https://github.com/yama6a/talos-raspberry-pi5-cluster
       there:  make reset-cluster && make bootstrap-cluster"
  ok "${node_count} node(s) reachable"
}

# 01_cilium writes the .env LB-IPAM range into 00_cilium's values.yaml, AFTER the commit above, and 02a
# refuses to hand off with argo_apps/ dirty. So sync again: a changed LB_RANGE_* is a real edit only this step
# can catch.
commit_and_push_lb_range() {
  step "git add + commit + push (01_cilium's LB range)"
  git add -A
  if git diff --cached --quiet; then
    ok "nothing new to commit"
  else
    git commit -m "$COMMIT_MSG_SYNC" >/dev/null && ok "committed the LB range" || die "git commit failed"
  fi
  git push || die "git push failed, ArgoCD deploys the REMOTE; push manually then resume from 02a_argocd.sh by hand"
  ok "remote up to date"
}

# Waits for the controller (ArgoCD wave 2), applies the backed-up key and restarts it, so the committed
# SealedSecrets decrypt. Fails cleanly (no backup, or the controller never came up) without wedging the rebuild.
restore_master_key() {
  run_step "restore the backed-up sealed-secrets master key" "$STEP_DIR" 03_restore_sealed_secrets_key.sh best-effort \
    "key restore didn't complete (see above), restore by hand once sealed-secrets is up, or re-seal (04_google_sso) + commit/push"
}

# A rebuild discards the local data, so discard the old backups too, else the fresh, same-named clusters would
# collide with the old backup history (systemID mismatch) and fail archiving. Runs right after the ArgoCD
# bootstrap, BEFORE the workloads and any new archiving come up. Pure AWS, best-effort.
# Not via run_step, which cannot pass the `wipe` arg. ASSUME_YES=1 so 10a does not re-prompt: the REBUILD
# confirmation already covers it.
wipe_s3_backups() {
  if [ -z "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
    step "wipe S3 backups (skipped: .env AWS creds empty)"
    return 0
  fi
  step "wipe the S3 backups (rebuild = fresh start; bucket + IAM kept)"
  if ASSUME_YES=1 bash "${STEP_DIR}/10a_s3_backup_bucket.sh" wipe </dev/null; then
    ok "S3 backups wiped"
  else
    warn "S3 wipe didn't complete; empty it by hand ('make s3-backup-wipe') before the new clusters archive"
  fi
}

# Real self-healing does the work: each app's syncPolicy.retry (limit:-1, refresh) re-drives a failed sync
# until its dependency lands, selfHeal + the poll re-examine, and the CNPG ObjectStore is a persistent
# resource (not a helm hook) so nothing wedges. This is the backstop: it hard-refreshes EVERY app so it
# re-compares against this rebuild's pushed commit and the key restore right away (the webhook is not up yet
# and the poll is 300s), then nudges stragglers. Settles first so the platform has created its apps.
# Best-effort; never fails the rebuild.
converge_apps() {
  use_kubeconfig                                 # needed by converge_argocd_apps
  step "let ArgoCD settle ${CONVERGE_SETTLE}s, then converge all apps to Synced+Healthy (backstop, up to ${CONVERGE_WAIT}s)"
  sleep "$CONVERGE_SETTLE"
  converge_argocd_apps "$CONVERGE_WAIT" || true
}

# Any OS-repo reset that preceded this wiped ntfy's Longhorn PVC, so ntfy came back with an EMPTY auth DB and
# the committed grafana-ntfy token is stale. 06_ntfy_auth re-creates the users + ACLs and mints and re-seals a
# FRESH token; push it (ArgoCD applies it) and restart Grafana to pick up GF_NTFY_TOKEN.
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
    git commit -m "rebuild: re-seal Grafana ntfy token" >/dev/null && ok "committed sealed ntfy token" || warn "commit failed; commit by hand"
  fi
  git push || warn "push failed; push the sealed grafana-ntfy token by hand"
  converge_argocd_apps "$CONVERGE_WAIT" || true                                   # apply the pushed SealedSecret
  kubectl -n "$MONITORING_NS" rollout restart deploy/grafana >/dev/null 2>&1 \
    && ok "grafana restarted (picks up GF_NTFY_TOKEN)" || warn "restart grafana by hand to pick up GF_NTFY_TOKEN"
}

# ArgoCD brings the ingress stack up (envoy-gateway -> gateway -> cert-manager -> apps) ASYNC after the ArgoCD
# bootstrap, and HTTP-01 issuance takes minutes, so a finished 02a does NOT mean the sites work yet.
# Best-effort: warns rather than failing the rebuild if it cannot confirm within INGRESS_WAIT.
verify_ingress_serving() {
  step "verify ingress serving (LE cert + HTTPS response), up to ${INGRESS_WAIT}s"
  verify_ingress "$INGRESS_GW_NS" "$INGRESS_WAIT" $INGRESS_HOSTS || true
}

print_handoff() {
cat <<EOF

=============== cluster rebuilt ===============
ArgoCD is bootstrapped and reconciling every app from git (cilium adopt, cert-manager, longhorn,
envoy-gateway, gateway, SSO, monitoring). Watch it:
  kubectl get applications -n argocd -w

Notes:
  - If the key restore (STEP 5) didn't run, do it once sealed-secrets is up
    (lib/shell/03_restore_sealed_secrets_key.sh), or re-seal with 04_google_sso and commit+push.
  - ntfy alerting: STEP 8 re-seeded it automatically (if NTFY_PHONE_PASSWORD_SECRET was set). If the nodes were
    reset first, ntfy's PVC went with them, so a fresh token was minted + re-sealed. If it was skipped/failed, run 'make configure-ntfy-auth'
    + commit/push + restart grafana. On your phone, re-subscribe 'cluster-alerts' at https://ntfy.ops.example.com.
  - FULL FRESH START: STEP 6 cleared the S3 backups, and any node reset you ran first cleared every volume.
    The DBs come back EMPTY and begin a clean backup history. If you wanted the old data, you had to restore
    BEFORE rebuilding (make restore-cnpg), because a rebuild discards it. The bucket + IAM stay; only
    \`make s3-backup-destroy\` tears those down. See docs/10_backups.md.
  - TLS certs re-issue via HTTP-01; first issuance takes a few minutes. If you've rebuilt repeatedly,
    validate hosts on letsencrypt-staging before flipping to prod (tight rate limits).
EOF
}

# ---- main ----

check_prerequisites
confirm_rebuild
commit_and_push_working_tree
assert_cluster_exists

run_step "CNI + monitoring CRDs + LB/L2 + Hubble" "$STEP_DIR" 01_cilium.sh
commit_and_push_lb_range
run_step "bootstrap ArgoCD; it deploys the rest from git" "$STEP_DIR" 02a_argocd.sh

restore_master_key
wipe_s3_backups
converge_apps
seed_ntfy_and_push_token
verify_ingress_serving
print_handoff
