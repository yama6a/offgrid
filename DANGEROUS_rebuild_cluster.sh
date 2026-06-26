#!/usr/bin/env bash
#
# DANGEROUS_rebuild_cluster.sh
#
# One-shot orchestrator: wipe the cluster and rebuild it end-to-end so you don't run the steps by hand.
# Sequence (one confirmation, up front):
#   0. git add/commit/push              — ArgoCD deploys the REMOTE repo, not your laptop, so sync it first
#   1. DANGEROUS_reset_talos_cluster.sh — wipe STATE+EPHEMERAL+u-longhorn, reboot to maintenance
#   2. 03d_talos_cluster_config.sh      — WAITS for maintenance, applies config, bootstraps etcd
#   3. 03e_nic_hardening.sh             — NIC hardening (EEE/watchdog)
#   4. 04_cilium.sh                     — CNI + prometheus-operator CRDs + LB-IPAM/L2 + Hubble
#   5. 05_argocd.sh                     — bootstrap ArgoCD; it then deploys everything else from git
#   6. 07_restore_sealed_secrets_key.sh — restore the master key so committed SealedSecrets decrypt
#
# Skips 03a/03b/03c (image build/flash/boot-verify): a reset keeps BOOT/EFI/META, so the OS is already on
# the NVMe — no reflash. 03d waits for maintenance itself. Bootstrap steps (1-5) abort on the first
# failure; the git + restore steps (0,6) are best-effort with printed fallbacks so a slow ArgoCD never
# wedges the rebuild.
#
# This script does NOT back up the sealed-secrets key — doing it here would risk overwriting a good
# backup with the about-to-be-wiped cluster's key. Back up DELIBERATELY beforehand
# (07_sealed_secrets/07_backup_sealed_secrets_key.sh) so step 6 has something to restore; with no backup,
# step 6 fails cleanly and you re-seal instead (12_google_sso, 15_monitoring) + commit/push.
#
# Needs Docker (host networking), git, kubectl.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"   # the reset script cd's into ./03_operating_system relative to here

# ---- knobs ------------------------------------------------------------------
RESET="${RESET:-${SCRIPT_DIR}/DANGEROUS_reset_talos_cluster.sh}"
RESTORE="${RESTORE:-${SCRIPT_DIR}/07_sealed_secrets/07_restore_sealed_secrets_key.sh}"
STEP_03_DIR="${STEP_03_DIR:-${SCRIPT_DIR}/03_operating_system}"
STEP_04_DIR="${STEP_04_DIR:-${SCRIPT_DIR}/04_networking}"
STEP_05_DIR="${STEP_05_DIR:-${SCRIPT_DIR}/05_gitops}"
CONFIG_FILE="${CONFIG_FILE:-${STEP_03_DIR}/03_config.sh}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-${STEP_03_DIR}/talos-cluster/kubeconfig}"
COMMIT_MSG="${COMMIT_MSG:-rebuild: sync working tree before cluster rebuild}"
# -----------------------------------------------------------------------------

