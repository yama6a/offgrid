#!/usr/bin/env bash
#
# 03f_talos_upgrade.sh  (macOS)
#
# Rolling, in-place upgrade of the running Talos cluster (from 03d) to the installer image 03a published
# to GHCR (${INSTALLER_REF}). NO reflash: Talos upgrades are atomic A/B with rollback, one node reboots
# into the new system while the other two hold etcd quorum, then the next. talosctl drives one node at a
# time and refuses to proceed if a reboot would break quorum.
#
# We CORDON + DRAIN each node ourselves (native kubectl) BEFORE talosctl upgrade, so Talos's own in-upgrade
# drain finds an empty node and can't hang on a PDB or a slow-terminating pod (which is what stalls it).
# A Longhorn volume-health gate runs first so we never reboot a node holding a volume's last healthy
# replica. See 03_operating_system.md for the full why.
#
# The nodes PULL the installer using the read:packages auth 03d baked into their machine config, so a
# PRIVATE ${INSTALLER_PACKAGE} works with no extra steps here.
#
# This upgrades the Talos OS only; it does NOT change the Kubernetes version. k8s is a separate, no-reboot
# roll — bump KUBERNETES_VERSION in versions.env and run 03g_k8s_upgrade.sh. If both changed, run 03f then 03g.
#
# Prereqs:
#   - 03a was run with GITHUB_GHCR_PUSH_TOKEN_SECRET set, so ${INSTALLER_REF} exists on GHCR.
#   - The nodes can pull it: either the GHCR package is PUBLIC, or 03d was run with a
#     GITHUB_GHCR_PULL_TOKEN_SECRET set (baked into the machine config). Otherwise the pull 401s and the
#     upgrade fails, re-run 03d with the pull token, or make the package public.
#   - The cluster is up (03d).
#
# Mixed tooling: talosctl runs as a pinned Docker image against secrets/ (talosconfig from 03d), like
# 03c-03e (Talos work -> Docker; the native macOS talosctl is unreliable, see 03_operating_system.md). The
# drain is a cluster op, so it uses NATIVE kubectl (apply-to-cluster -> native, like 04/05).
#
# NOT DANGEROUS_ (atomic A/B with rollback, not a wipe) but it reboots every node in turn, so it asks for
# a typed 'yes'. Re-run-safe: a node already on the target image is a clean no-op, so a re-run after a
# mid-way failure just resumes.
#
set -euo pipefail

# Node list (CLUSTER_NODES) in .env; INSTALLER_REF / NODES / TALOSCTL_VERSION derived in lib/shell/common.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
HEALTH_TIMEOUT=1800   # secs to wait per node for reboot + installer pull + rejoin-healthy (nodes pull the
                      # image over your home link, so keep this generous; matches talosctl's own default)
# Pre-drain (this script cordons+drains each node BEFORE talosctl upgrade, so Talos's own in-upgrade drain
# finds an empty node and can't hang on a PDB or a slow-terminating pod). See 03_operating_system.md.
VOLUME_HEALTH_TIMEOUT=1800  # secs: wait for ALL Longhorn volumes healthy before draining a node (a degraded
                            # volume = the node may hold its last replica; also waits out the prev node's
                            # post-reboot resync). Longhorn auto-rebuilds onto the spare node while we wait.
GRACEFUL_DRAIN_TIMEOUT=120  # secs: bounded polite drain (honors eviction) before escalating to force
FORCE_GRACE=20              # secs: grace-period on the force-delete of stragglers (let rabbit flush; 0=now)
# -----------------------------------------------------------------------------

require docker kubectl
docker info >/dev/null 2>&1 || die "docker not responding (start Rancher/Docker Desktop)"
[ -f "${CLUSTER_DIR}/talosconfig" ] || die "missing ${CLUSTER_DIR}/talosconfig, run step 03 (03d) first"
use_kubeconfig                                    # KUBECONFIG from secrets/ (native kubectl drives the drain)
assert_api                                        # kubectl must reach the API before we start rebooting

