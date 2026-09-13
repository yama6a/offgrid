#!/usr/bin/env bash
# Seeds the ntfy server's users, ACLs and the Grafana write token. Imperative and run INSIDE the pod because
# ntfy has NO declarative user or token config. Runs AFTER 05_ntfy is synced. Idempotent: re-run to rotate.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
NTFY_NS="$MONITORING_NS"                       # ntfy runs beside grafana (05_ntfy)
GRAFANA_CHART="${PLATFORM_CHARTS}/05_grafana"  # the token is read by grafana
SEALED_OUT="${GRAFANA_CHART}/templates/grafana-ntfy-sealedsecret.yaml"   # sealed write token (committed)
SECRET_NAME="grafana-ntfy"                     # Secret Grafana reads GF_NTFY_TOKEN from
SECRET_KEY="token"                             # fixed contract with 05_grafana envValueFrom
TOPIC="cluster-alerts"                         # matches 05_grafana webhook + 05_ntfy
PHONE_USER="phone"                             # Android subscriber (read-only)
GRAFANA_USER="grafana"                         # webhook publisher (write-only, token auth)

# ---- state ----
TOKEN=""   # set by mint_grafana_token

# ---- functions ----

# Operates on the pod's /var/lib/ntfy/user.db via /etc/ntfy/server.yml.
nexec()    { kubectl -n "$NTFY_NS" exec deploy/ntfy -- ntfy "$@"; }
# Same, injecting NTFY_PASSWORD: ntfy's documented non-interactive input for `user add` / `user change-pass`.
nexec_pw() { local pw="$1"; shift; kubectl -n "$NTFY_NS" exec deploy/ntfy -- env NTFY_PASSWORD="$pw" ntfy "$@"; }

check_prerequisites() {
  say "prerequisites"
  require kubeseal kubectl
  [ -d "$GRAFANA_CHART" ] || die "missing ${GRAFANA_CHART}, the 05_grafana chart should ship it"
  use_kubeconfig
  assert_api
  ok "kubeseal/kubectl present, cluster reachable"
  say "waiting for ntfy (05_ntfy must be synced first)"
  kubectl -n "$NTFY_NS" rollout status deploy/ntfy --timeout=120s \
    || die "ntfy not ready in ns/${NTFY_NS}; sync the 05_ntfy app first (ArgoCD wave 5)"
  ok "ntfy pod is running"
}

# NTFY_PHONE_PASSWORD_SECRET comes from the gitignored .env (defaulted empty in common.sh); nothing is
# prompted. Empty means alerting off, which deletes the tracked SealedSecret, so it asks first.
handle_disabled() {
  [ -n "$NTFY_PHONE_PASSWORD_SECRET" ] && return 0
  say "no NTFY_PHONE_PASSWORD_SECRET -> DISABLE ntfy alerting (no phone user, drop the sealed token)"
  if [ -f "$SEALED_OUT" ]; then
    warn "this will DELETE the tracked SealedSecret ${SEALED_OUT}"
    if confirm_word_always YES "remove it and disable Grafana->ntfy publishing?"; then
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
}

# Two users on the one topic: phone read-only (the Android app), grafana write-only (token auth, so its
# password is a throwaway just to create the account). `user add` fails when the user exists, hence the
# change-pass fallback.
seed_users_and_acls() {
  say "seeding ntfy users + ACLs on topic '${TOPIC}'"
  if nexec_pw "$NTFY_PHONE_PASSWORD_SECRET" user add "$PHONE_USER" >/dev/null 2>&1; then
    ok "phone user created"
  else
    nexec_pw "$NTFY_PHONE_PASSWORD_SECRET" user change-pass "$PHONE_USER" >/dev/null 2>&1 \
      && ok "phone user existed -> password rotated" || bad "could not create/rotate phone user"
  fi
  nexec_pw "$(openssl rand -hex 24)" user add "$GRAFANA_USER" >/dev/null 2>&1 \
    && ok "grafana user created" || ok "grafana user already exists"
  nexec access "$PHONE_USER"   "$TOPIC" ro >/dev/null 2>&1 && ok "phone ACL: ro on ${TOPIC}"   || bad "could not set phone ACL"
  nexec access "$GRAFANA_USER" "$TOPIC" wo >/dev/null 2>&1 && ok "grafana ACL: wo on ${TOPIC}" || bad "could not set grafana ACL"
}

# Drops any existing grafana tokens first, so this rotates rather than accumulating. Format: tk_<alnum>.
mint_grafana_token() {
  local tid
  say "minting the Grafana write token"
  for tid in $(nexec token list "$GRAFANA_USER" 2>/dev/null | grep -oE 'tk_[A-Za-z0-9]+'); do
    nexec token remove "$GRAFANA_USER" "$tid" >/dev/null 2>&1 || true
  done
  TOKEN="$(nexec token add "$GRAFANA_USER" 2>/dev/null | grep -oE 'tk_[A-Za-z0-9]+' | head -1)"
  [ -n "$TOKEN" ] || die "failed to mint an ntfy token for ${GRAFANA_USER} (try: kubectl -n ${NTFY_NS} exec deploy/ntfy -- ntfy token add ${GRAFANA_USER})"
  ok "token minted"
}

seal_token() {
  say "sealing the token into ${SECRET_NAME} (ns ${NTFY_NS})"
  assert_sealed_secrets_ready
  seal_secret "$SECRET_NAME" "$NTFY_NS" "$SEALED_OUT" "${SECRET_KEY}=${TOKEN}"
}

print_result() {
  if [ "$FAIL" -ne 0 ]; then
    echo "Something failed, see above. Fix and re-run (idempotent)."
    return 0
  fi
cat <<EOF
ntfy auth seeded; Grafana write token sealed at ${SEALED_OUT}.

Next:
  - git add -A && git commit && git push   # ArgoCD (wave 5) applies it; the controller unseals the token into
                                            # Secret ${SECRET_NAME} (ns ${NTFY_NS})
  - restart Grafana so it picks up GF_NTFY_TOKEN:  kubectl -n ${NTFY_NS} rollout restart deploy/grafana
  - phone: install the ntfy app, add server https://ntfy.${OPS_DOMAIN}, log in as '${PHONE_USER}', subscribe '${TOPIC}'
  - test: Grafana UI -> Alerting -> Contact points -> ntfy -> "Test" (a push should hit your phone)
  - re-run this script to rotate the phone password / Grafana token, or (empty NTFY_PHONE_PASSWORD_SECRET) to disable.
EOF
}

# ---- main ----

check_prerequisites
handle_disabled
seed_users_and_acls
mint_grafana_token
seal_token

summary
print_result
[ "$FAIL" -eq 0 ]
