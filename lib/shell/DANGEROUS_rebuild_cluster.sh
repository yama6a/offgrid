#!/usr/bin/env bash
# One-shot orchestrator: wipe the cluster and rebuild it end to end. One confirmation, up front.
#
# Sequence:
#   0. git add/commit/push             : ArgoCD deploys the REMOTE repo, not your laptop, so sync it first
#   1. DANGEROUS_reset_talos_cluster.sh: wipe STATE+EPHEMERAL+u-longhorn, reboot to maintenance
#   2. 03c_talos_cluster_config.sh     : wait for maintenance, apply config, bootstrap etcd
#   3. 03d_nic_hardening.sh            : NIC hardening
#   4. 04_cilium.sh                    : CNI + prometheus-operator CRDs + LB-IPAM/L2 + Hubble
#   5. git add/commit/push             : 04 wrote the LB range into the chart values; 05 refuses a dirty argo_apps/
#   6. 05_argocd.sh                    : bootstrap ArgoCD, which then deploys everything else from git
#   7. 06_restore_sealed_secrets_key.sh: restore the master key so committed SealedSecrets decrypt
#   8. 13_s3_backup_bucket.sh wipe     : DELETE all backups in the bucket, keeping the bucket and IAM
#   9. converge argocd apps            : settle, then drive every app to Synced+Healthy
#  10. 10_ntfy_auth.sh                 : seed ntfy users, seal Grafana's token, push, restart grafana
#  11. verify ingress serving          : wait until each HTTPS host serves an LE cert
#
# A rebuild is a FULL fresh start: it wipes local data AND the S3 backups, so the empty same-named clusters
# ArgoCD recreates begin a clean backup history with no old-vs-new systemID conflict. To keep the OLD data,
# restore BEFORE rebuilding.
# We RESTORE the sealed-secrets key rather than re-seal, so the committed backup SealedSecrets still decrypt.
#
# This script does NOT back up the key: doing it here would risk overwriting a good backup with the
# about-to-be-wiped cluster's key. Back up DELIBERATELY beforehand so step 7 has something to restore. With
# no backup, step 7 fails cleanly and you re-seal instead.
#
# Skips 03a/03b: a reset keeps BOOT/EFI/META, so the OS is already on the NVMe and 03c waits for
# maintenance itself. Steps 0-6 abort on the first failure; 7 onwards are best-effort.
#
# Needs Docker (host networking), git, kubectl.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"   # say/die/warn/ok + CLUSTER_DIR + the inventory node arrays + REPO_ROOT
cd "$REPO_ROOT" || exit 1           # run from the repo root (git ops); set -e is off, so guard cd

# ---- knobs ------------------------------------------------------------------
STEP=0; STEP_TOTAL=12                           # shared step counter (common.sh step/run_step); bump TOTAL if you add/remove a step
STEP_DIR="$SCRIPT_DIR"                          # every step script (+ the reset script) is a sibling of this orchestrator in lib/shell/
RESET="${STEP_DIR}/DANGEROUS_reset_talos_cluster.sh"
RESTORE="${STEP_DIR}/06_restore_sealed_secrets_key.sh"
KUBECONFIG_FILE="${CLUSTER_DIR}/kubeconfig"
INGRESS_GW_NS="gateway"                        # namespace of the shared Gateway
# operational knobs for this orchestrator:
COMMIT_MSG="rebuild: sync working tree before cluster rebuild"
COMMIT_MSG_SYNC="rebuild: sync LB range written by 04_cilium"
INGRESS_WAIT=900                               # max secs to wait for the ingress to actually serve (HTTP-01 issuance is slow)
INGRESS_HOSTS=""                               # space-separated hosts to check; empty = derive from the Gateway's HTTPS listeners
CONVERGE_SETTLE=120                            # secs to let ArgoCD create its apps + roll the early waves before the backstop kicks in
CONVERGE_WAIT=900                              # max secs for the converge backstop to drive every app to Synced+Healthy

require docker git kubectl
[ -f "$RESET" ]   || die "missing ${RESET}"
[ -f "$RESTORE" ] || die "missing ${RESTORE}"
IPS=("${ALL_IPS[@]}")   # workers included: the reset wipes them and 03c reconfigures them in the same pass

cat <<EOF

