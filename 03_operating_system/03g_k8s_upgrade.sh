#!/usr/bin/env bash
#
# 03g_k8s_upgrade.sh  (macOS)
#
# Rolling, in-place upgrade of the running cluster's KUBERNETES version to KUBERNETES_VERSION (.env), via
# `talosctl upgrade-k8s`. This is the k8s-only counterpart to 03f (which upgrades the Talos OS): the two are
# independent. `talosctl upgrade --image` (03f) swaps the node OS and does NOT touch k8s; `upgrade-k8s`
# (here) rolls the control-plane static pods (apiserver/controller-manager/scheduler) + kubelet component
# versions and does NOT reboot nodes. So bumping ONLY KUBERNETES_VERSION means: run THIS, not 03f.
#
# talosctl drives the whole cluster from one endpoint: it upgrades each control-plane component in turn and
# only proceeds while the API stays healthy. No image publish step is needed (k8s images come from
# registry.k8s.io, not our GHCR installer), so unlike 03f there's no 03a prerequisite.
#
# Order when BOTH change: upgrade Talos first (03f), then k8s (03g) — a newer Talos always supports the k8s
# version it defaults to. KUBERNETES_VERSION can't exceed the pinned Talos's default (see .env); bump
# TALOS_VERSION + run 03a/03f before raising it past that ceiling, or upgrade-k8s rejects it.
#
# Self-contained: talosctl runs as a pinned Docker image against talos-cluster/ (talosconfig from 03d),
# like 03c-03f. Talos work -> Docker (the native macOS talosctl is unreliable, see 03_operating_system.md).
#
# NOT DANGEROUS_ (no wipe, no reboot; k8s control-plane roll with health gating) but it does roll the
# live control plane, so it asks for a typed 'yes'. Re-run-safe: a cluster already at the target version
# is a clean no-op, so a re-run after a mid-way failure just resumes.
#
set -euo pipefail

# KUBERNETES_VERSION / NODES / TALOSCTL_VERSION derived-or-read in lib/common.sh (from .env).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

require docker
docker info >/dev/null 2>&1 || die "docker not responding (start Rancher/Docker Desktop)"
[ -f "${CLUSTER_DIR}/talosconfig" ] || die "missing ${CLUSTER_DIR}/talosconfig, run step 03 (03d) first"

read -ra IPS <<< "$NODES"
[ "${#IPS[@]}" -gt 0 ] || die "no nodes set, edit CLUSTER_NODES in .env"

say "pulling ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION} (first run only)"
docker pull -q "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" >/dev/null

# Preflight: the cluster must answer before we touch the control plane.
talosctl -n "${IPS[0]}" version >/dev/null 2>&1 || die "cluster API not reachable via ${CLUSTER_DIR}/talosconfig (is the cluster up?)"

echo "== Kubernetes upgrade (talosctl ${TALOSCTL_VERSION}, dockerized) =="
echo "Target: k8s ${KUBERNETES_VERSION}"
echo "Nodes:  ${IPS[*]}"
echo
warn "this rolls the live control plane (apiserver/controller-manager/scheduler + kubelet). No node reboots."
printf '>> proceed with the k8s upgrade to %s? type yes: ' "${KUBERNETES_VERSION}"
read -r confirm </dev/tty 2>/dev/null || confirm=""
[ "$confirm" = "yes" ] || die "aborted"

# upgrade-k8s is cluster-wide: it discovers every control-plane node from the one endpoint and rolls each
# component in turn, gating on API health. A cluster already at the target is a no-op, so this is re-run-safe.
say "upgrading cluster to k8s ${KUBERNETES_VERSION}"
if talosctl -n "${IPS[0]}" upgrade-k8s --to "${KUBERNETES_VERSION}"; then
  ok "cluster upgraded to k8s ${KUBERNETES_VERSION}"
else
  die "k8s upgrade failed (see above). Cluster left as-is; fix and re-run (idempotent, resumes)."
fi

say "K8S UPGRADE COMPLETE"
echo "   target: k8s ${KUBERNETES_VERSION}"
echo "   verify: kubectl get nodes   (VERSION column shows the new kubelet on every node)"
