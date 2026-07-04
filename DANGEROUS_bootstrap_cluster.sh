#!/usr/bin/env bash
#
# DANGEROUS_bootstrap_cluster.sh
#
# One-shot orchestrator for a FIRST-TIME cluster init (contrast DANGEROUS_rebuild_cluster.sh, which wipes
# a RUNNING cluster and reuses preserved state). This assumes freshly-flashed nodes (03a/03b/03c done)
# sitting in MAINTENANCE mode, and takes them from there to a fully delivered cluster. One confirmation up
# front, non-interactive after that.
# Sequence (STEP N/14):
#   1. maintenance preflight        : every node must answer the INSECURE (maintenance) API — fast-fail
#                                      if any is already configured (that's a rebuild, not a bootstrap)
#   2. archive local creds          : mv secrets.yaml/kubeconfig/talosconfig/sealed-secrets-master.key +
#                                      03d scratch into talos-cluster/backup_<ts>/ so 03d mints a NEW PKI
#   3. 03d_talos_cluster_config.sh  : generate fresh config, apply, bootstrap etcd, write kube/talosconfig
#   4. 03e_nic_hardening.sh         : NIC hardening (EEE/watchdog)
#   5. 04_cilium.sh                 : CNI + prometheus-operator CRDs + LB-IPAM/L2 + Hubble
#   6. 07_gateway.sh + 07_sso_domains.sh : write LE_EMAIL/BASE_DOMAIN into the gateway chart + SSO_CALLBACK_DOMAINS
#                                     into the ingress-edge callbackDomains (both chart values, no cluster)
#   7. git add/commit/push          : 05 refuses a dirty argo_apps/ tree; ArgoCD deploys the REMOTE
#   8. 05_argocd.sh                 : bootstrap ArgoCD; it then delivers the whole platform from git
#   9. wait sealed-secrets ctrl     : ArgoCD wave-2 app; kubeseal (steps 10-11, 13) needs it up
#  10. 07_google_sso.sh </dev/null  : write shared clientID + RE-SEAL google-oauth against the NEW key
#  11. 09_grafana_smtp.sh           : RE-SEAL grafana-smtp against the NEW key
#  12. git add/commit/push          : push the re-sealed SealedSecrets so ArgoCD unseals them (waves 4 & 7)
#  13. 06_backup_sealed_secrets_key.sh : back up the NEW master key so a future rebuild can restore it
#  14. verify ingress serving       : wait until each HTTPS host serves an LE cert over clean HTTP/2
#
# Why re-seal + back up (and a rebuild doesn't): a fresh controller mints a BRAND-NEW master key, so the
# two committed SealedSecrets (google-oauth, grafana-smtp, sealed against an OLD key) are orphaned — they
# must be re-sealed against the new key. The rebuild instead RESTORES the old key (06_restore) and skips
# re-sealing. Here there is no old key to restore, so we re-seal and then back the new key up.
#
# Skips 03a/03b/03c (image build/flash/boot-verify): bootstrap assumes the OS is already flashed and the
# nodes are in maintenance. Bootstrap steps (1-9) abort on the first failure with a resume hint; the
# re-seal/backup/verify steps (10-14) are best-effort so a slow ArgoCD never wedges the run.
#
# FIRST-TIME semantics: archiving secrets.yaml makes 03d mint a NEW Talos CA — the archived
# talosconfig/kubeconfig stop working (they're kept under backup_<ts>/). This is intended for a genuine
# from-scratch init. To re-initialize a RUNNING cluster, use DANGEROUS_rebuild_cluster.sh (it wipes first).
#
# Needs Docker (host networking), git, kubectl, helm, yq, kubeseal.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source "${SCRIPT_DIR}/lib/common.sh"   # say/die/warn/ok + CLUSTER_DIR + CLUSTER_NODES + secret .env keys

