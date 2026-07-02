#!/usr/bin/env bash
#
# 03f_talos_upgrade.sh  (macOS)
#
# Rolling, in-place upgrade of the running Talos cluster (from 03d) to the installer image 03a published
# to GHCR (${INSTALLER_REF}). NO reflash: Talos upgrades are atomic A/B with rollback, one node reboots
# into the new system while the other two hold etcd quorum, then the next. talosctl drives one node at a
# time and refuses to proceed if a reboot would break quorum.
#
# The nodes PULL the installer using the read:packages auth 03d baked into their machine config, so a
# PRIVATE ${INSTALLER_PACKAGE} works with no extra steps here.
#
# Prereqs:
#   - 03a was run with GITHUB_GHCR_PUSH_TOKEN_SECRET set, so ${INSTALLER_REF} exists on GHCR.
#   - The nodes can pull it: either the GHCR package is PUBLIC, or 03d was run with a
#     GITHUB_GHCR_PULL_TOKEN_SECRET set (baked into the machine config). Otherwise the pull 401s and the
#     upgrade fails, re-run 03d with the pull token, or make the package public.
#   - The cluster is up (03d).
#
# Self-contained: talosctl runs as a pinned Docker image against talos-cluster/ (talosconfig from 03d),
# like 03c-03e. Talos work -> Docker (the native macOS talosctl is unreliable, see 03_operating_system.md).
#
# NOT DANGEROUS_ (atomic A/B with rollback, not a wipe) but it reboots every node in turn, so it asks for
# a typed 'yes'. Re-run-safe: a node already on the target image is a clean no-op, so a re-run after a
# mid-way failure just resumes.
#
set -euo pipefail

# Node list (CLUSTER_NODES) in .env; INSTALLER_REF / NODES / TALOSCTL_VERSION derived in lib/common.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# ---- knobs ------------------------------------------------------------------
HEALTH_TIMEOUT=1800   # secs to wait per node for reboot + installer pull + rejoin-healthy (nodes pull the
                      # image over your home link, so keep this generous; matches talosctl's own default)
# -----------------------------------------------------------------------------

require docker
docker info >/dev/null 2>&1 || die "docker not responding (start Rancher/Docker Desktop)"
[ -f "${CLUSTER_DIR}/talosconfig" ] || die "missing ${CLUSTER_DIR}/talosconfig, run step 03 (03d) first"

read -ra IPS <<< "$NODES"
[ "${#IPS[@]}" -gt 0 ] || die "no nodes set, edit CLUSTER_NODES in .env"

say "pulling ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION} (first run only)"
docker pull -q "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" >/dev/null

# Preflight: the cluster must answer before we start rebooting nodes.
talosctl -n "${IPS[0]}" version >/dev/null 2>&1 || die "cluster API not reachable via ${CLUSTER_DIR}/talosconfig (is the cluster up?)"

echo "== Talos rolling upgrade (talosctl ${TALOSCTL_VERSION}, dockerized) =="
echo "Image:  ${INSTALLER_REF}"
echo "Nodes:  ${IPS[*]}"
echo
warn "this reboots EVERY node in turn (atomic A/B, a few min each). etcd quorum is held throughout."
printf '>> proceed with the rolling upgrade? type yes: '
read -r confirm </dev/tty 2>/dev/null || confirm=""
[ "$confirm" = "yes" ] || die "aborted"

for ip in "${IPS[@]}"; do
  say "upgrading ${ip} -> ${INSTALLER_REF}"
  # --wait tracks the node until it reboots into the new system and rejoins; a node already on the target
  # image completes immediately. talosctl won't proceed if the reboot would cost etcd quorum.
  if talosctl -n "$ip" upgrade --image "$INSTALLER_REF" --wait --timeout "${HEALTH_TIMEOUT}s"; then
    ok "${ip} upgraded"
  else
    die "${ip} upgrade failed (see above). Cluster left as-is; fix and re-run (idempotent, skips done nodes)."
  fi
  # Gate on FULL cluster health (etcd quorum fully restored) before touching the next node. A false
  # negative just stops us early; re-running resumes (the upgraded node is then a no-op).
  say "waiting for cluster health before the next node"
  talosctl -n "$ip" health --wait-timeout "${HEALTH_TIMEOUT}s" >/dev/null 2>&1 \
    || die "cluster not healthy after upgrading ${ip}; stopping. Investigate, then re-run to resume."
done

say "ROLLING UPGRADE COMPLETE"
echo "   image:  ${INSTALLER_REF}"
echo "   verify: talosctl version   (server tag on every node)   /   kubectl get nodes"