say()  { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
warn() { printf '  \033[33m[warn]\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m[ok]\033[0m %s\n' "$*"; }

# === prereqs =================================================================
command -v docker  >/dev/null || die "docker not found on PATH (and it needs host networking enabled)"
command -v git     >/dev/null || die "git not found on PATH"
command -v kubectl >/dev/null || die "kubectl not found on PATH"
[ -f "$RESET" ]       || die "missing ${RESET}"
[ -f "$RESTORE" ]     || die "missing ${RESTORE}"
[ -f "$CONFIG_FILE" ] || die "missing ${CONFIG_FILE}"
# shellcheck source=03_operating_system/03_config.sh
source "$CONFIG_FILE"
IPS=(); for e in "${CLUSTER_NODES[@]}"; do IPS+=("${e##*:}"); done

# === confirm (the ONLY destructive prompt — the reset's own prompt is auto-answered) ===
cat <<EOF

This will DESTROY and REBUILD the entire Talos cluster:
  nodes : ${IPS[*]}
  wipe  : STATE + EPHEMERAL + u-longhorn  (ALL k8s state AND all Longhorn/PVC data — gone for good)
  flow  : commit+push -> reset -> 03d -> 03e -> 04 -> 05 -> restore sealed-secrets key
          (ArgoCD then redeploys cilium/cert-manager/longhorn/gateway/SSO/monitoring from git)

Have a CURRENT sealed-secrets key backup (07_backup_sealed_secrets_key.sh) — else SSO + Alertmanager
email won't decrypt until you re-seal (12_google_sso, 15_monitoring).
EOF
read -r -p ">> type REBUILD to proceed: " ans
[ "$ans" = "REBUILD" ] || { echo "aborted (phew!)."; exit 0; }

# === STEP 0. commit + push (ArgoCD deploys the remote, not your working tree) ==
say "STEP 0/6 — git add + commit + push"
git add -A
if git diff --cached --quiet; then
  ok "nothing new to commit"
else
  git commit -m "$COMMIT_MSG" >/dev/null && ok "committed local changes" || die "git commit failed"
fi
git push || die "git push failed — ArgoCD deploys the REMOTE; push manually then re-run"
ok "remote up to date"

# === STEP 1. reset to maintenance ============================================
say "STEP 1/6 — reset to maintenance (DANGEROUS_reset_talos_cluster.sh)"
printf 'YES\n' | bash "$RESET" || die "reset failed"
ok "reset issued"

# === STEP 2-5. bootstrap (each in its own dir; 03d waits for maintenance; abort on first failure) ===
say "STEP 2/6 — 03d_talos_cluster_config.sh (waits for maintenance, applies config, bootstraps etcd)"
( cd "$STEP_03_DIR" && bash ./03d_talos_cluster_config.sh ) || die "03d failed — fix and resume from 03d by hand"
ok "03d done"

say "STEP 3/6 — 03e_nic_hardening.sh"
( cd "$STEP_03_DIR" && bash ./03e_nic_hardening.sh ) || die "03e failed — fix and resume from 03e by hand"
ok "03e done"

say "STEP 4/6 — 04_cilium.sh (CNI + monitoring CRDs + LB/L2 + Hubble)"
( cd "$STEP_04_DIR" && bash ./04_cilium.sh ) || die "04_cilium failed — fix and resume from 04 by hand"
ok "04_cilium done"

say "STEP 5/6 — 05_argocd.sh (bootstrap ArgoCD; it deploys the rest from git)"
( cd "$STEP_05_DIR" && bash ./05_argocd.sh ) || die "05_argocd failed — fix and resume from 05 by hand"
ok "05_argocd done"

# === STEP 6. restore the sealed-secrets key (best-effort, non-fatal) =========
# Waits for the controller (ArgoCD wave 2), applies the backed-up key + restarts it, so the committed
# SealedSecrets decrypt. Fails cleanly (no backup / controller never came up) without wedging the rebuild.
say "STEP 6/6 — restore sealed-secrets key (07_restore_sealed_secrets_key.sh)"
bash "$RESTORE" || warn "key restore didn't complete (see above) — restore by hand once sealed-secrets is up, or re-seal (12/15) + commit/push"

# === summary =================================================================
cat <<EOF

=============== cluster rebuilt ===============
ArgoCD is bootstrapped and reconciling every app from git (cilium adopt, cert-manager, longhorn,
envoy-gateway, gateway, SSO, monitoring). Watch it:
  KUBECONFIG=${KUBECONFIG_FILE} kubectl get applications -n argocd -w

Notes:
  - If the key restore (STEP 6) didn't run, do it once sealed-secrets is up
    (./07_sealed_secrets/07_restore_sealed_secrets_key.sh), or re-seal with 12_google_sso +
    15_monitoring and commit+push.
  - TLS certs re-issue via HTTP-01; first issuance takes a few minutes. If you've rebuilt repeatedly,
    validate hosts on letsencrypt-staging before flipping to prod (tight rate limits).
EOF