# ---- knobs ------------------------------------------------------------------
STEP_03_DIR="${SCRIPT_DIR}/03_operating_system"
STEP_04_DIR="${SCRIPT_DIR}/04_networking"
STEP_05_DIR="${SCRIPT_DIR}/05_gitops"
STEP_06_DIR="${SCRIPT_DIR}/06_secrets"
STEP_07_DIR="${SCRIPT_DIR}/07_ingress"
STEP_09_DIR="${SCRIPT_DIR}/09_monitoring"
KUBECONFIG_FILE="${CLUSTER_DIR}/kubeconfig"
INGRESS_GW_NS="gateway"                        # namespace of the shared Gateway (ingress verify)
INGRESS_HOSTS=""                               # space-separated hosts to check; empty = derive from Gateways
# generated artifacts archived (never `mv *`, so user files like .env.other-secrets survive):
ARCHIVE_FILES=(secrets.yaml controlplane.yaml cp.yaml cp-patch.yaml volumes.yaml worker.yaml \
  kubeconfig talosconfig sealed-secrets-master.key \
  nic-discovery.txt nic-eth-delete.yaml nic-hardening-patch.yaml)
MAINT_TIMEOUT=30                               # secs/node to confirm maintenance API before giving up
CONTROLLER_WAIT=900                            # secs to wait for the sealed-secrets controller (ArgoCD wave 2)
INGRESS_WAIT=900                               # secs to wait for the ingress to actually serve (HTTP-01 is slow)
COMMIT_MSG_SYNC="bootstrap: sync config before ArgoCD bootstrap"
COMMIT_MSG_SEAL="bootstrap: re-seal SSO/SMTP secrets against the new sealed-secrets key"
# -----------------------------------------------------------------------------

# === prereqs =================================================================
require docker git kubectl helm yq kubeseal
docker info >/dev/null 2>&1 || die "docker not responding (start Rancher/Docker Desktop)"
[ -f "${STEP_03_DIR}/03d_talos_cluster_config.sh" ] || die "missing 03d, run from the repo root"
IPS=(); for e in "${CLUSTER_NODES[@]}"; do IPS+=("${e##*:}"); done
[ "${#IPS[@]}" -gt 0 ] || die "no nodes set, edit CLUSTER_NODES in .env"

# === confirm (the ONLY prompt) ================================================
cat <<EOF

This will BOOTSTRAP a FIRST-TIME Talos cluster on freshly-flashed nodes:
  nodes   : ${IPS[*]}
  archive : secrets.yaml + kubeconfig + talosconfig + sealed-secrets-master.key (+ 03d scratch)
            -> talos-cluster/backup_<timestamp>/   (03d then mints a NEW Talos CA; the old creds stop working)
  flow    : preflight -> archive -> 03d -> 03e -> 04 -> 07_gateway + 07_sso_domains -> commit/push -> 05 (ArgoCD)
            -> re-seal SSO + SMTP against the new key -> commit/push -> back up the new key -> verify ingress

Requires nodes in MAINTENANCE mode (03a/03b/03c done). To re-initialize a RUNNING cluster instead,
abort and use DANGEROUS_rebuild_cluster.sh (it wipes first).
EOF
read -r -p ">> type BOOTSTRAP to proceed: " ans
[ "$ans" = "BOOTSTRAP" ] || { echo "aborted (phew!)."; exit 0; }

say "pulling ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION} (first run only)"
docker pull -q "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" >/dev/null 2>&1 || true

# === STEP 1. maintenance preflight (fast-fail; runs BEFORE we archive anything) ===
# A maintenance node answers the INSECURE API; a CONFIGURED one does NOT (see 03d). So requiring the
# insecure `version` to succeed proves the node is fresh-in-maintenance, not already running a cluster.
# --insecure needs no talosconfig, so this works even though we're about to archive it.
say "STEP 1/14, checking every node is in MAINTENANCE mode (fresh-init preflight)"
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

