#!/usr/bin/env bash
#
# view_credentials.sh  (macOS)
#
# One read-only "where do I go + how do I get in" sheet for the cluster's UIs. Reads Secrets + .env, WRITES NOTHING.
#
# Two services have a real human login credential; everything else behind the edge is Google-SSO-only (sign in with
# your Google account, no separate password). What it prints:
#   - RabbitMQ    — URL + username + password, from the operator-generated Secret rabbitmq-default-user (ns rabbitmq).
#   - ntfy 'phone'— URL + topic + user + password; password from .env NTFY_PHONE_PASSWORD_SECRET (10_ntfy_auth seeds it).
#   - GH webhook  — GitHub hooks/new config URL + ArgoCD payload URL + shared secret, from secrets/argocd-github-webhook-secret.txt (08 mints it).
#   - SSO-only UIs— argocd/grafana/longhorn/vmui/vlogs/hubble: URL only (Google SSO, no app login).
#
# SINGLE SOURCE OF TRUTH (read, not duplicated):
#   - URLs: argo_apps/platform/charts/06_platform_ingress/values.yaml (subdomain + domain per host).
#   - ntfy password: .env NTFY_PHONE_PASSWORD_SECRET (loaded by common.sh; empty => ntfy alerting disabled).
#   - RabbitMQ creds: live Secret in the cluster.
#   - webhook secret: secrets/argocd-github-webhook-secret.txt (08 mints it; empty => run 08).
#
# The FIRST script here to decode a Secret (kubectl ... jsonpath | base64 -d). Cluster-optional: if the API is
# unreachable the RabbitMQ block shows <unavailable> but ntfy + the SSO URLs (both offline sources) still print.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
INGRESS_VALUES="${REPO_ROOT}/argo_apps/platform/charts/06_platform_ingress/values.yaml"  # URL source of truth
RABBITMQ_NS="rabbitmq"                                                                    # broker + default-user Secret ns
RABBITMQ_SECRET="rabbitmq-default-user"                                                   # operator-generated admin creds
RABBITMQ_SUBDOMAIN="rabbitmq"                                                             # its host in the platform ingress
NTFY_USER="phone"                                                                         # Android subscriber (read-only)
NTFY_TOPIC="cluster-alerts"                                                               # matches 10_ntfy_auth.sh / 05_ntfy
WEBHOOK_FILE="${CLUSTER_DIR}/argocd-github-webhook-secret.txt"                             # plaintext webhook secret (08 mints it)
ARGOCD_SUBDOMAIN="argocd"                                                                  # its host in the platform ingress (webhook endpoint)
# -----------------------------------------------------------------------------

# === 0. prereqs ==============================================================
say "prerequisites"
require kubectl yq
[ -f "$INGRESS_VALUES" ] || die "missing ${INGRESS_VALUES}"
use_kubeconfig                                              # dies only if the kubeconfig FILE is absent
API_UP=1; kubectl get nodes >/dev/null 2>&1 || API_UP=0    # SOFT probe: offline sources still print if the API is down
[ "$API_UP" -eq 1 ] && ok "cluster reachable" || warn "cluster unreachable — RabbitMQ creds will be <unavailable>"

# helpers to pull a host's URL out of the ingress values (no hardcoded domains)
ingress_domain() { yq -r ".ingress.ingresses[] | select(.name==\"$1\").domain" "$INGRESS_VALUES"; }
PLATFORM_DOMAIN="$(ingress_domain platform)"

# === 1. RabbitMQ (real login behind the SSO edge) ============================
say "RabbitMQ (management UI)"
echo "  URL:      https://${RABBITMQ_SUBDOMAIN}.${PLATFORM_DOMAIN}"
if [ "$API_UP" -eq 1 ]; then
  rmq_user="$(kubectl -n "$RABBITMQ_NS" get secret "$RABBITMQ_SECRET" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)"
  rmq_pass="$(kubectl -n "$RABBITMQ_NS" get secret "$RABBITMQ_SECRET" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"
  if [ -n "$rmq_user" ] && [ -n "$rmq_pass" ]; then
    echo "  Username: ${rmq_user}"
    echo "  Password: ${rmq_pass}"
    ok "read ${RABBITMQ_SECRET}"
  else
    bad "could not read Secret ${RABBITMQ_SECRET} in ns/${RABBITMQ_NS} (is 03_rabbitmq synced?)"
  fi
else
  echo "  Username: <unavailable: cluster unreachable>"
  echo "  Password: <unavailable: cluster unreachable>"
  bad "cluster unreachable — could not read ${RABBITMQ_SECRET}"
fi
echo "  Note:     Google SSO first (edge), THEN this RabbitMQ login."

# === 2. ntfy (phone push; password from .env, no cluster read) ===============
say "ntfy (phone push)"
ntfy_domain="$(ingress_domain ntfy)"
ntfy_sub="$(yq -r '.ingress.ingresses[] | select(.name=="ntfy").hosts[0].subdomain' "$INGRESS_VALUES")"
echo "  URL:      https://${ntfy_sub}.${ntfy_domain}"
echo "  Topic:    ${NTFY_TOPIC}"
echo "  Username: ${NTFY_USER}"
if [ -n "$NTFY_PHONE_PASSWORD_SECRET" ]; then
  echo "  Password: ${NTFY_PHONE_PASSWORD_SECRET}"
  ok "ntfy phone password present (.env)"
else
  echo "  Password: <ntfy alerting disabled: NTFY_PHONE_PASSWORD_SECRET empty in .env>"
  warn "set NTFY_PHONE_PASSWORD_SECRET in .env and re-run 10_ntfy_auth.sh to enable"
fi
echo "  Note:     edge is OPEN (no SSO — the app can't do OAuth); ntfy's own user/token auth is the only gate."

# === 3. GitHub webhook (ArgoCD fast-sync; secret from file, no cluster read) =
say "GitHub webhook (ArgoCD push-sync)"
echo "  Config:   ${REPO_URL}/settings/hooks/new"                          # where to paste it in GitHub
echo "  Payload:  https://${ARGOCD_SUBDOMAIN}.${PLATFORM_DOMAIN}/api/webhook"  # HMAC-verified, bypasses SSO
if [ -s "$WEBHOOK_FILE" ]; then
  echo "  Secret:   $(cat "$WEBHOOK_FILE")"
  ok "read webhook secret (${WEBHOOK_FILE})"
else
  echo "  Secret:   <not generated: run 08_argocd_webhook.sh>"
  warn "run 08_argocd_webhook.sh to mint the webhook secret"
fi
echo "  Note:     Content type application/json; SSL verification on; event = just the push event."

# === 4. SSO-only UIs (Google account, no separate login) =====================
say "SSO-only (log in with your Google account — no separate login)"
while read -r sub; do
  [ "$sub" = "$RABBITMQ_SUBDOMAIN" ] && continue                # rabbitmq has its own login, shown above
  printf '  %-9s https://%s.%s\n' "${sub}:" "$sub" "$PLATFORM_DOMAIN"
done < <(yq -r '.ingress.ingresses[] | select(.name=="platform").hosts[].subdomain' "$INGRESS_VALUES")

# === 5. summary ==============================================================
summary
