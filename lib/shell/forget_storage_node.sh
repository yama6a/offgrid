#!/usr/bin/env bash
# Deletes NODE's Longhorn node record after the Kubernetes node is gone. Without this, Longhorn keeps listing a
# down node that will never return.
#
# Example hook: POST_REMOVE_STORAGE_HOOK="/abs/path/to/lib/shell/forget_storage_node.sh"
# A re-run is safe. With no record left, it does nothing.
# Usage: NODE=<hostname> forget_storage_node.sh, or make forget-storage-node NODE=<hostname>
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
LH_NS="longhorn-system"

# ---- functions ----

check_prerequisites() {
  require kubectl
  use_kubeconfig
  assert_api
  [ -n "${NODE:-}" ] || die "NODE is unset. Pass the removed node, for example NODE=talos-cp1 $0"
}

# Longhorn refuses to delete the record while the Kubernetes node exists.
# A replica record still on NODE means its eviction never finished, and that copy is lost with the disk.
assert_safe_to_forget() {
  local left
  kubectl get node "$NODE" > /dev/null 2>&1 \
    && die "the Kubernetes node ${NODE} still exists. Delete it first: kubectl delete node ${NODE}"
  left="$(kubectl -n "$LH_NS" get replicas.longhorn.io \
    -o jsonpath="{range .items[?(@.spec.nodeID==\"${NODE}\")]}{.metadata.name}{\"\n\"}{end}" 2> /dev/null | grep -c .)"
  [ "${left:-0}" -eq 0 ] || die "${left} Longhorn replica record(s) still point at ${NODE}. Check that each volume is healthy elsewhere: kubectl -n ${LH_NS} get volumes.longhorn.io"
}

# ---- main ----

case "${1:-}" in
  -h | --help)
    sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

check_prerequisites
say "dropping Longhorn's record of ${NODE}"
if ! kubectl -n "$LH_NS" get nodes.longhorn.io "$NODE" > /dev/null 2>&1; then
  ok "Longhorn has no node ${NODE}"
  exit 0
fi
assert_safe_to_forget
kubectl -n "$LH_NS" delete nodes.longhorn.io "$NODE" > /dev/null || die "Longhorn refused to delete node ${NODE}. Re-run in a minute"
ok "deleted Longhorn node ${NODE}"
