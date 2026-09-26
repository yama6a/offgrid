#!/usr/bin/env bash
# Sets up GitHub push-webhook sync for ArgoCD. Mints and seals the webhook shared secret, and sets the poll
# interval from .env. ArgoCD checks this secret's HMAC on POST /api/webhook, so that path can bypass SSO.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
ARGOCD_CHART="${PLATFORM_CHARTS}/01_argocd"
ARGOCD_VALUES="${ARGOCD_CHART}/values.yaml" # gets the poll interval
# A separate wave-3 app. A SealedSecret in the wave-1 argocd chart fails the first install, because the
# sealed-secrets CRD arrives in wave 2.
SEALED_OUT="${PLATFORM_CHARTS}/03_argocd_webhook_secret/templates/argocd-secret-sealedsecret.yaml"
INGRESS_VALUES="${PLATFORM_CHARTS}/06_platform_ingress/values.yaml" # holds the argocd host
SEAL_NAME="argocd-secret"                                           # ArgoCD reads webhook.github.secret only from here
SEAL_NAMESPACE="argocd"
WEBHOOK_KEY="webhook.github.secret"                            # the argocd-secret key the GitHub webhook handler reads
WEBHOOK_FILE="${CLUSTER_DIR}/argocd-github-webhook-secret.txt" # plaintext copy for GitHub, kept off the repo

# ---- state ----
RECON=""          # set by resolve_poll_cadence
WEBHOOK_SECRET="" # set by mint_webhook_secret
ARGOCD_DOMAIN=""  # set by print_result

# ---- functions ----

check_prerequisites() {
  say "prerequisites"
  require kubeseal kubectl yq openssl
  ensure_cluster_dir
  use_kubeconfig
  [ -f "$ARGOCD_VALUES" ] || die "missing ${ARGOCD_VALUES}. The 01_argocd chart ships it."
  [ -f "$INGRESS_VALUES" ] || die "missing ${INGRESS_VALUES}. The 06_platform_ingress chart ships it."
  assert_api
  assert_sealed_secrets_ready
  ok "kubeseal, kubectl, yq and openssl present. API and sealed-secrets controller reachable."
}

resolve_poll_cadence() {
  say "poll interval from .env POLL_SYNC_ENABLED=${POLL_SYNC_ENABLED}"
  case "$POLL_SYNC_ENABLED" in
    true) RECON="60s" ;;
    false) RECON="300s" ;;
    *) die "POLL_SYNC_ENABLED in .env must be true or false, got '${POLL_SYNC_ENABLED}'" ;;
  esac
  ok "timeout.reconciliation is ${RECON}"
}

# A re-run reuses the stored plaintext, so the secret configured in GitHub stays valid.
mint_webhook_secret() {
  say "writing the webhook shared secret to ${WEBHOOK_FILE}"
  if [ -s "$WEBHOOK_FILE" ]; then
    WEBHOOK_SECRET="$(cat "$WEBHOOK_FILE")"
    ok "reusing the existing webhook secret. Delete ${WEBHOOK_FILE} to rotate it."
  else
    WEBHOOK_SECRET="$(openssl rand -hex 32)" || die "openssl rand failed"
    (
      umask 077
      printf '%s\n' "$WEBHOOK_SECRET" > "$WEBHOOK_FILE"
    ) || die "could not write ${WEBHOOK_FILE}"
    ok "generated a new webhook secret with openssl rand -hex 32"
  fi
  [ -n "$WEBHOOK_SECRET" ] || die "webhook secret is empty"
}

