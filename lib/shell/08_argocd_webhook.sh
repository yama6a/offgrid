#!/usr/bin/env bash
#
# 08_argocd_webhook.sh  (macOS)
#
# Wires up GitHub push-webhook sync for ArgoCD (replacing the git poll) and sets the poll cadence.
# Two jobs:
#
#   1. GENERATE + SEAL the GitHub webhook shared secret. The secret is minted HERE (not read from .env),
#      the plaintext is written to secrets/argocd-github-webhook-secret.txt (the gitignored off-repo store)
#      for you to paste into GitHub's webhook config, and it's sealed into a committable SealedSecret that
#      MERGES webhook.github.secret into argocd-secret (patch-mode; server.secretkey is preserved). ArgoCD
#      verifies this secret's HMAC on POST /api/webhook, which is why that path can safely bypass Google SSO
#      (the ungated bypass route lives in 08_platform_ingress; the SecurityPolicy never targets it).
#      Idempotent: a re-run REUSES the stored plaintext, so the secret you configured in GitHub stays valid.
#
#   2. PATCH the poll cadence from .env POLL_SYNC_ENABLED into the argocd chart values:
#         false -> timeout.reconciliation: 3600s  (webhook-driven; poll is just a 1h safety net)
#         true  -> timeout.reconciliation: 60s     (fast poll)
#      The webhook is the fast sync path either way; the poll is the fallback for a dropped webhook.
#
# SINGLE SOURCE OF TRUTH (read, not duplicated):
#   - seal name/namespace          : hardcoded argocd-secret/argocd (fixed by ArgoCD; webhook.github.secret
#                                     is only ever read from argocd-secret)
#   - the poll cadence knob         <- .env POLL_SYNC_ENABLED
#   - the argocd host (webhook URL) <- 08_platform_ingress/values.yaml (the ingress that owns the edge)
# Written by this script:
#   - argo_apps/platform/charts/01_argocd/templates/argocd-secret-sealedsecret.yaml  (the sealed secret)
#   - argo_apps/platform/charts/01_argocd/values.yaml  (.argo-cd.configs.cm.timeout.reconciliation)
#   - secrets/argocd-github-webhook-secret.txt  (plaintext, gitignored; paste into GitHub)
#
# Native kubeseal + kubectl + yq + openssl (hard-fails if missing); apply-to-cluster work is native, like
# 05/07/09. Talks to the cluster via the step-03 kubeconfig (kubeseal fetches the controller's cert).
#
# NB createSecret:false means argocd-server auto-creates argocd-secret before the sealed-secrets controller
# exists; 05_argocd.sh (and, belt-and-suspenders, this script) annotates that live Secret patch-managed so
# the merge is allowed. Poll is disabled by default, so after committing you must let ArgoCD pick up the
# push (the bootstrap orchestrator hard-refreshes for you; on a live cluster, refresh the argocd app or wait
# out the fallback poll). See 05_gitops.md.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
ARGOCD_CHART="${REPO_ROOT}/argo_apps/platform/charts/01_argocd"                  # the argocd wrapper chart
ARGOCD_VALUES="${ARGOCD_CHART}/values.yaml"                                      # poll cadence patched here
SEALED_OUT="${ARGOCD_CHART}/templates/argocd-secret-sealedsecret.yaml"           # sealed webhook secret (committed)
INGRESS_VALUES="${REPO_ROOT}/argo_apps/platform/charts/08_platform_ingress/values.yaml"  # source of the argocd host
SEAL_NAME="argocd-secret"           # ArgoCD reads webhook.github.secret ONLY from the Secret named argocd-secret
SEAL_NAMESPACE="argocd"
WEBHOOK_KEY="webhook.github.secret"  # the argocd-secret data key ArgoCD's GitHub webhook handler reads
WEBHOOK_FILE="${CLUSTER_DIR}/argocd-github-webhook-secret.txt"  # plaintext for GitHub (gitignored off-repo store)
# -----------------------------------------------------------------------------

# === 0. prereqs ==============================================================
say "prerequisites"
require kubeseal kubectl yq openssl
use_kubeconfig
[ -f "$ARGOCD_VALUES" ]  || die "missing ${ARGOCD_VALUES} (the 01_argocd chart should ship it)"
[ -f "$INGRESS_VALUES" ] || die "missing ${INGRESS_VALUES} (the 08_platform_ingress chart should ship it)"
assert_api
kubectl get pods -n "$SS_CONTROLLER_NS" -l "$SS_POD_SELECTOR" >/dev/null 2>&1 \
  || die "sealed-secrets controller not reachable in ns/${SS_CONTROLLER_NS}, is it synced? (kubectl -n ${SS_CONTROLLER_NS} get pods)"
ok "kubeseal/kubectl/yq/openssl present, API + sealed-secrets controller reachable"

# === 1. resolve the poll cadence from .env ===================================
say "poll cadence from .env POLL_SYNC_ENABLED=${POLL_SYNC_ENABLED}"
case "$POLL_SYNC_ENABLED" in
  true)  RECON="60s"   ;;   # fast poll
  false) RECON="3600s" ;;   # webhook-driven; poll is a 1h safety net
  *)     die "POLL_SYNC_ENABLED must be true or false in .env (got '${POLL_SYNC_ENABLED}')" ;;
