#!/usr/bin/env bash
# Wires up GitHub push-webhook sync for ArgoCD: mints and seals the webhook shared secret, and sets the poll
# cadence from .env. ArgoCD verifies this secret's HMAC on POST /api/webhook, which is why that path can
# safely bypass SSO.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
ARGOCD_CHART="${PLATFORM_CHARTS}/01_argocd"
ARGOCD_VALUES="${ARGOCD_CHART}/values.yaml"                          # poll cadence patched here
# A wave-3 app of its own, NOT the wave-1 argocd chart above: a SealedSecret in that chart aborts the
# cold-boot argocd install before the sealed-secrets CRD exists (wave 2).
SEALED_OUT="${PLATFORM_CHARTS}/03_argocd_webhook_secret/templates/argocd-secret-sealedsecret.yaml"
INGRESS_VALUES="${PLATFORM_CHARTS}/06_platform_ingress/values.yaml"  # source of the argocd host
SEAL_NAME="argocd-secret"            # ArgoCD reads webhook.github.secret ONLY from the Secret with this name
SEAL_NAMESPACE="argocd"
WEBHOOK_KEY="webhook.github.secret"  # the argocd-secret data key ArgoCD's GitHub webhook handler reads
WEBHOOK_FILE="${CLUSTER_DIR}/argocd-github-webhook-secret.txt"  # plaintext for GitHub (gitignored off-repo store)

# ---- state ----
RECON=""            # set by resolve_poll_cadence
WEBHOOK_SECRET=""   # set by mint_webhook_secret
ARGOCD_DOMAIN=""    # set by print_result

# ---- functions ----

check_prerequisites() {
  say "prerequisites"
  require kubeseal kubectl yq openssl
  ensure_cluster_dir
  use_kubeconfig
  [ -f "$ARGOCD_VALUES" ]  || die "missing ${ARGOCD_VALUES} (the 01_argocd chart should ship it)"
  [ -f "$INGRESS_VALUES" ] || die "missing ${INGRESS_VALUES} (the 06_platform_ingress chart should ship it)"
  assert_api
  assert_sealed_secrets_ready
  ok "kubeseal/kubectl/yq/openssl present, API + sealed-secrets controller reachable"
}

# The webhook is the fast path either way; the poll is the fallback for a dropped one.
resolve_poll_cadence() {
  say "poll cadence from .env POLL_SYNC_ENABLED=${POLL_SYNC_ENABLED}"
  case "$POLL_SYNC_ENABLED" in
    true)  RECON="60s"  ;;
    false) RECON="300s" ;;
    *)     die "POLL_SYNC_ENABLED must be true or false in .env (got '${POLL_SYNC_ENABLED}')" ;;
  esac
  ok "timeout.reconciliation -> ${RECON}"
}

# Minted HERE, not read from .env. A re-run REUSES the stored plaintext, so the secret you configured in
# GitHub stays valid.
mint_webhook_secret() {
  say "webhook shared secret -> ${WEBHOOK_FILE}"
  if [ -s "$WEBHOOK_FILE" ]; then
    WEBHOOK_SECRET="$(cat "$WEBHOOK_FILE")"
    ok "reusing existing webhook secret (delete ${WEBHOOK_FILE} to rotate)"
  else
    WEBHOOK_SECRET="$(openssl rand -hex 32)" || die "openssl rand failed"
    ( umask 077; printf '%s\n' "$WEBHOOK_SECRET" > "$WEBHOOK_FILE" ) || die "could not write ${WEBHOOK_FILE}"
    ok "generated a new webhook secret (openssl rand -hex 32)"
  fi
  [ -n "$WEBHOOK_SECRET" ] || die "webhook secret is empty"
}

# The generated template is decorated so the controller MERGES into argocd-secret instead of replacing it:
#   sealedsecrets.bitnami.com/patch: "true"  -> merge webhook.github.secret in, KEEP server.secretkey
#   app.kubernetes.io/part-of: argocd        -> the label ArgoCD's secret informer selects on
seal_webhook_secret() {
  say "sealing ${WEBHOOK_KEY} -> ${SEALED_OUT}"
  seal_secret "$SEAL_NAME" "$SEAL_NAMESPACE" "$SEALED_OUT" "${WEBHOOK_KEY}=${WEBHOOK_SECRET}"
  [ -s "$SEALED_OUT" ] || return 0
  # yq -i is fine here, unlike on hand-written values: kubeseal rewrites this file whole every run.
  if yq -i '.spec.template.metadata.annotations."sealedsecrets.bitnami.com/patch" = "true"
          | .spec.template.metadata.labels."app.kubernetes.io/part-of" = "argocd"' "$SEALED_OUT"; then
    [ "$(yq -r '.spec.template.metadata.annotations."sealedsecrets.bitnami.com/patch"' "$SEALED_OUT")" = "true" ] \
      && ok "template annotated patch-managed + labelled part-of=argocd" || bad "patch annotation not written"
  else
    bad "yq failed to decorate the SealedSecret template (patch annotation / part-of label)"
  fi
}

# Without the annotation on the EXISTING Secret, the controller refuses to touch the argocd-server-created
# argocd-secret. 02a_argocd.sh does this too; repeated here so a standalone run is self-sufficient.
mark_live_secret_patch_managed() {
  say "marking the live argocd-secret patch-managed"
  if kubectl -n "$SEAL_NAMESPACE" get secret "$SEAL_NAME" >/dev/null 2>&1; then
    kubectl -n "$SEAL_NAMESPACE" annotate secret "$SEAL_NAME" sealedsecrets.bitnami.com/patch=true --overwrite >/dev/null 2>&1 \
      && ok "live ${SEAL_NAME} annotated patch-managed" || warn "could not annotate live ${SEAL_NAME}; do it by hand if the merge is refused"
  else
    warn "live ${SEAL_NAME} not present yet (created by argocd-server); 02a_argocd.sh annotates it, or annotate by hand later"
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
  ARGOCD_DOMAIN="$(yq -r '.ingress.ingresses[] | select(.hosts[].subdomain == "argocd") | .domain' "$INGRESS_VALUES" 2>/dev/null | head -1)"
  webhook_url="https://argocd.${ARGOCD_DOMAIN:-<domain>}/api/webhook"
  if [ "$FAIL" -ne 0 ]; then
    echo "Something failed, see above. Fix and re-run (idempotent)."
    return 0
  fi
cat <<EOF

ArgoCD webhook wired. Finish in TWO places:

1. Commit + push so ArgoCD unseals + applies the secret and the new poll cadence:
     git add -A && git commit -m "argocd: github webhook sync" && git push
   Poll is a slow ${RECON} fallback, so ArgoCD won't pick this up fast on its own yet: either wait out the
   fallback, hard-refresh the argocd app, or (first time) run the webhook to prove it end-to-end.

2. Add the webhook in the GitHub repo (Settings -> Webhooks -> Add webhook):
     Payload URL   : ${webhook_url}
     Content type  : application/json
     Secret        : the contents of ${WEBHOOK_FILE}
     SSL verification : ENABLED  (needs the letsencrypt-PROD cert on argocd.${ARGOCD_DOMAIN:-<domain>})
     Events        : Just the push event
   Then push a trivial commit and watch: kubectl -n argocd get applications -w  (refreshes in seconds).

Rotate the secret: delete ${WEBHOOK_FILE}, re-run this script, commit/push, update the GitHub webhook secret.
See 02_gitops.md (Webhook-driven sync).
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
