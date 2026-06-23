#!/usr/bin/env bash
#
# config.sh — shared knobs for step 12 (Google SSO via Envoy Gateway SecurityPolicy).
#
# Sourced by 12_google_sso.sh. NON-SECRET knobs ONLY: the Google client-id and the email allowlist are
# written (plaintext, by design) into the 04_google_sso chart's values.yaml; the client SECRET is
# prompted and sealed. The SSO host, seal namespace and Secret name are NOT knobs here — the script
# reads them from the charts (gateway baseDomain + gatewayTestSso.subdomain; google-sso namespace +
# oidc.clientSecretName) so there is ONE definition of each. Override per-run via env if needed.

# ---- knobs ------------------------------------------------------------------
# The sealed-secrets controller to seal against (kubeseal --controller-namespace/--controller-name).
# Matches 02_sealed_secrets (fullnameOverride: sealed-secrets in its values.yaml).
SS_CONTROLLER_NS="${SS_CONTROLLER_NS:-sealed-secrets}"
SS_CONTROLLER_NAME="${SS_CONTROLLER_NAME:-sealed-secrets}"

# The Secret data key Envoy Gateway's OIDC clientSecret expects (do not change unless EG changes it).
CLIENT_SECRET_KEY="${CLIENT_SECRET_KEY:-client-secret}"
# -----------------------------------------------------------------------------
