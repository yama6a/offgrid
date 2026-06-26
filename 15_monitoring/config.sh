#!/usr/bin/env bash
#
# config.sh — shared knobs for step 15 (monitoring: Alertmanager email wiring).
#
# Sourced by 15_alertmanager_secret.sh. NON-SECRET knobs ONLY. The SMTP app-password is prompted and
# sealed; it never lands here or in git. The namespace, secret name and chart paths are knobs so the
# script is reusable; override per-run via env if needed.

# ---- knobs ------------------------------------------------------------------
# The sealed-secrets controller to seal against (kubeseal --controller-namespace/--controller-name).
# Matches 02_sealed_secrets (fullnameOverride: sealed-secrets in its values.yaml).
SS_CONTROLLER_NS="${SS_CONTROLLER_NS:-sealed-secrets}"
SS_CONTROLLER_NAME="${SS_CONTROLLER_NAME:-sealed-secrets}"

# SMTP smarthost Alertmanager relays through (Gmail submission). host:port.
SMTP_SMARTHOST="${SMTP_SMARTHOST:-smtp.gmail.com:587}"

# The monitoring namespace + the Secret the Alertmanager pod mounts (alertmanagerSpec.secrets).
# The Secret data key is `password`; mounted at /etc/alertmanager/secrets/<name>/password.
MONITORING_NS="${MONITORING_NS:-monitoring}"
SMTP_SECRET_NAME="${SMTP_SECRET_NAME:-alertmanager-smtp}"
SMTP_SECRET_KEY="${SMTP_SECRET_KEY:-password}"
# -----------------------------------------------------------------------------
