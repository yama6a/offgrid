#!/usr/bin/env bash
# One read-only "where do I go and how do I get in" sheet for the cluster's UIs. Reads Secrets and .env,
# WRITES NOTHING. Only RabbitMQ and ntfy have a real human login; everything else behind the edge is
# Google-SSO-only, so this prints their URL and nothing more.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
INGRESS_VALUES="${PLATFORM_CHARTS}/06_platform_ingress/values.yaml"  # URL source of truth
RABBITMQ_NS="rabbitmq"
RABBITMQ_SECRET="rabbitmq-default-user"    # operator-generated admin creds
RABBITMQ_SUBDOMAIN="rabbitmq"
NTFY_SUBDOMAIN="ntfy"                      # a host under the platform ingress, not an ingress of its own
NTFY_USER="phone"                          # Android subscriber (read-only)
NTFY_TOPIC="cluster-alerts"                # matches 06_ntfy_auth.sh / 05_ntfy
WEBHOOK_FILE="${CLUSTER_DIR}/argocd-github-webhook-secret.txt"   # plaintext webhook secret (02b mints it)
ARGOCD_SUBDOMAIN="argocd"

# ---- state ----
API_UP=1            # set by check_prerequisites
PLATFORM_DOMAIN=""

# ---- functions ----

ingress_domain() { yq -r ".ingress.ingresses[] | select(.name==\"$1\").domain" "$INGRESS_VALUES"; }

# A SOFT API probe, so the offline sources still print when the cluster is down.
check_prerequisites() {
  say "prerequisites"
  require kubectl yq
  [ -f "$INGRESS_VALUES" ] || die "missing ${INGRESS_VALUES}"
  use_kubeconfig                                              # dies only if the kubeconfig FILE is absent
  kubectl get nodes >/dev/null 2>&1 || API_UP=0
  [ "$API_UP" -eq 1 ] && ok "cluster reachable" || warn "cluster unreachable, RabbitMQ creds will be <unavailable>"
  PLATFORM_DOMAIN="$(ingress_domain platform)"
}

show_rabbitmq() {
  local user pass
  say "RabbitMQ (management UI)"
  echo "  URL:      https://${RABBITMQ_SUBDOMAIN}.${PLATFORM_DOMAIN}"
  if [ "$API_UP" -eq 1 ]; then
    user="$(kubectl -n "$RABBITMQ_NS" get secret "$RABBITMQ_SECRET" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)"
    pass="$(kubectl -n "$RABBITMQ_NS" get secret "$RABBITMQ_SECRET" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"
    if [ -n "$user" ] && [ -n "$pass" ]; then
      echo "  Username: ${user}"
      echo "  Password: ${pass}"
      ok "read ${RABBITMQ_SECRET}"
    else
      bad "could not read Secret ${RABBITMQ_SECRET} in ns/${RABBITMQ_NS} (is 03_rabbitmq synced?)"
    fi
  else
    echo "  Username: <unavailable: cluster unreachable>"
    echo "  Password: <unavailable: cluster unreachable>"
    bad "cluster unreachable, could not read ${RABBITMQ_SECRET}"
  fi
  echo "  Note:     Google SSO first (edge), THEN this RabbitMQ login."
}

show_ntfy() {
  say "ntfy (phone push)"
  echo "  URL:      https://${NTFY_SUBDOMAIN}.${PLATFORM_DOMAIN}"
  echo "  Topic:    ${NTFY_TOPIC}"
  echo "  Username: ${NTFY_USER}"
  if [ -n "$NTFY_PHONE_PASSWORD_SECRET" ]; then
    echo "  Password: ${NTFY_PHONE_PASSWORD_SECRET}"
    ok "ntfy phone password present (.env)"
  else
    echo "  Password: <ntfy alerting disabled: NTFY_PHONE_PASSWORD_SECRET empty in .env>"
    warn "set NTFY_PHONE_PASSWORD_SECRET in .env and re-run 06_ntfy_auth.sh to enable"
  fi
  echo "  Note:     edge is OPEN (no SSO, the app cannot do OAuth); ntfy's own user/token auth is the only gate."
}

show_github_webhook() {
  say "GitHub webhook (ArgoCD push-sync)"
  echo "  Config:   ${REPO_URL}/settings/hooks/new"
  echo "  Payload:  https://${ARGOCD_SUBDOMAIN}.${PLATFORM_DOMAIN}/api/webhook"   # HMAC-verified, bypasses SSO
  if [ -s "$WEBHOOK_FILE" ]; then
    echo "  Secret:   $(cat "$WEBHOOK_FILE")"
    ok "read webhook secret (${WEBHOOK_FILE})"
  else
    echo "  Secret:   <not generated: run 02b_argocd_webhook.sh>"
    warn "run 02b_argocd_webhook.sh to mint the webhook secret"
  fi
  echo "  Note:     Content type application/json; SSL verification on; event = just the push event."
}

show_sso_only_hosts() {
  local sub
  say "SSO-only (log in with your Google account, no separate login)"
  while read -r sub; do
    [ "$sub" = "$RABBITMQ_SUBDOMAIN" ] && continue                # rabbitmq has its own login, shown above
    [ "$sub" = "$NTFY_SUBDOMAIN" ] && continue                    # ntfy's edge is open, shown above
    printf '  %-9s https://%s.%s\n' "${sub}:" "$sub" "$PLATFORM_DOMAIN"
  done < <(yq -r '.ingress.ingresses[] | select(.name=="platform").hosts[].subdomain' "$INGRESS_VALUES")
}

# ---- main ----

check_prerequisites
show_rabbitmq
show_ntfy
show_github_webhook
show_sso_only_hosts

summary
