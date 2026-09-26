#!/usr/bin/env bash
# Seeds the ntfy users, ACLs and the Grafana write token. It runs inside the pod, because ntfy has no
# declarative user or token config. Run it after 05_ntfy is synced. Run it again to rotate.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
NTFY_NS="$MONITORING_NS"                                               # ntfy runs in the Grafana namespace
GRAFANA_CHART="${PLATFORM_CHARTS}/05_grafana"                          # Grafana reads the token
SEALED_OUT="${GRAFANA_CHART}/templates/grafana-ntfy-sealedsecret.yaml" # the sealed write token, committed
SECRET_NAME="grafana-ntfy"                                             # the Secret Grafana reads GF_NTFY_TOKEN from
SECRET_KEY="token"                                                     # must match envValueFrom in 05_grafana
TOPIC="cluster-alerts"                                                 # must match the 05_grafana webhook and 05_ntfy
PHONE_USER="phone"                                                     # the Android subscriber, read-only
GRAFANA_USER="grafana"                                                 # the webhook publisher, write-only with a token

# ---- state ----
TOKEN="" # set by mint_grafana_token

# ---- functions ----

nexec() { kubectl -n "$NTFY_NS" exec deploy/ntfy -- ntfy "$@"; }
# ntfy reads NTFY_PASSWORD for a non-interactive `user add` or `user change-pass`.
nexec_pw() {
  local pw="$1"
  shift
  kubectl -n "$NTFY_NS" exec deploy/ntfy -- env NTFY_PASSWORD="$pw" ntfy "$@"
}

check_prerequisites() {
  say "prerequisites"
  require kubeseal kubectl
  [ -d "$GRAFANA_CHART" ] || die "missing ${GRAFANA_CHART}. The 05_grafana chart ships it."
  use_kubeconfig
  assert_api
  ok "kubeseal and kubectl present, cluster reachable"
  say "waiting for ntfy. 05_ntfy must be synced first."
  kubectl -n "$NTFY_NS" rollout status deploy/ntfy --timeout=120s \
    || die "ntfy not ready in ns/${NTFY_NS}. Sync the wave-5 05_ntfy app first."
  ok "ntfy pod is running"
}

# An empty NTFY_PHONE_PASSWORD_SECRET turns alerting off and deletes the tracked SealedSecret, so it asks first.
handle_disabled() {
  [ -n "$NTFY_PHONE_PASSWORD_SECRET" ] && return 0
  say "NTFY_PHONE_PASSWORD_SECRET is empty. Turning ntfy alerting off: no phone user, no sealed token."
  if [ -f "$SEALED_OUT" ]; then
    warn "this deletes the tracked SealedSecret ${SEALED_OUT}"
    if confirm_word_always YES "remove it and stop Grafana publishing to ntfy?"; then
      rm -f "$SEALED_OUT" && ok "SealedSecret deleted" || bad "could not delete ${SEALED_OUT}"
    else
      die "aborted. Left ${SEALED_OUT} in place. Set a password and run this again to turn alerting on."
    fi
  else
    ok "no SealedSecret to remove"
  fi
  warn "Grafana keeps running, because GF_NTFY_TOKEN is optional. It cannot publish alerts, and no phone user exists."
  warn "To turn on phone push, set NTFY_PHONE_PASSWORD_SECRET in .env and run this again."
  summary
  exit
}

# The grafana user logs in with a token, so its password is random and thrown away.
# `user add` fails when the user exists, so the phone user falls back to change-pass.
seed_users_and_acls() {
  say "seeding ntfy users and ACLs on topic '${TOPIC}'"
  if nexec_pw "$NTFY_PHONE_PASSWORD_SECRET" user add "$PHONE_USER" > /dev/null 2>&1; then
    ok "phone user created"
  else
    nexec_pw "$NTFY_PHONE_PASSWORD_SECRET" user change-pass "$PHONE_USER" > /dev/null 2>&1 \
      && ok "phone user existed. Password rotated." || bad "could not create or rotate the phone user"
  fi
  nexec_pw "$(openssl rand -hex 24)" user add "$GRAFANA_USER" > /dev/null 2>&1 \
    && ok "grafana user created" || ok "grafana user already exists"
  nexec access "$PHONE_USER" "$TOPIC" ro > /dev/null 2>&1 && ok "phone ACL: ro on ${TOPIC}" || bad "could not set phone ACL"
  nexec access "$GRAFANA_USER" "$TOPIC" wo > /dev/null 2>&1 && ok "grafana ACL: wo on ${TOPIC}" || bad "could not set grafana ACL"
}

# Removes the old grafana tokens first, so tokens do not pile up.
mint_grafana_token() {
  local tid
  say "minting the Grafana write token"
  for tid in $(nexec token list "$GRAFANA_USER" 2> /dev/null | grep -oE 'tk_[A-Za-z0-9]+'); do
    nexec token remove "$GRAFANA_USER" "$tid" > /dev/null 2>&1 || true
  done
  TOKEN="$(nexec token add "$GRAFANA_USER" 2> /dev/null | grep -oE 'tk_[A-Za-z0-9]+' | head -1)"
  [ -n "$TOKEN" ] || die "failed to mint an ntfy token for ${GRAFANA_USER}. Try: kubectl -n ${NTFY_NS} exec deploy/ntfy -- ntfy token add ${GRAFANA_USER}"
  ok "token minted"
}

seal_token() {
  say "sealing the token into ${SECRET_NAME} in ns/${NTFY_NS}"
  assert_sealed_secrets_ready
  seal_secret "$SECRET_NAME" "$NTFY_NS" "$SEALED_OUT" "${SECRET_KEY}=${TOKEN}"
}

print_result() {
  if [ "$FAIL" -ne 0 ]; then
    echo "Something failed. See above. Fix it and run this script again."
    return 0
  fi
  cat << EOF
ntfy auth seeded. Grafana write token sealed at ${SEALED_OUT}.

Next:
  - git add -A && git commit && git push   # ArgoCD applies it in wave 5, and the controller unseals the token
                                            # into Secret ${SECRET_NAME} in ns/${NTFY_NS}
  - restart Grafana so it reads GF_NTFY_TOKEN:  kubectl -n ${NTFY_NS} rollout restart deploy/grafana
  - phone: install the ntfy app, add server https://ntfy.${OPS_DOMAIN}, log in as '${PHONE_USER}', subscribe to '${TOPIC}'
  - test: in Grafana, open Alerting, Contact points, ntfy, and click "Test". Your phone gets a push.
  - run this script again to rotate the phone password and Grafana token.
    With an empty NTFY_PHONE_PASSWORD_SECRET, it turns alerting off.
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
