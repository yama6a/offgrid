#!/usr/bin/env bash
#
# DANGEROUS_bootstrap_cluster.sh
#
# One-shot orchestrator for a FIRST-TIME cluster init (contrast DANGEROUS_rebuild_cluster.sh, which wipes
# a RUNNING cluster and reuses preserved state). This assumes freshly-flashed nodes (03a/03b done) sitting
# in MAINTENANCE mode — it runs 03c (boot-verify) itself as an up-front gate — and takes them from there to
# a fully delivered cluster. One confirmation up front, non-interactive after that.
# Sequence (STEP N/19):
#   1. maintenance preflight        : every node must answer the INSECURE (maintenance) API — fast-fail
#                                      if any is already configured (that's a rebuild, not a bootstrap)
#   2. 03c_talos_boot_verify.sh     : deep per-node verify (our image/Talos version + rpi5 overlay, NVMe,
#                                      wired NIC) — a hard gate BEFORE we archive creds / mint PKI
#   3. archive local creds          : mv secrets.yaml/kubeconfig/talosconfig/sealed-secrets-master.key +
#                                      03d scratch into secrets/backup_<ts>/ so 03d mints a NEW PKI
#   4. 03d_talos_cluster_config.sh  : generate fresh config, apply, bootstrap etcd, write kube/talosconfig
#   5. 03e_nic_hardening.sh         : NIC hardening (EEE/watchdog)
#   6. 04_cilium.sh                 : CNI + prometheus-operator CRDs + LB-IPAM/L2 + Hubble
#   7. 07_gateway.sh                : write LE_EMAIL/BASE_DOMAIN into the gateway chart values (no cluster)
#   8. git add/commit/push          : 05 refuses a dirty argo_apps/ tree; ArgoCD deploys the REMOTE
#   9. 05_argocd.sh                 : bootstrap ArgoCD; it then delivers the whole platform from git
#  10. wait sealed-secrets ctrl     : ArgoCD wave-2 app; kubeseal (steps 11-13, 15, 18) needs it up
#  11. 07_google_sso.sh </dev/null  : write shared clientID + RE-SEAL google-oauth against the NEW key
#  12. 09_grafana_smtp.sh           : RE-SEAL grafana-smtp against the NEW key
#  13. 08_argocd_webhook.sh         : generate+seal the GitHub webhook secret (-> secrets/) + set poll cadence
#  14. 13_s3_backup_bucket.sh       : Terraform -> S3 backup bucket + scoped IAM writer (skipped if .env AWS creds empty)
#  15. 14_cnpg_backup.sh            : seal the writer creds per CNPG ns + enable backups in the pg-cluster values
#  16. git add/commit/push          : push the re-sealed SealedSecrets + CNPG backup creds/values (waves 4 & 7 + argocd)
#  17. hard-refresh argocd apps     : poll is a slow fallback now, so nudge ArgoCD to pull the just-pushed commit
#  18. 06_backup_sealed_secrets_key.sh : back up the NEW master key so a future rebuild can restore it
#  19. verify ingress serving       : wait until each HTTPS host serves an LE cert over clean HTTP/2
#
# Why re-seal + back up (and a rebuild doesn't): a fresh controller mints a BRAND-NEW master key, so the
# two committed SealedSecrets (google-oauth, grafana-smtp, sealed against an OLD key) are orphaned — they
# must be re-sealed against the new key. The rebuild instead RESTORES the old key (06_restore) and skips
# re-sealing. Here there is no old key to restore, so we re-seal and then back the new key up.
#
# Skips 03a/03b (image build/flash): bootstrap assumes the OS is already flashed and the nodes are in
# maintenance, but it DOES run 03c (boot-verify) as a hard gate up front. Bootstrap steps (1-10) abort on
# the first failure with a resume hint; the re-seal/backup/verify steps (11-19) are best-effort so a slow
# ArgoCD never wedges the run.
#
# FIRST-TIME semantics: archiving secrets.yaml makes 03d mint a NEW Talos CA — the archived
# talosconfig/kubeconfig stop working (they're kept under backup_<ts>/). This is intended for a genuine
# from-scratch init. To re-initialize a RUNNING cluster, use DANGEROUS_rebuild_cluster.sh (it wipes first).
#
# Needs Docker (host networking), git, kubectl, helm, yq, kubeseal.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"   # say/die/warn/ok + CLUSTER_DIR + CLUSTER_NODES + secret .env keys + REPO_ROOT
cd "$REPO_ROOT"                     # run from the repo root (git ops, relative hints)