# === STEP 2. archive existing local creds -> backup_<timestamp>/ ==============
# Clears the canonical talos-cluster dir of PKI-bearing files so 03d generates a FRESH secrets.yaml
# (and thus a new CA). Critically this also moves controlplane.yaml, which would otherwise trigger 03d's
# --from-controlplane-config migration and reuse the OLD PKI. Only a known file list is moved, never a
# glob, so user files (.env.other-secrets, .DS_Store) are left untouched.
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_SUBDIR="${CLUSTER_DIR}/backup_${TS}"
say "STEP 2/14, archiving existing creds -> ${BACKUP_SUBDIR}"
mkdir -p "$BACKUP_SUBDIR"
moved=0
for f in "${ARCHIVE_FILES[@]}"; do
  if [ -e "${CLUSTER_DIR}/${f}" ]; then
    mv "${CLUSTER_DIR}/${f}" "${BACKUP_SUBDIR}/" && moved=$((moved+1)) || die "could not archive ${f}"
  fi
done
if [ "$moved" -gt 0 ]; then ok "archived ${moved} file(s)"; else rmdir "$BACKUP_SUBDIR" 2>/dev/null; ok "nothing to archive (already a clean start)"; fi

# === STEP 3-4. Talos bring-up (03d mints fresh PKI; abort on first failure) ===
say "STEP 3/14, 03d_talos_cluster_config.sh (fresh PKI, apply config, bootstrap etcd)"
( cd "$STEP_03_DIR" && bash ./03d_talos_cluster_config.sh ) || die "03d failed, fix and resume from 03d by hand"
ok "03d done"

say "STEP 4/14, 03e_nic_hardening.sh"
( cd "$STEP_03_DIR" && bash ./03e_nic_hardening.sh ) || die "03e failed, fix and resume from 03e by hand"
ok "03e done"

# === STEP 5. CNI ==============================================================
say "STEP 5/14, 04_cilium.sh (CNI + monitoring CRDs + LB/L2 + Hubble)"
( cd "$STEP_04_DIR" && bash ./04_cilium.sh ) || die "04_cilium failed, fix and resume from 04 by hand"
ok "04_cilium done"

# === STEP 6. chart config from .env (gateway values + SSO callback domains; no cluster) ===
say "STEP 6/14, 07_gateway.sh (propagate LE_EMAIL/BASE_DOMAIN into the gateway chart values)"
( cd "$STEP_07_DIR" && bash ./07_gateway.sh ) || die "07_gateway failed, fix and resume from 07_gateway by hand"
ok "07_gateway done"
# 07_sso_domains.sh writes SSO_CALLBACK_DOMAINS from .env into the ingress-edge library's callbackDomains.
# </dev/null -> non-interactive REPLACE (.env is authoritative); empty SSO_CALLBACK_DOMAINS -> it self-skips
# (leaves the committed list untouched, so a no-SSO bootstrap never wipes domains). Must precede 07_google_sso.
say "STEP 6/14, 07_sso_domains.sh (propagate SSO_CALLBACK_DOMAINS into the ingress-edge callbackDomains)"
( cd "$STEP_07_DIR" && bash ./07_sso_domains.sh </dev/null ) \
  || warn "07_sso_domains didn't complete; re-run it by hand ('07_sso_domains.sh') + commit/push"
ok "07_sso_domains done"

# === STEP 7. commit + push (ArgoCD deploys the REMOTE; 05 refuses a dirty tree) ===
say "STEP 7/14, git add + commit + push (config so far: LB range + gateway values + SSO callback domains)"
git add -A
if git diff --cached --quiet; then
  ok "nothing new to commit"
else
  git commit -m "$COMMIT_MSG_SYNC" >/dev/null && ok "committed local changes" || die "git commit failed"
fi
git push || die "git push failed, ArgoCD deploys the REMOTE; push manually then resume from 05 by hand"
ok "remote up to date"

# === STEP 8. ArgoCD ===========================================================
say "STEP 8/14, 05_argocd.sh (bootstrap ArgoCD; it delivers the rest from git)"
( cd "$STEP_05_DIR" && bash ./05_argocd.sh ) || die "05_argocd failed, fix and resume from 05 by hand"
ok "05_argocd done"