esac
ok "timeout.reconciliation -> ${RECON}"

# === 2. generate (or reuse) the webhook shared secret -> secrets/ ============
# Idempotent: reuse the stored plaintext so the secret you configured in GitHub stays valid across re-runs.
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

# === 3. seal it into argocd-secret (merge / patch-mode) ======================
# Reuse the shared seal_secret helper (single key, strict scope, sanity checks), then decorate the generated
# template so the controller MERGES into argocd-secret instead of replacing it:
#   - sealedsecrets.bitnami.com/patch: "true"  -> merge webhook.github.secret in, KEEP server.secretkey
#   - app.kubernetes.io/part-of: argocd         -> the label ArgoCD's secret informer selects on
# The patch annotation must ALSO be on the LIVE argocd-secret for the first merge (step 4 / 05_argocd.sh).
say "sealing ${WEBHOOK_KEY} -> ${SEALED_OUT}"
seal_secret "$SEAL_NAME" "$SEAL_NAMESPACE" "$WEBHOOK_KEY" "$WEBHOOK_SECRET" "$SEALED_OUT"
if [ -s "$SEALED_OUT" ]; then
  if yq -i '.spec.template.metadata.annotations."sealedsecrets.bitnami.com/patch" = "true"
          | .spec.template.metadata.labels."app.kubernetes.io/part-of" = "argocd"' "$SEALED_OUT"; then
    [ "$(yq -r '.spec.template.metadata.annotations."sealedsecrets.bitnami.com/patch"' "$SEALED_OUT")" = "true" ] \
      && ok "template annotated patch-managed + labelled part-of=argocd" || bad "patch annotation not written"
  else
    bad "yq failed to decorate the SealedSecret template (patch annotation / part-of label)"
  fi
fi

# === 4. mark the LIVE argocd-secret patch-managed (belt-and-suspenders) ======
# 05_argocd.sh already does this in both orchestrators; repeat it here so a standalone run (e.g.
# `make configure-argocd-webhook` on a live cluster) is self-sufficient. Without the annotation on the
# EXISTING Secret, the controller refuses to touch the argocd-server-created argocd-secret. Best-effort.
say "marking the live argocd-secret patch-managed"
if kubectl -n "$SEAL_NAMESPACE" get secret "$SEAL_NAME" >/dev/null 2>&1; then
  kubectl -n "$SEAL_NAMESPACE" annotate secret "$SEAL_NAME" sealedsecrets.bitnami.com/patch=true --overwrite >/dev/null 2>&1 \
    && ok "live ${SEAL_NAME} annotated patch-managed" || warn "could not annotate live ${SEAL_NAME}; do it by hand if the merge is refused"
else
  warn "live ${SEAL_NAME} not present yet (created by argocd-server); 05_argocd.sh annotates it, or annotate by hand later"
fi

# === 5. patch the poll cadence into the argocd chart values ==================
say "writing timeout.reconciliation=${RECON} into ${ARGOCD_VALUES}"
if RECON="$RECON" yq -i '.["argo-cd"].configs.cm."timeout.reconciliation" = strenv(RECON)' "$ARGOCD_VALUES"; then
  [ "$(yq -r '.["argo-cd"].configs.cm."timeout.reconciliation"' "$ARGOCD_VALUES")" = "$RECON" ] \
    && ok "timeout.reconciliation set to ${RECON}" || bad "timeout.reconciliation not written"
else
  bad "yq failed to patch timeout.reconciliation"
fi

# === 6. summary + how to finish in GitHub ====================================
ARGOCD_DOMAIN="$(yq -r '.ingress.ingresses[] | select(.hosts[].subdomain == "argocd") | .domain' "$INGRESS_VALUES" 2>/dev/null | head -1)"
WEBHOOK_URL="https://argocd.${ARGOCD_DOMAIN:-<domain>}/api/webhook"

summary
if [ "$FAIL" -eq 0 ]; then
  cat <<EOF

ArgoCD webhook wired. Finish in TWO places:

1. Commit + push so ArgoCD unseals + applies the secret and the new poll cadence:
     git add -A && git commit -m "argocd: github webhook sync" && git push
   Poll is a slow ${RECON} fallback, so ArgoCD won't pick this up fast on its own yet: either wait out the
   fallback, hard-refresh the argocd app, or (first time) run the webhook to prove it end-to-end.

2. Add the webhook in the GitHub repo (Settings -> Webhooks -> Add webhook):
     Payload URL   : ${WEBHOOK_URL}
     Content type  : application/json
     Secret        : the contents of ${WEBHOOK_FILE}
     SSL verification : ENABLED  (needs the letsencrypt-PROD cert on argocd.${ARGOCD_DOMAIN:-<domain>})
     Events        : Just the push event
   Then push a trivial commit and watch: kubectl -n argocd get applications -w  (refreshes in seconds).

Rotate the secret: delete ${WEBHOOK_FILE}, re-run this script, commit/push, update the GitHub webhook secret.
See 05_gitops.md (Webhook-driven sync).
EOF
else
  echo "Something failed, see above. Fix and re-run (idempotent)."
fi
[ "$FAIL" -eq 0 ]
