#!/usr/bin/env bash
#
# 10_ntfy_auth.sh  (macOS)
#
# Seeds the self-hosted ntfy notification server's auth (users + ACLs + the Grafana write token), so the project
# stays reusable with no personal credentials in git. ntfy is a deny-all PRIVATE instance (05_ntfy) with NO
# declarative user/token config, so users/tokens are created imperatively here, INSIDE the running pod (against
# its SQLite auth DB). Two users on the single topic `cluster-alerts`:
#   - phone   (read-only)  — the Android app subscribes; password from .env (NTFY_PHONE_PASSWORD_SECRET).
#   - grafana (write-only) — Grafana's webhook contact point publishes; authenticates with a minted TOKEN, sealed
#                            into the `grafana-ntfy` Secret (key `token`) that 05_grafana reads as GF_NTFY_TOKEN
#                            (envValueFrom, optional). Neither the token nor the password ever land in git plaintext.
#
# Runs AFTER 05_ntfy is synced (needs the pod up to exec `ntfy user/access/token`). Idempotent: re-run to rotate
# the phone password or the Grafana token. Empty NTFY_PHONE_PASSWORD_SECRET => DISABLE path (drops the sealed
# token; Grafana keeps running, just can't publish, GF_NTFY_TOKEN is optional).
#
# Written by this script (committable, no secrets in the values file):
#   - argo_apps/platform/charts/05_grafana/templates/grafana-ntfy-sealedsecret.yaml   (the sealed write token)
#
# Native kubeseal + kubectl (hard-fails if missing); apply-to-cluster work is native, like 04/05/09. Talks to the
# cluster via the step-03 kubeconfig (kubeseal fetches the controller's cert). See docs/09_monitoring.md.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
NTFY_NS="$MONITORING_NS"                                                          # ntfy runs beside grafana (05_ntfy)
GRAFANA_CHART="${REPO_ROOT}/argo_apps/platform/charts/05_grafana"                 # the token is read by grafana
SEALED_OUT="${GRAFANA_CHART}/templates/grafana-ntfy-sealedsecret.yaml"            # sealed write token (committed)
SECRET_NAME="grafana-ntfy"                                                        # Secret Grafana reads GF_NTFY_TOKEN from
SECRET_KEY="token"                                                                # data key; fixed contract with 05_grafana envValueFrom
TOPIC="cluster-alerts"                                                            # the single alert topic (matches 05_grafana webhook + 05_ntfy)
PHONE_USER="phone"                                                                # Android subscriber (read-only)
GRAFANA_USER="grafana"                                                            # webhook publisher (write-only, token auth)
# -----------------------------------------------------------------------------

# Run an ntfy admin subcommand inside the ntfy pod (operates on the pod's /var/lib/ntfy/user.db via /etc/ntfy/server.yml).
nexec()    { kubectl -n "$NTFY_NS" exec deploy/ntfy -- ntfy "$@"; }
# Same, injecting NTFY_PASSWORD (ntfy's documented non-interactive password input for `user add` / `user change-pass`).
nexec_pw() { local pw="$1"; shift; kubectl -n "$NTFY_NS" exec deploy/ntfy -- env NTFY_PASSWORD="$pw" ntfy "$@"; }

# === 0. prereqs ==============================================================
say "prerequisites"
require kubeseal kubectl
[ -d "$GRAFANA_CHART" ] || die "missing ${GRAFANA_CHART}, the 05_grafana chart should ship it"
use_kubeconfig
assert_api
ok "kubeseal/kubectl present, cluster reachable"

# === 1. ntfy must be up (we exec into it) ====================================
say "waiting for ntfy (05_ntfy must be synced first)"
kubectl -n "$NTFY_NS" rollout status deploy/ntfy --timeout=120s \
  || die "ntfy not ready in ns/${NTFY_NS}; sync the 05_ntfy app first (ArgoCD wave 5)"
ok "ntfy pod is running"