# ---- knobs ------------------------------------------------------------------
STEP=0; STEP_TOTAL=19                          # shared step counter (common.sh step/run_step); bump TOTAL if you add/remove a step
STEP_DIR="$SCRIPT_DIR"                          # every step script is a sibling of this orchestrator in lib/shell/
KUBECONFIG_FILE="${CLUSTER_DIR}/kubeconfig"
INGRESS_GW_NS="gateway"                        # namespace of the shared Gateway (ingress verify)
INGRESS_HOSTS=""                               # space-separated hosts to check; empty = derive from Gateways
MAINT_TIMEOUT=30                               # secs/node to confirm maintenance API before giving up
CONTROLLER_WAIT=900                            # secs to wait for the sealed-secrets controller (ArgoCD wave 2)
INGRESS_WAIT=900                               # secs to wait for the ingress to actually serve (HTTP-01 is slow)
CONVERGE_WAIT=900                              # secs for the converge backstop to drive every app to Synced+Healthy
COMMIT_MSG_SYNC="bootstrap: sync config before ArgoCD bootstrap"
COMMIT_MSG_SEAL="bootstrap: re-seal SSO/SMTP + argocd webhook secrets + CNPG S3 backup creds/values"
# -----------------------------------------------------------------------------

# === prereqs =================================================================
require docker git kubectl helm yq kubeseal
docker info >/dev/null 2>&1 || die "docker not responding (start Rancher/Docker Desktop)"
[ -f "${STEP_DIR}/03d_talos_cluster_config.sh" ] || die "missing 03d, run from the repo root"
IPS=(); for e in "${CLUSTER_NODES[@]}"; do IPS+=("${e##*:}"); done
[ "${#IPS[@]}" -gt 0 ] || die "no nodes set, edit CLUSTER_NODES in .env"

# === confirm (the ONLY prompt) ================================================
cat <<EOF

This will BOOTSTRAP a FIRST-TIME Talos cluster on freshly-flashed nodes:
  nodes   : ${IPS[*]}
  archive : secrets.yaml + kubeconfig + talosconfig + sealed-secrets-master.key (+ 03d scratch)
            -> secrets/backup_<timestamp>/   (03d then mints a NEW Talos CA; the old creds stop working)
  flow    : preflight -> 03c verify -> archive -> 03d -> 03e -> 04 -> 07_gateway -> commit/push -> 05 (ArgoCD)
            -> re-seal SSO + SMTP against the new key -> commit/push -> back up the new key -> verify ingress

Requires nodes in MAINTENANCE mode (03a/03b done; 03c boot-verify is run for you below). To re-initialize
a RUNNING cluster instead, abort and use DANGEROUS_rebuild_cluster.sh (it wipes first).
EOF
read -r -p ">> type BOOTSTRAP to proceed: " ans
[ "$ans" = "BOOTSTRAP" ] || { echo "aborted (phew!)."; exit 0; }

say "pulling ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION} (first run only)"
docker pull -q "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" >/dev/null 2>&1 || true

# === STEP 1. maintenance preflight (fast-fail; runs BEFORE we archive anything) ===
# A maintenance node answers the INSECURE API; a CONFIGURED one does NOT (see 03d). So requiring the
# insecure `version` to succeed proves the node is fresh-in-maintenance, not already running a cluster.
# --insecure needs no talosconfig, so this works even though we're about to archive it.
step "checking every node is in MAINTENANCE mode (fresh-init preflight)"
for ip in "${IPS[@]}"; do
  printf '   %-15s ' "$ip"
  deadline=$(( $(date +%s) + MAINT_TIMEOUT ))
  until nc -z -G2 "$ip" "$API_PORT" >/dev/null 2>&1 && talosctl -e "$ip" -n "$ip" version --insecure >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || { echo "NOT IN MAINTENANCE"; \
      die "${ip} is not answering the maintenance API within ${MAINT_TIMEOUT}s. Bootstrap needs freshly-flashed nodes in maintenance mode (03b/03c). If this is a RUNNING cluster, use DANGEROUS_rebuild_cluster.sh to wipe first."; }
    printf '.'; sleep 3
  done
  echo "maintenance"
