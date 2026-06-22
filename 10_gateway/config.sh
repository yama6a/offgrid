#!/usr/bin/env bash
#
# config.sh — shared knobs for step 10 (ingress gateway + Let's Encrypt).
#
# Sourced by 10_gateway.sh. The script writes these into the gateway wrapper chart's values.yaml
# (acme.email + baseDomain) via yq, so the shell side and ArgoCD render the SAME values. This file
# is the source of truth for them; edit here and re-run 10_gateway.sh — don't hand-edit values.yaml.
# Override per-run via env, e.g. `BASE_DOMAIN=example.com ./10_gateway.sh`.

# ---- knobs ------------------------------------------------------------------
# ACME registration email for the Let's Encrypt ClusterIssuers (account-level; expiry notices here).
LE_EMAIL="${LE_EMAIL:-letsencrypt@example.com}"
# Base domain for cluster-hosted app hostnames. Host names are derived as <subdomain>.<baseDomain>,
# e.g. the gateway-test echo app becomes gateway-test.${BASE_DOMAIN}.
BASE_DOMAIN="${BASE_DOMAIN:-example.com}"
# -----------------------------------------------------------------------------
