#!/usr/bin/env bash
#
# config.sh — shared knobs for step 16 (Grafana unified-alerting SMTP password).
#
# Sourced by 16_grafana_smtp.sh. NON-SECRET knobs ONLY. The Gmail app-password is prompted and sealed; it
# never lands here or in git. The namespace, secret name and chart path are knobs so the script is
# reusable; override per-run via env if needed.

# ---- knobs ------------------------------------------------------------------
# The sealed-secrets controller to seal against (kubeseal --controller-namespace/--controller-name).
# Matches 02_sealed_secrets (fullnameOverride: sealed-secrets in its values.yaml).
SS_CONTROLLER_NS="${SS_CONTROLLER_NS:-sealed-secrets}"
SS_CONTROLLER_NAME="${SS_CONTROLLER_NAME:-sealed-secrets}"

# The monitoring namespace + the Secret Grafana reads GF_SMTP_PASSWORD from (envValueFrom in 07_grafana
# values.yaml). The data key is `password`.
MONITORING_NS="${MONITORING_NS:-monitoring}"
SMTP_SECRET_NAME="${SMTP_SECRET_NAME:-grafana-smtp}"
SMTP_SECRET_KEY="${SMTP_SECRET_KEY:-password}"
# -----------------------------------------------------------------------------