This will DESTROY and REBUILD the entire Talos cluster:
  nodes : ${IPS[*]}
  wipe  : STATE + EPHEMERAL + u-longhorn  (ALL k8s state AND every Longhorn volume, gone for good)
  flow  : commit+push -> reset -> 03c -> 03d -> 04 -> commit+push -> 05 -> restore sealed-secrets key -> WIPE S3 backups -> seed ntfy
          (ArgoCD then redeploys cilium/cert-manager/longhorn/gateway/SSO/monitoring from git)
  note  : FULL fresh start, wipes the CNPG volumes AND the S3 backups. The DBs come back EMPTY. If you want
          the old data, restore from S3 BEFORE rebuilding (make restore-cnpg); a rebuild discards it.

Have a CURRENT sealed-secrets key backup (06_backup_sealed_secrets_key.sh), else SSO won't decrypt
until you re-seal (07_google_sso). ntfy alerting is seeded post-boot via 10_ntfy_auth regardless.
EOF
read -r -p ">> type REBUILD to proceed: " ans
[ "$ans" = "REBUILD" ] || { echo "aborted (phew!)."; exit 0; }

step "git add + commit + push"
git add -A
if git diff --cached --quiet; then
  ok "nothing new to commit"
else
  git commit -m "$COMMIT_MSG" >/dev/null && ok "committed local changes" || die "git commit failed"
fi
git push || die "git push failed, ArgoCD deploys the REMOTE; push manually then re-run"
ok "remote up to date"

# REBUILD_IN_PROGRESS=1 tells the reset script to SKIP its S3 teardown (terraform destroy): a rebuild keeps
# the bucket + IAM and only wipes the backup CONTENTS (STEP 9). Only `make reset-cluster` (standalone) destroys
# the S3 infrastructure.
step "reset to maintenance (DANGEROUS_reset_talos_cluster.sh)"
printf 'YES\n' | REBUILD_IN_PROGRESS=1 bash "$RESET" || die "reset failed"
ok "reset issued"

run_step "waits for maintenance, applies config, bootstraps etcd" "$STEP_DIR" 03c_talos_cluster_config.sh
run_step "NIC hardening (EEE/watchdog)"                            "$STEP_DIR" 03d_nic_hardening.sh
run_step "CNI + monitoring CRDs + LB/L2 + Hubble"                 "$STEP_DIR" 04_cilium.sh

# 04_cilium writes the .env LB-IPAM range into 00_cilium's values.yaml, AFTER the commit above, and 05 refuses
# to hand off with argo_apps/ dirty. So sync again here: a changed LB_RANGE_* is a real edit only this step can
# catch. Same step the bootstrap orchestrator runs between 04/07 and 05.
step "git add + commit + push (04_cilium's LB range)"
git add -A
if git diff --cached --quiet; then
  ok "nothing new to commit"
else
  git commit -m "$COMMIT_MSG_SYNC" >/dev/null && ok "committed the LB range" || die "git commit failed"
fi
git push || die "git push failed, ArgoCD deploys the REMOTE; push manually then resume from 05 by hand"
ok "remote up to date"

run_step "bootstrap ArgoCD; it deploys the rest from git"         "$STEP_DIR" 05_argocd.sh

# Waits for the controller (ArgoCD wave 2), applies the backed-up key + restarts it, so the committed
# SealedSecrets decrypt. Fails cleanly (no backup / controller never came up) without wedging the rebuild.
run_step "restore the backed-up sealed-secrets master key" "$STEP_DIR" 06_restore_sealed_secrets_key.sh best-effort \
  "key restore didn't complete (see above), restore by hand once sealed-secrets is up, or re-seal (07/09) + commit/push"