done
ok "all nodes in maintenance"

# === STEP 2. deep boot-verify (03c) — hard gate BEFORE we touch anything =======
# STEP 1 only proves the maintenance API answers. 03c additionally asserts each node booted OUR image
# (Talos version + rpi5 overlay in the kernel cmdline), sees its NVMe, and has its wired NIC — exactly the
# failure modes that would otherwise surface confusingly deep inside 03d/04. It's a one-shot snapshot (no
# wait of its own), which is why STEP 1's maintenance poll runs first. Fatal run_step: 03c exits non-zero
# on any FAIL, so we die here — before archiving creds / minting fresh PKI — rather than proceed on a bad node.
run_step "boot-verify every node (our image/NIC/NVMe/overlay)" "$STEP_DIR" 03c_talos_boot_verify.sh

# === STEP 3. archive existing local creds -> backup_<timestamp>/ ==============
# Clears the canonical secrets dir of PKI-bearing files so 03d generates a FRESH secrets.yaml (and thus a
# new CA). Moves EVERY file present (incl. dotfiles like a stray .env.other-secrets) into the dated backup,
# so nothing lingers to make 03d reuse the old identity — no fixed allowlist to keep in sync now that
# 03d/03e's render scratch lives in an OS temp dir, not here. Skips DIRECTORIES (so prior backup_<ts>/ dirs
# are never re-nested into the new one) and .DS_Store (macOS noise, not a cred).
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_SUBDIR="${CLUSTER_DIR}/backup_${TS}"
step "archiving existing creds -> ${BACKUP_SUBDIR}"
mkdir -p "$BACKUP_SUBDIR"
moved=0
for path in "${CLUSTER_DIR}"/* "${CLUSTER_DIR}"/.[!.]*; do
  [ -e "$path" ] || continue                       # glob matched nothing (nullglob off)
  [ -d "$path" ] && continue                        # files only; skips backup_<ts>/ and any other dirs
  f="$(basename "$path")"
  [ "$f" = ".DS_Store" ] && continue                # macOS noise, leave it
  mv "$path" "${BACKUP_SUBDIR}/" && moved=$((moved+1)) || die "could not archive ${f}"
done
if [ "$moved" -gt 0 ]; then ok "archived ${moved} file(s)"; else rmdir "$BACKUP_SUBDIR" 2>/dev/null; ok "nothing to archive (already a clean start)"; fi

# === STEP 4-5. Talos bring-up (03d mints fresh PKI; abort on first failure) ===
run_step "fresh PKI, apply config, bootstrap etcd" "$STEP_DIR" 03d_talos_cluster_config.sh
run_step "NIC hardening (EEE/watchdog)"            "$STEP_DIR" 03e_nic_hardening.sh

# === STEP 6. CNI ==============================================================
run_step "CNI + monitoring CRDs + LB/L2 + Hubble" "$STEP_DIR" 04_cilium.sh

# === STEP 7. gateway config from .env (chart values; no cluster) ===
run_step "propagate LE_EMAIL/BASE_DOMAIN into the gateway chart values" "$STEP_DIR" 07_gateway.sh

# === STEP 8. commit + push (ArgoCD deploys the REMOTE; 05 refuses a dirty tree) ===
step "git add + commit + push (config so far: LB range + gateway values)"
git add -A
if git diff --cached --quiet; then
  ok "nothing new to commit"
else
  git commit -m "$COMMIT_MSG_SYNC" >/dev/null && ok "committed local changes" || die "git commit failed"
fi
git push || die "git push failed, ArgoCD deploys the REMOTE; push manually then resume from 05 by hand"
ok "remote up to date"

# === STEP 9. ArgoCD ===========================================================
run_step "bootstrap ArgoCD; it delivers the rest from git" "$STEP_DIR" 05_argocd.sh

# === STEP 10. wait for the sealed-secrets controller (ArgoCD wave 2) ==========
# kubeseal (steps 11-12, 15) + the key backup (18) all need the controller up. It's a wave-2 app, so ArgoCD
# creates it a bit after 05; poll until a controller pod is Ready. Abort with a manual-recovery hint if
# it never comes up (the cluster is still fine — you'd just re-seal + back up by hand later).
step "waiting for the sealed-secrets controller (ArgoCD wave 2), up to ${CONTROLLER_WAIT}s"
export KUBECONFIG="$KUBECONFIG_FILE"
deadline=$(( $(date +%s) + CONTROLLER_WAIT ))
until kubectl get pods -n "$SS_CONTROLLER_NS" -l "$SS_POD_SELECTOR" \
        -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; do
  [ "$(date +%s)" -lt "$deadline" ] || die "sealed-secrets controller not Ready within ${CONTROLLER_WAIT}s (kubectl -n ${SS_CONTROLLER_NS} get pods). Cluster is up; once the controller is Ready, re-seal by hand (07_google_sso, 09_grafana_smtp, 08_argocd_webhook) + commit/push, then 06_backup_sealed_secrets_key.sh."
  printf '.'; sleep 10
done
echo; ok "sealed-secrets controller Ready"

# === STEP 11. re-seal Google SSO against the NEW key (best-effort) ============
# 07_google_sso.sh no longer prompts (allowlists are per-ingress values already in git); it just re-writes
# the shared clientID + re-seals google-oauth against the fresh key. Skipped if the .env creds are empty.
if [ -n "$GOOGLE_SSO_CLIENT_ID" ] && [ -n "$GOOGLE_SSO_CLIENT_SECRET" ]; then
  run_step "re-writes clientID + re-seals the client secret" "$STEP_DIR" 07_google_sso.sh best-effort \
    "07_google_sso didn't complete; re-run it by hand ('07_google_sso.sh') + commit/push"
else
  step "re-seal Google SSO (skipped: .env creds empty)"
  warn "GOOGLE_SSO_CLIENT_ID/SECRET empty in .env -> skipping SSO re-seal (google-oauth stays orphaned until you set them + run 07)"
fi

# === STEP 12. re-seal Grafana SMTP against the NEW key (best-effort) ==========
if [ -n "$SMTP_GOOGLE_APP_PASSWORD_SECRET" ]; then
  run_step "re-seal Grafana SMTP against the new key" "$STEP_DIR" 09_grafana_smtp.sh best-effort \
    "09_grafana_smtp didn't complete; re-run it by hand + commit/push"
else
  step "re-seal Grafana SMTP (skipped: .env secret empty)"
  warn "SMTP_GOOGLE_APP_PASSWORD_SECRET empty in .env -> skipping SMTP re-seal (Grafana email off; committed grafana-smtp stays orphaned)"
fi

# === STEP 13. seal the ArgoCD GitHub webhook secret + set poll cadence (best-effort) ===
# Not guarded on a .env secret: 08 GENERATES its own webhook secret (into secrets/) and always runs. It
# seals webhook.github.secret into argocd-secret (patch-merge; 05 marked the live secret patch-managed) and
# writes timeout.reconciliation from .env POLL_SYNC_ENABLED. The GitHub webhook itself is a manual post-boot
# step (it needs public DNS + the prod cert); 08 prints the exact setup. See 05_gitops.md.
run_step "generate+seal the GitHub webhook secret + set poll cadence" "$STEP_DIR" 08_argocd_webhook.sh best-effort \
  "08_argocd_webhook didn't complete; re-run it by hand ('08_argocd_webhook.sh') + commit/push"

# === STEP 14. Terraform: S3 backup bucket + scoped IAM writer (best-effort) ===
# Needs NO cluster (pure AWS), but grouped here so the commit below carries any resulting state note. Skipped
# when the .env deployer creds are empty (backups off). Idempotent (terraform apply), so a re-run reconciles.
if [ -n "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
  run_step "Terraform: S3 backup bucket + scoped IAM writer" "$STEP_DIR" 13_s3_backup_bucket.sh best-effort \
    "13_s3_backup_bucket didn't complete; re-run it by hand ('make s3-backup-bucket')"
else
  step "S3 backup bucket (skipped: .env AWS creds empty)"
  warn "AWS_DEPLOY_ACCESS_KEY_ID empty in .env -> skipping S3 backups (no bucket; CNPG backups stay off)"
fi

# === STEP 15. enable CNPG S3 backups: seal creds + chart values (best-effort) ==
# Needs the controller (STEP 10) + the Terraform outputs from STEP 14. Seals the writer creds into each CNPG
# namespace and flips backups on in the shared pg-cluster values; the commit below pushes both. Skipped when
# creds empty (kept paired with STEP 14 so neither runs half-configured).
if [ -n "$AWS_DEPLOY_ACCESS_KEY_ID" ]; then
  run_step "seal S3 creds per CNPG ns + enable backups in pg-cluster" "$STEP_DIR" 14_cnpg_backup.sh best-effort \
    "14_cnpg_backup didn't complete; re-run it by hand ('make configure-cnpg-backup') + commit/push"
else
  step "enable CNPG S3 backups (skipped: .env AWS creds empty)"
fi

# === STEP 16. commit + push the re-sealed secrets + backup config (best-effort) ===
step "git add + commit + push the re-sealed secrets (ArgoCD unseals them, waves 4 & 7 + argocd)"
git add -A
if git diff --cached --quiet; then
  ok "nothing new to commit"
else
  git commit -m "$COMMIT_MSG_SEAL" >/dev/null && ok "committed re-sealed secrets" || warn "commit failed; commit + push by hand"
fi
git push || warn "push failed; push by hand so ArgoCD picks up the re-sealed secrets"

# === STEP 17. converge ArgoCD (pull the pushed commit + self-heal backstop) ===
# The git poll is a 300s fallback and the GitHub webhook isn't configured yet, so ArgoCD won't pick up STEP
# 16's push (re-sealed google-oauth/grafana-smtp/argocd secrets) on its own for up to ~5 min. converge_argocd_apps
# hard-refreshes EVERY app first (so they re-compare against the pushed commit and apply the re-sealed secrets
# now), then nudges any straggler to Synced+Healthy (unbounded per-app retry converges the rest on its own).
# Best-effort: never fails the bootstrap.
step "converge ArgoCD (pull re-sealed secrets + self-heal backstop, up to ${CONVERGE_WAIT}s)"
converge_argocd_apps "$CONVERGE_WAIT" || true

# === STEP 18. back up the NEW master key (best-effort) ========================
# So a future DANGEROUS_rebuild_cluster.sh can RESTORE it instead of orphaning these SealedSecrets again.
run_step "back up the new sealed-secrets master key" "$STEP_DIR" 06_backup_sealed_secrets_key.sh best-effort \
  "key backup didn't complete; run 06_backup_sealed_secrets_key.sh by hand once the controller is up"

# === STEP 19. verify the ingress data path actually serves (best-effort) ======
# ArgoCD brings up the ingress stack ASYNC after step 8 and HTTP-01 issuance takes minutes; verify_ingress
# (lib/shell/common.sh) polls each HTTPS host until it serves a REAL, LE-backed response over clean HTTP/2.
# Best-effort: warns, never fails the bootstrap.
step "verify ingress serving (LE cert + clean HTTP/2), up to ${INGRESS_WAIT}s"
verify_ingress "$INGRESS_GW_NS" "$INGRESS_WAIT" $INGRESS_HOSTS || true

# === summary =================================================================
cat <<EOF

=============== cluster bootstrapped ===============
ArgoCD is bootstrapped and reconciling every app from git. Watch it:
  KUBECONFIG=${KUBECONFIG_FILE} kubectl get applications -n argocd -w

Notes:
  - Old creds were archived under ${BACKUP_SUBDIR:-secrets/backup_<ts>} (the previous Talos CA /
    kubeconfig / sealed-secrets key). The cluster now uses a FRESH identity.
  - A NEW sealed-secrets master key was backed up to ${CLUSTER_DIR}/sealed-secrets-master.key
    (if STEP 16 succeeded) — keep a copy off-cluster; a future rebuild restores from it.
  - If the SSO/SMTP re-seal (STEP 11/12) was skipped or failed, set the .env secrets and re-run
    07_google_sso.sh </dev/null / 09_grafana_smtp.sh, then commit + push.
  - ArgoCD git-poll is a slow fallback now (webhook-driven). Finish the GitHub webhook: paste
    ${CLUSTER_DIR}/argocd-github-webhook-secret.txt into the repo's webhook (Payload URL
    https://argocd.<domain>/api/webhook, content-type application/json, push event). See 05_gitops.md.
  - TLS certs issue via HTTP-01; first issuance takes a few minutes. NB the platform ingress is on
    letsencrypt-PROD now (GitHub webhook SSL verification needs a trusted cert) — mind the prod rate limits.
EOF