# === STEP 9. wait for the sealed-secrets controller (ArgoCD wave 2) ===========
# kubeseal (steps 10-11) + the key backup (13) all need the controller up. It's a wave-2 app, so ArgoCD
# creates it a bit after 05; poll until a controller pod is Ready. Abort with a manual-recovery hint if
# it never comes up (the cluster is still fine — you'd just re-seal + back up by hand later).
say "STEP 9/14, waiting for the sealed-secrets controller (ArgoCD wave 2), up to ${CONTROLLER_WAIT}s"
export KUBECONFIG="$KUBECONFIG_FILE"
deadline=$(( $(date +%s) + CONTROLLER_WAIT ))
until kubectl get pods -n "$SS_CONTROLLER_NS" -l "$SS_POD_SELECTOR" \
        -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; do
  [ "$(date +%s)" -lt "$deadline" ] || die "sealed-secrets controller not Ready within ${CONTROLLER_WAIT}s (kubectl -n ${SS_CONTROLLER_NS} get pods). Cluster is up; once the controller is Ready, re-seal by hand (07_google_sso, 09_grafana_smtp) + commit/push, then 06_backup_sealed_secrets_key.sh."
  printf '.'; sleep 10
done
echo; ok "sealed-secrets controller Ready"

# === STEP 10. re-seal Google SSO against the NEW key (best-effort) ============
# 07_google_sso.sh no longer prompts (allowlists are per-ingress values already in git); it just re-writes
# the shared clientID + re-seals google-oauth against the fresh key. Skipped if the .env creds are empty.
say "STEP 10/14, re-seal Google SSO (07_google_sso.sh: re-writes clientID + re-seals the client secret)"
if [ -n "$GOOGLE_SSO_CLIENT_ID" ] && [ -n "$GOOGLE_SSO_CLIENT_SECRET" ]; then
  ( cd "$STEP_07_DIR" && bash ./07_google_sso.sh </dev/null ) \
    || warn "07_google_sso didn't complete; re-run it by hand ('07_google_sso.sh') + commit/push"
else
  warn "GOOGLE_SSO_CLIENT_ID/SECRET empty in .env -> skipping SSO re-seal (google-oauth stays orphaned until you set them + run 07)"
fi

# === STEP 11. re-seal Grafana SMTP against the NEW key (best-effort) ==========
say "STEP 11/14, re-seal Grafana SMTP (09_grafana_smtp.sh)"
if [ -n "$SMTP_GOOGLE_APP_PASSWORD_SECRET" ]; then
  ( cd "$STEP_09_DIR" && bash ./09_grafana_smtp.sh ) \
    || warn "09_grafana_smtp didn't complete; re-run it by hand + commit/push"
else
  warn "SMTP_GOOGLE_APP_PASSWORD_SECRET empty in .env -> skipping SMTP re-seal (Grafana email off; committed grafana-smtp stays orphaned)"
fi

# === STEP 12. commit + push the re-sealed secrets (best-effort) ===============
say "STEP 12/14, git add + commit + push the re-sealed secrets (ArgoCD unseals them, waves 4 & 7)"
git add -A
if git diff --cached --quiet; then
  ok "nothing new to commit"
else
  git commit -m "$COMMIT_MSG_SEAL" >/dev/null && ok "committed re-sealed secrets" || warn "commit failed; commit + push by hand"
fi
git push || warn "push failed; push by hand so ArgoCD picks up the re-sealed secrets"

# === STEP 13. back up the NEW master key (best-effort) ========================
# So a future DANGEROUS_rebuild_cluster.sh can RESTORE it instead of orphaning these SealedSecrets again.
say "STEP 13/14, back up the new sealed-secrets master key (06_backup_sealed_secrets_key.sh)"
( cd "$STEP_06_DIR" && bash ./06_backup_sealed_secrets_key.sh ) \
  || warn "key backup didn't complete; run 06_backup_sealed_secrets_key.sh by hand once the controller is up"

