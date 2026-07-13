#!/usr/bin/env bash
#
# DANGEROUS_rebuild_cluster.sh
#
# One-shot orchestrator: wipe the cluster and rebuild it end-to-end so you don't run the steps by hand.
# Sequence (one confirmation, up front):
#   0. git add/commit/push             : ArgoCD deploys the REMOTE repo, not your laptop, so sync it first
#   1. DANGEROUS_reset_talos_cluster.sh, wipe STATE+EPHEMERAL+u-longhorn+u-cnpg, reboot to maintenance
#   2. 03d_talos_cluster_config.sh     : WAITS for maintenance, applies config, bootstraps etcd
#   3. 03e_nic_hardening.sh            : NIC hardening (EEE/watchdog)
#   4. 04_cilium.sh                    : CNI + prometheus-operator CRDs + LB-IPAM/L2 + Hubble
#   5. 05_argocd.sh                    : bootstrap ArgoCD; it then deploys everything else from git
#   6. 06_restore_sealed_secrets_key.sh, restore the master key so committed SealedSecrets decrypt
#   7. 13_s3_backup_bucket.sh wipe     : DELETE all backups in the S3 bucket (keep the bucket/IAM; no terraform)
#   8. verify ingress serving          : wait until each HTTPS host serves an LE cert over clean HTTP/2
#
# A rebuild is a FULL fresh start: it wipes local CNPG data AND the S3 backups (step 7), so the empty,
# same-named clusters ArgoCD recreates begin a CLEAN backup history (no old-vs-new systemID conflict). The
# bucket + IAM stay (no terraform destroy — that's `make reset-cluster`). We RESTORE the sealed-secrets key
# (step 6) rather than re-seal, so the committed CNPG-backup SealedSecret still decrypts — no 14_cnpg_backup
# re-seal needed. If you want the OLD data back, restore BEFORE rebuilding — a rebuild discards it.
#
# Skips 03a/03b/03c (image build/flash/boot-verify): a reset keeps BOOT/EFI/META, so the OS is already on
# the NVMe, no reflash. 03d waits for maintenance itself. Bootstrap steps (1-5) abort on the first
# failure; the git + restore + bucket steps (0,6,7) are best-effort with printed fallbacks so a slow ArgoCD
# never wedges the rebuild.
#
# This script does NOT back up the sealed-secrets key, doing it here would risk overwriting a good
# backup with the about-to-be-wiped cluster's key. Back up DELIBERATELY beforehand
# (lib/shell/06_backup_sealed_secrets_key.sh) so step 6 has something to restore; with no backup,
# step 6 fails cleanly and you re-seal instead (07_google_sso, 09_grafana_smtp) + commit/push.
#
# Needs Docker (host networking), git, kubectl.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"   # say/die/warn/ok + CLUSTER_DIR + CLUSTER_NODES from .env + REPO_ROOT
cd "$REPO_ROOT"                     # run from the repo root (git ops)

# ---- knobs ------------------------------------------------------------------
STEP=0; STEP_TOTAL=9                            # shared step counter (common.sh step/run_step); bump TOTAL if you add/remove a step
STEP_DIR="$SCRIPT_DIR"                          # every step script (+ the reset script) is a sibling of this orchestrator in lib/shell/
RESET="${STEP_DIR}/DANGEROUS_reset_talos_cluster.sh"
RESTORE="${STEP_DIR}/06_restore_sealed_secrets_key.sh"
KUBECONFIG_FILE="${CLUSTER_DIR}/kubeconfig"
INGRESS_GW_NS="gateway"                        # namespace of the shared Gateway
# operational knobs for this orchestrator:
COMMIT_MSG="rebuild: sync working tree before cluster rebuild"
INGRESS_WAIT=900                               # max secs to wait for the ingress to actually serve (HTTP-01 issuance is slow)
INGRESS_HOSTS=""                               # space-separated hosts to check; empty = derive from the Gateway's HTTPS listeners
# -----------------------------------------------------------------------------

# === prereqs =================================================================
require docker git kubectl
[ -f "$RESET" ]   || die "missing ${RESET}"
[ -f "$RESTORE" ] || die "missing ${RESTORE}"
IPS=(); for e in "${CLUSTER_NODES[@]}"; do IPS+=("${e##*:}"); done

# === confirm (the ONLY destructive prompt, the reset's own prompt is auto-answered) ===
cat <<EOF

This will DESTROY and REBUILD the entire Talos cluster:
  nodes : ${IPS[*]}
  wipe  : STATE + EPHEMERAL + u-longhorn + u-cnpg  (ALL k8s state AND all Longhorn + local-path data, gone for good)
  flow  : commit+push -> reset -> 03d -> 03e -> 04 -> 05 -> restore sealed-secrets key -> WIPE S3 backups
          (ArgoCD then redeploys cilium/cert-manager/longhorn/gateway/SSO/monitoring from git)
  note  : FULL fresh start — wipes local CNPG data AND the S3 backups. The DBs come back EMPTY. If you want
          the old data, restore from S3 BEFORE rebuilding (make restore-cnpg); a rebuild discards it.