# node_for_ip <ip> -> the k8s node name whose InternalIP == <ip> (Talos nodes are addressed by IP, kubectl by name)
node_for_ip() {
  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' \
    | awk -v ip="$1" '$2==ip{print $1; exit}'
}

# wait_volumes_healthy -> block until no Longhorn volume is degraded/faulted, or die after VOLUME_HEALTH_TIMEOUT.
# Rebooting a node that holds a volume's LAST healthy replica loses that data; a `degraded` volume is exactly
# when that risk exists. Detached volumes report `unknown` (fine). Re-running resumes once Longhorn rebuilds.
wait_volumes_healthy() {
  local deadline unhealthy
  deadline=$(( $(date +%s) + VOLUME_HEALTH_TIMEOUT ))
  while :; do
    unhealthy="$(kubectl -n longhorn-system get volumes.longhorn.io \
      -o jsonpath='{range .items[?(@.status.robustness=="degraded")]}{.metadata.name}{"\n"}{end}{range .items[?(@.status.robustness=="faulted")]}{.metadata.name}{"\n"}{end}' \
      2>/dev/null | grep -c . || true)"
    [ "${unhealthy:-0}" -eq 0 ] && return 0
    [ "$(date +%s)" -ge "$deadline" ] && die "Longhorn still has ${unhealthy} degraded/faulted volume(s) after ${VOLUME_HEALTH_TIMEOUT}s; not draining (would risk a last-replica reboot). Fix storage, then re-run (idempotent)."
    printf '.'; sleep 15
  done
}

# drain_node <node> -> cordon, then a bounded graceful drain; force-delete any stragglers so the node can
# ALWAYS reboot (these pods can't relocate — node-local storage / per-node engine / hard anti-affinity —
# so a graceful drain can only kill them; they come back on the same node after the reboot).
drain_node() {
  local node="$1"
  kubectl cordon "$node" >/dev/null
  if ! kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data \
        --timeout="${GRACEFUL_DRAIN_TIMEOUT}s" >/dev/null 2>&1; then
    warn "graceful drain of ${node} timed out; force-deleting stragglers"
    kubectl delete pod --all-namespaces --field-selector "spec.nodeName=${node}" \
      --force --grace-period="${FORCE_GRACE}" >/dev/null 2>&1 || true
  fi
}

# Don't strand a node cordoned if we die mid-node (drain/upgrade failure); Talos also uncordons on rejoin.
DRAINING_NODE=""
trap '[ -n "$DRAINING_NODE" ] && kubectl uncordon "$DRAINING_NODE" >/dev/null 2>&1 || true' EXIT

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
  node="$(node_for_ip "$ip")"
  [ -n "$node" ] || die "no k8s node has InternalIP ${ip} (is the cluster up / .env CLUSTER_NODES right?)"

  # Gate on Longhorn health BEFORE cordoning (an abort here leaves no stray cordon): never drain a node
  # while a volume is degraded — that's when this node might hold its last healthy replica.
  say "waiting for all Longhorn volumes healthy before draining ${node} (${ip})"
  wait_volumes_healthy

  # Pre-drain ourselves so Talos's own in-upgrade drain is a fast no-op (can't hang on a PDB / slow pod).
  say "draining ${node}"
  DRAINING_NODE="$node"
  drain_node "$node"

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

  kubectl uncordon "$node" >/dev/null 2>&1 || true   # Talos uncordons on rejoin; make it explicit/idempotent
  DRAINING_NODE=""
done

say "ROLLING UPGRADE COMPLETE"
echo "   image:  ${INSTALLER_REF}"
echo "   verify: talosctl version   (server tag on every node)   /   kubectl get nodes"
echo "   note:   this did NOT change the k8s version; for that run 03g_k8s_upgrade.sh"