# A rebuild discards the local data, so discard the old backups too, else the fresh, same-named clusters
# would collide with the old backup history (systemID mismatch) and fail archiving. Runs right after the
# ArgoCD bootstrap, BEFORE the workloads (and any new archiving) come up. Pure AWS, best-effort. Not via
# run_step (which can't pass the `wipe` arg); ASSUME_YES=1 so 13 doesn't re-prompt (the REBUILD confirm covers it).
if [ -n "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
  step "wipe the S3 backups (rebuild = fresh start; bucket + IAM kept)"
  if ASSUME_YES=1 bash "${STEP_DIR}/13_s3_backup_bucket.sh" wipe </dev/null; then
    ok "S3 backups wiped"
  else
    warn "S3 wipe didn't complete; empty it by hand ('make s3-backup-wipe') before the new clusters archive"
  fi
else
  step "wipe S3 backups (skipped: .env AWS creds empty)"
fi

# Real self-healing does the work: each app's syncPolicy.retry (limit:-1, refresh) re-drives a failed sync
# until its dependency lands (a workload that raced ahead of the platform just retries until the CRD exists),
# selfHeal + the poll re-examine, and the CNPG ObjectStore is a persistent resource (not a helm hook) so
# nothing wedges. The converge step is the bootstrap backstop: it hard-refreshes EVERY app so it re-compares
# against this rebuild's pushed commit + the STEP-7 key restore right away (the webhook isn't up yet, the poll
# is 300s), and nudges any straggler to Synced+Healthy. Settle first so the platform has created its apps.
# Best-effort; never fails the rebuild. See 05_gitops.md.
export KUBECONFIG="$KUBECONFIG_FILE"           # 03c regenerated it above; needed by converge_argocd_apps
step "let ArgoCD settle ${CONVERGE_SETTLE}s, then converge all apps to Synced+Healthy (backstop, up to ${CONVERGE_WAIT}s)"
sleep "$CONVERGE_SETTLE"
converge_argocd_apps "$CONVERGE_WAIT" || true

# The reset wiped ntfy's Longhorn PVC, so ntfy came back with an EMPTY auth DB and the committed grafana-ntfy
# token is stale. 10_ntfy_auth.sh re-creates the phone/grafana users + ACLs and mints + re-seals a FRESH token;
# push it (ArgoCD applies it) and restart Grafana to pick up GF_NTFY_TOKEN. Skipped when the .env password is
# empty. Best-effort. See docs/09_monitoring.md.
if [ -n "$NTFY_PHONE_PASSWORD_SECRET" ]; then
  if run_step "seed ntfy users + seal Grafana's ntfy token" "$STEP_DIR" 10_ntfy_auth.sh best-effort \
       "10_ntfy_auth didn't complete; re-run 'make configure-ntfy-auth' + commit/push once ntfy is up"; then
    git add -A
    if git diff --cached --quiet; then ok "no ntfy token change to commit"; else
      git commit -m "rebuild: re-seal Grafana ntfy token" >/dev/null && ok "committed sealed ntfy token" || warn "commit failed; commit by hand"
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

# ArgoCD brings up the ingress stack (envoy-gateway -> gateway -> cert-manager -> apps) ASYNC after the
# ArgoCD bootstrap, and HTTP-01 issuance takes minutes, so "05 done" does NOT mean the sites work yet.
# verify_ingress (lib/shell/common.sh) polls each HTTPS host until it serves a REAL, LE-backed HTTPS
# response. Best-effort: warns (does not fail the rebuild) if it can't confirm within INGRESS_WAIT.
step "verify ingress serving (LE cert + HTTPS response), up to ${INGRESS_WAIT}s"
verify_ingress "$INGRESS_GW_NS" "$INGRESS_WAIT" $INGRESS_HOSTS || true

cat <<EOF

=============== cluster rebuilt ===============
ArgoCD is bootstrapped and reconciling every app from git (cilium adopt, cert-manager, longhorn,
envoy-gateway, gateway, SSO, monitoring). Watch it:
  KUBECONFIG=${KUBECONFIG_FILE} kubectl get applications -n argocd -w

Notes:
  - If the key restore (STEP 8) didn't run, do it once sealed-secrets is up
    (lib/shell/06_restore_sealed_secrets_key.sh), or re-seal with 07_google_sso and commit+push.
  - ntfy alerting: STEP 11 re-seeded it automatically (if NTFY_PHONE_PASSWORD_SECRET was set). The reset wiped
    ntfy's PVC, so a fresh token was minted + re-sealed. If it was skipped/failed, run 'make configure-ntfy-auth'
    + commit/push + restart grafana. On your phone, re-subscribe 'cluster-alerts' at https://ntfy.ops.example.com.
  - FULL FRESH START: the wipe cleared every volume AND the S3 backups (STEP 9). The DBs come back EMPTY and
    begin a clean backup history. If you wanted the old data, you had to restore BEFORE rebuilding
    (make restore-cnpg) first, because a rebuild discards it. The bucket + IAM stay; only \`make reset-cluster\` destroys them.
    See docs/13_backups.md.
  - TLS certs re-issue via HTTP-01; first issuance takes a few minutes. If you've rebuilt repeatedly,
    validate hosts on letsencrypt-staging before flipping to prod (tight rate limits).
EOF