Have a CURRENT sealed-secrets key backup (06_backup_sealed_secrets_key.sh), else SSO + Grafana
email won't decrypt until you re-seal (07_google_sso, 09_grafana_smtp).
EOF
read -r -p ">> type REBUILD to proceed: " ans
[ "$ans" = "REBUILD" ] || { echo "aborted (phew!)."; exit 0; }

# === STEP 1. commit + push (ArgoCD deploys the remote, not your working tree) ==
step "git add + commit + push"
git add -A
if git diff --cached --quiet; then
  ok "nothing new to commit"
else
  git commit -m "$COMMIT_MSG" >/dev/null && ok "committed local changes" || die "git commit failed"
fi
git push || die "git push failed, ArgoCD deploys the REMOTE; push manually then re-run"
ok "remote up to date"

# === STEP 2. reset to maintenance ============================================
# REBUILD_IN_PROGRESS=1 tells the reset script to SKIP its S3 teardown (terraform destroy): a rebuild keeps
# the bucket + IAM and only wipes the backup CONTENTS (STEP 8). Only `make reset-cluster` (standalone) destroys
# the S3 infrastructure.
step "reset to maintenance (DANGEROUS_reset_talos_cluster.sh)"
printf 'YES\n' | REBUILD_IN_PROGRESS=1 bash "$RESET" || die "reset failed"
ok "reset issued"

# === STEP 3-6. bootstrap (each in its own dir; 03d waits for maintenance; abort on first failure) ===
run_step "waits for maintenance, applies config, bootstraps etcd" "$STEP_DIR" 03d_talos_cluster_config.sh
run_step "NIC hardening (EEE/watchdog)"                            "$STEP_DIR" 03e_nic_hardening.sh
run_step "CNI + monitoring CRDs + LB/L2 + Hubble"                 "$STEP_DIR" 04_cilium.sh
run_step "bootstrap ArgoCD; it deploys the rest from git"         "$STEP_DIR" 05_argocd.sh

# === STEP 7. restore the sealed-secrets key (best-effort, non-fatal) =========
# Waits for the controller (ArgoCD wave 2), applies the backed-up key + restarts it, so the committed
# SealedSecrets decrypt. Fails cleanly (no backup / controller never came up) without wedging the rebuild.
run_step "restore the backed-up sealed-secrets master key" "$STEP_DIR" 06_restore_sealed_secrets_key.sh best-effort \
  "key restore didn't complete (see above), restore by hand once sealed-secrets is up, or re-seal (07/09) + commit/push"

# === STEP 8. wipe the S3 backups (fresh start; keep the bucket + IAM) =========
# A rebuild discards the local data, so discard the old backups too — else the fresh, same-named clusters
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

# === STEP 9. verify the ingress data path actually serves (best-effort) =======
# ArgoCD brings up the ingress stack (envoy-gateway -> gateway -> cert-manager -> apps) ASYNC after the
# ArgoCD bootstrap, and HTTP-01 issuance takes minutes, so "05 done" does NOT mean the sites work yet.
# verify_ingress (lib/shell/common.sh) polls each HTTPS host until it serves a REAL, LE-backed response over
# clean HTTP/2. Best-effort: warns (does not fail the rebuild) if it can't confirm within INGRESS_WAIT.
step "verify ingress serving (LE cert + clean HTTP/2), up to ${INGRESS_WAIT}s"
verify_ingress "$INGRESS_GW_NS" "$INGRESS_WAIT" $INGRESS_HOSTS || true

# === summary =================================================================
cat <<EOF

=============== cluster rebuilt ===============
ArgoCD is bootstrapped and reconciling every app from git (cilium adopt, cert-manager, longhorn,
envoy-gateway, gateway, SSO, monitoring). Watch it:
  KUBECONFIG=${KUBECONFIG_FILE} kubectl get applications -n argocd -w

Notes:
  - If the key restore (STEP 7) didn't run, do it once sealed-secrets is up
    (lib/shell/06_restore_sealed_secrets_key.sh), or re-seal with 07_google_sso +
    09_grafana_smtp and commit+push.
  - FULL FRESH START: the wipe cleared local-path AND the S3 backups (STEP 8). The DBs come back EMPTY and
    begin a clean backup history. If you wanted the old data, you had to restore BEFORE rebuilding
    (make restore-cnpg) — a rebuild discards it. The bucket + IAM stay; only `make reset-cluster` destroys them.
    See docs/13_backups.md.
  - TLS certs re-issue via HTTP-01; first issuance takes a few minutes. If you've rebuilt repeatedly,
    validate hosts on letsencrypt-staging before flipping to prod (tight rate limits).
EOF
