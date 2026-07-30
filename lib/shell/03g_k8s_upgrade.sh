#!/usr/bin/env bash
# Rolling, in-place upgrade of the cluster's KUBERNETES version to KUBERNETES_VERSION, via
# `talosctl upgrade-k8s`. The counterpart to 03f, which upgrades the OS; the two are independent, so bumping
# only KUBERNETES_VERSION means running THIS, not 03f. It rolls the control-plane static pods and kubelet
# versions and reboots nothing.
# KUBERNETES_VERSION cannot exceed the pinned Talos's default: bump TALOS_VERSION and run 03a/03f before
# raising it past that ceiling, or upgrade-k8s rejects it.
# Re-run-safe: a cluster already at the target version is a clean no-op.
set -euo pipefail

# KUBERNETES_VERSION / NODES / TALOSCTL_VERSION derived-or-read in lib/shell/common.sh (from versions.env + .env).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

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