# === 2a. DISABLE path: empty phone password ==================================
# NTFY_PHONE_PASSWORD_SECRET comes from the gitignored .env (defaulted empty in common.sh); nothing is prompted.
if [ -z "$NTFY_PHONE_PASSWORD_SECRET" ]; then
  say "no NTFY_PHONE_PASSWORD_SECRET -> DISABLE ntfy alerting (no phone user, drop the sealed token)"
  if [ -f "$SEALED_OUT" ]; then
    warn "this will DELETE the tracked SealedSecret ${SEALED_OUT}"
    read -r -p ">> remove it and disable Grafana->ntfy publishing? type YES: " confirm
    if [ "$confirm" = "YES" ]; then
      rm -f "$SEALED_OUT" && ok "SealedSecret deleted" || bad "could not delete ${SEALED_OUT}"
    else
      die "aborted, left ${SEALED_OUT} in place (set a password and re-run to (re)enable)"
    fi
  else
    ok "no SealedSecret to remove"
  fi
  warn "Grafana keeps running (GF_NTFY_TOKEN is optional) but can't publish alerts, and no phone user exists."
  warn "Set NTFY_PHONE_PASSWORD_SECRET in .env and re-run to enable mobile push."
  summary
  exit
fi

# === 2b. SEAL path: seed users + ACLs, mint + seal the Grafana token =========
say "seeding ntfy users + ACLs on topic '${TOPIC}'"

# phone user (read-only): create, or rotate its password if it already exists (add fails when the user exists).
if nexec_pw "$NTFY_PHONE_PASSWORD_SECRET" user add "$PHONE_USER" >/dev/null 2>&1; then
  ok "phone user created"
else
  nexec_pw "$NTFY_PHONE_PASSWORD_SECRET" user change-pass "$PHONE_USER" >/dev/null 2>&1 \
    && ok "phone user existed -> password rotated" || bad "could not create/rotate phone user"
fi

# grafana user (write-only, token auth): a throwaway random password just to create the account (auth is via token).
nexec_pw "$(openssl rand -hex 24)" user add "$GRAFANA_USER" >/dev/null 2>&1 \
  && ok "grafana user created" || ok "grafana user already exists"

# ACLs: phone read-only, grafana write-only, both scoped to the single alert topic.
nexec access "$PHONE_USER"   "$TOPIC" ro >/dev/null 2>&1 && ok "phone ACL: ro on ${TOPIC}"   || bad "could not set phone ACL"
nexec access "$GRAFANA_USER" "$TOPIC" wo >/dev/null 2>&1 && ok "grafana ACL: wo on ${TOPIC}" || bad "could not set grafana ACL"

# Rotate the Grafana token: drop any existing grafana tokens, mint a fresh one, capture it (format: tk_<alnum>).
say "minting the Grafana write token"
for tid in $(nexec token list "$GRAFANA_USER" 2>/dev/null | grep -oE 'tk_[A-Za-z0-9]+'); do
  nexec token remove "$GRAFANA_USER" "$tid" >/dev/null 2>&1 || true
done
TOKEN="$(nexec token add "$GRAFANA_USER" 2>/dev/null | grep -oE 'tk_[A-Za-z0-9]+' | head -1)"
[ -n "$TOKEN" ] || die "failed to mint an ntfy token for ${GRAFANA_USER} (try: kubectl -n ${NTFY_NS} exec deploy/ntfy -- ntfy token add ${GRAFANA_USER})"
ok "token minted"

# === 3. seal the token -> grafana-ntfy (committable) =========================
say "sealing the token into ${SECRET_NAME} (ns ${NTFY_NS})"
kubectl get pods -n "$SS_CONTROLLER_NS" -l "$SS_POD_SELECTOR" >/dev/null 2>&1 \
  || die "sealed-secrets controller not reachable in ns/${SS_CONTROLLER_NS}, is step 02 synced?"
seal_secret "$SECRET_NAME" "$NTFY_NS" "$SECRET_KEY" "$TOKEN" "$SEALED_OUT"

# === 4. summary ==============================================================
summary
if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
ntfy auth seeded; Grafana write token sealed at ${SEALED_OUT}.

Next:
  - git add -A && git commit && git push   # ArgoCD (wave 5) applies it; the controller unseals the token into
                                            # Secret ${SECRET_NAME} (ns ${NTFY_NS})
  - restart Grafana so it picks up GF_NTFY_TOKEN:  kubectl -n ${NTFY_NS} rollout restart deploy/grafana
  - phone: install the ntfy app, add server https://ntfy.ops.example.com, log in as '${PHONE_USER}', subscribe '${TOPIC}'
  - test: Grafana UI -> Alerting -> Contact points -> ntfy -> "Test" (a push should hit your phone)
  - re-run this script to rotate the phone password / Grafana token, or (empty NTFY_PHONE_PASSWORD_SECRET) to disable.
EOF
else
  echo "Something failed, see above. Fix and re-run (idempotent)."
fi
[ "$FAIL" -eq 0 ]