# === STEP 14. verify the ingress data path actually serves (best-effort) ======
# ArgoCD brings up the ingress stack ASYNC after step 8 and HTTP-01 issuance takes minutes, so poll each
# HTTPS host until it serves a REAL response: (1) the served cert's issuer says "Let's Encrypt" (rejects
# cert-manager's temporary self-signed cert), and (2) curl --http2 returns a normal 2xx/3xx/4xx. We hit
# the Gateway LB IP with the right SNI (not public DNS), so a router/DDNS quirk can't wedge it. -k ignores
# CA trust (LE staging is fine). Best-effort: warns, never fails the bootstrap.
say "STEP 14/14, verify ingress serving (LE cert + clean HTTP/2), up to ${INGRESS_WAIT}s"
if ! command -v curl >/dev/null || ! command -v openssl >/dev/null; then
  warn "curl/openssl not both present, skipping ingress verification"
else
  ingress_serves_ok() {   # $1=host $2=lbip ; returns 0 only for a real, LE-backed, clean-h2 response
    local host="$1" ip="$2" issuer code ver
    issuer="$(printf '' | openssl s_client -connect "${ip}:443" -servername "$host" 2>/dev/null \
              | openssl x509 -noout -issuer 2>/dev/null)"
    printf '%s' "$issuer" | grep -qiE "Let.?s Encrypt" || return 1   # temp/self-signed/wrong cert -> wait
    read -r code ver < <(curl -k --http2 -sS -o /dev/null -w '%{http_code} %{http_version}' \
      --resolve "${host}:443:${ip}" --max-time 10 "https://${host}/" 2>/dev/null)
    [ "${ver:-}" = "2" ] || return 1                                 # ERR_HTTP2_PROTOCOL_ERROR/conn fail -> wait
    case "${code:-000}" in [234][0-9][0-9]) return 0;; *) return 1;; esac   # 000 / 5xx -> wait
  }

  deadline=$(( $(date +%s) + INGRESS_WAIT )); remaining=""; lbip=""
  while :; do
    lbip="$(kubectl get gateway -n "$INGRESS_GW_NS" \
            -o jsonpath='{range .items[*]}{.status.addresses[0].value}{"\n"}{end}' 2>/dev/null | grep -m1 .)"
    if [ -n "$INGRESS_HOSTS" ]; then hosts="$INGRESS_HOSTS"; else
      hosts="$(kubectl get gateway -n "$INGRESS_GW_NS" \
               -o jsonpath='{range .items[*].spec.listeners[?(@.protocol=="HTTPS")]}{.hostname}{"\n"}{end}' 2>/dev/null \
               | sort -u | tr '\n' ' ')"
    fi
    if [ -n "$lbip" ] && [ -n "${hosts// }" ]; then
      remaining=""
      for h in $hosts; do ingress_serves_ok "$h" "$lbip" || remaining="${remaining} ${h}"; done
      [ -z "${remaining// }" ] && { ok "all ingress hosts serve an LE cert over clean HTTP/2 (via ${lbip})"; break; }
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      warn "ingress not fully serving within ${INGRESS_WAIT}s${lbip:+ (LB ${lbip})}, still pending:${remaining:-  <gateway/hosts not found yet>}"
      warn "inspect: kubectl get gateway,certificate -A ; kubectl -n argocd get applications"
      break
    fi
    printf '.'; sleep 10
  done
  echo
fi

# === summary =================================================================
cat <<EOF

=============== cluster bootstrapped ===============
ArgoCD is bootstrapped and reconciling every app from git. Watch it:
  KUBECONFIG=${KUBECONFIG_FILE} kubectl get applications -n argocd -w

Notes:
  - Old creds were archived under ${BACKUP_SUBDIR:-talos-cluster/backup_<ts>} (the previous Talos CA /
    kubeconfig / sealed-secrets key). The cluster now uses a FRESH identity.
  - A NEW sealed-secrets master key was backed up to ${CLUSTER_DIR}/sealed-secrets-master.key
    (if STEP 13 succeeded) — keep a copy off-cluster; a future rebuild restores from it.
  - If the SSO/SMTP re-seal (STEP 10/11) was skipped or failed, set the .env secrets and re-run
    07_google_sso.sh </dev/null / 09_grafana_smtp.sh, then commit + push.
  - TLS certs issue via HTTP-01; first issuance takes a few minutes. If bootstrapping repeatedly,
    validate on letsencrypt-staging before prod (tight rate limits).
EOF
