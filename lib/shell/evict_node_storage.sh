#!/usr/bin/env bash
# Moves every Longhorn replica off NODE, then exits 0. It does not cordon, drain or wipe the node.
#
# Longhorn builds each new replica before it drops the old one, so every volume keeps its replica count.
# A wipe without this leaves each volume that had a replica on NODE on one copy until Longhorn rebuilds it.
#
# Example hook: PRE_REMOVE_STORAGE_HOOK="/abs/path/to/lib/shell/evict_node_storage.sh"
# A re-run is safe. It sets the same eviction request again and waits for what is left.
# Usage: NODE=<hostname> evict_node_storage.sh, or make evict-node-storage NODE=<hostname>
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
EVICT_TIMEOUT=7200 # seconds for Longhorn to move every replica off NODE
POLL=15
LH_NS="longhorn-system"

# ---- functions ----

check_prerequisites() {
  require kubectl python3
  use_kubeconfig
  assert_api
  [ -n "${NODE:-}" ] || die "NODE is unset. Pass the node to evict, for example NODE=talos-cp1 $0"
}

# Longhorn's own completion test: every disk on the node schedules no replica and no backing image.
_scheduled_here() {
  kubectl -n "$LH_NS" get nodes.longhorn.io "$NODE" -o json 2> /dev/null | python3 -c '
import json, sys
disks = (json.load(sys.stdin).get("status") or {}).get("diskStatus") or {}
print(sum(len(d.get("scheduledReplica") or {}) + len(d.get("scheduledBackingImage") or {}) for d in disks.values()))'
}

request_eviction() {
  kubectl -n "$LH_NS" patch nodes.longhorn.io "$NODE" --type merge \
    -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}' > /dev/null \
    || die "could not request eviction on Longhorn node ${NODE}"
  ok "scheduling off and eviction requested on ${NODE}"
}

wait_for_eviction() {
  local deadline left
  deadline=$(($(date +%s) + EVICT_TIMEOUT))
  while :; do
    left="$(_scheduled_here)"
    [ -n "$left" ] || die "could not read the disk status of Longhorn node ${NODE}"
    printf '    replicas left on %s: %s\n' "$NODE" "$left"
    [ "$left" -eq 0 ] && break
    [ "$(date +%s)" -ge "$deadline" ] && die "${left} replica(s) still on ${NODE} after ${EVICT_TIMEOUT}s. Longhorn keeps moving them, so re-run to wait for the rest."
    sleep "$POLL"
  done
  ok "no Longhorn data left on ${NODE}"
}

# ---- main ----

case "${1:-}" in
  -h | --help)
    sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

check_prerequisites
say "evicting Longhorn replicas from ${NODE}"
if ! kubectl -n "$LH_NS" get nodes.longhorn.io "$NODE" > /dev/null 2>&1; then
  ok "Longhorn has no node ${NODE}, so there is nothing to move"
  exit 0
fi
request_eviction
wait_for_eviction