# The patch annotation makes the controller merge into argocd-secret and keep server.secretkey.
# ArgoCD watches only Secrets with the part-of=argocd label.
seal_webhook_secret() {
  say "sealing ${WEBHOOK_KEY} into ${SEALED_OUT}"
  seal_secret "$SEAL_NAME" "$SEAL_NAMESPACE" "$SEALED_OUT" "${WEBHOOK_KEY}=${WEBHOOK_SECRET}"
  [ -s "$SEALED_OUT" ] || return 0
  # yq -i is safe here because kubeseal rewrites this whole file on every run.
  if yq -i '.spec.template.metadata.annotations."sealedsecrets.bitnami.com/patch" = "true"
          | .spec.template.metadata.labels."app.kubernetes.io/part-of" = "argocd"' "$SEALED_OUT"; then
    [ "$(yq -r '.spec.template.metadata.annotations."sealedsecrets.bitnami.com/patch"' "$SEALED_OUT")" = "true" ] \
      && ok "template annotated for patch merge and labelled part-of=argocd" || bad "patch annotation not written"
  else
    bad "yq failed to add the patch annotation and part-of label to the SealedSecret template"
  fi
}

# The controller changes the live argocd-secret only if it carries the patch annotation.
# 02a_argocd.sh sets it too. This script sets it again so it can run on its own.
mark_live_secret_patch_managed() {
  say "annotating the live argocd-secret for patch merge"
  if kubectl -n "$SEAL_NAMESPACE" get secret "$SEAL_NAME" > /dev/null 2>&1; then
    kubectl -n "$SEAL_NAMESPACE" annotate secret "$SEAL_NAME" sealedsecrets.bitnami.com/patch=true --overwrite > /dev/null 2>&1 \
      && ok "live ${SEAL_NAME} annotated for patch merge" || warn "could not annotate live ${SEAL_NAME}. Annotate it by hand if the merge is refused."
  else
    warn "live ${SEAL_NAME} does not exist yet. 02a_argocd.sh creates and annotates it."
  fi
}

write_poll_cadence() {
  say "writing timeout.reconciliation=${RECON} into ${ARGOCD_VALUES}"
  ys_set "$ARGOCD_VALUES" "$RECON" argo-cd configs cm timeout.reconciliation
  [ "$(yq -r '.["argo-cd"].configs.cm."timeout.reconciliation"' "$ARGOCD_VALUES")" = "$RECON" ] \
    && ok "timeout.reconciliation set to ${RECON}" || bad "timeout.reconciliation not written"
}

print_result() {
  local webhook_url
  ARGOCD_DOMAIN="$(yq -r '.ingress.ingresses[] | select(.hosts[].subdomain == "argocd") | .domain' "$INGRESS_VALUES" 2> /dev/null | head -1)"
  webhook_url="https://argocd.${ARGOCD_DOMAIN:-<domain>}/api/webhook"
  if [ "$FAIL" -ne 0 ]; then
    echo "Something failed. See above. Fix it and run this script again."
    return 0
  fi
  cat << EOF

ArgoCD webhook set up. Finish in two places:

1. Commit and push, so ArgoCD unseals and applies the secret and the new poll interval:
     git add -A && git commit -m "argocd: github webhook sync" && git push
   The webhook does not work yet, so ArgoCD picks this up only on the next ${RECON} poll.
   To apply it sooner, hard-refresh the argocd app.

2. Add the webhook in the GitHub repo, under Settings, Webhooks, Add webhook:
     Payload URL      : ${webhook_url}
     Content type     : application/json
     Secret           : the contents of ${WEBHOOK_FILE}
     SSL verification : enabled. Needs the letsencrypt-prod cert on argocd.${ARGOCD_DOMAIN:-<domain>}.
     Events           : Just the push event
   Then push a small commit. The apps refresh within seconds: kubectl -n argocd get applications -w

To rotate the secret: delete ${WEBHOOK_FILE}, run this script again, commit and push, then update the secret in GitHub.
See docs/runbooks/02_gitops.md.
EOF
}

# ---- main ----

check_prerequisites
resolve_poll_cadence
mint_webhook_secret
seal_webhook_secret
mark_live_secret_patch_managed
write_poll_cadence

summary
print_result
[ "$FAIL" -eq 0 ]
