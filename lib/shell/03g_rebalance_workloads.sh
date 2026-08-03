#!/usr/bin/env bash
# Rolling-restarts the stateless Deployments so the scheduler re-spreads them after 03e's node-by-node drain.
# A nudge, not guaranteed balance: the scheduler scores each pod alone. Not needed after 03f, which moves no pods.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
SKIP_NAMESPACES="longhorn-system envoy-gateway-system"  # CSI sidecars mid-volume-op; the ingress data plane
ROLLOUT_TIMEOUT=300   # secs per Deployment; restarts are serial, maxSurge doubles pods and 3 Pi 5s are RAM-tight

require kubectl
use_kubeconfig
assert_api

say "checking every node is Ready and schedulable"   # restarting now would just pack the survivors
NODES_JSON=$(kubectl get nodes -o json) || die "could not list nodes"
NOT_OK=$(printf '%s' "$NODES_JSON" | python3 -c '
import json,sys
for n in json.load(sys.stdin)["items"]:
    name = n["metadata"]["name"]
    ready = next((c["status"] for c in n["status"]["conditions"] if c["type"] == "Ready"), "Unknown")
    if n["spec"].get("unschedulable"): print(f"{name} (cordoned)")
    elif ready != "True":              print(f"{name} (Ready={ready})")
')
[ -z "$NOT_OK" ] || die "not rebalancing, these nodes cannot take pods: ${NOT_OK//$'\n'/, }. Wait for them to
come back (or uncordon), then re-run: make rebalance-workloads"
NODE_COUNT=$(printf '%s' "$NODES_JSON" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["items"]))')
[ "$NODE_COUNT" -eq "${#CLUSTER_NODES[@]}" ] \
  || die "cluster has ${NODE_COUNT} nodes, .env CLUSTER_NODES expects ${#CLUSTER_NODES[@]}; rebalancing now would skew the spread"
ok "all ${NODE_COUNT} nodes Ready and schedulable"

pods_per_node() {
  kubectl get pods -A --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c | sed 's/^/   /'
}

say "pod spread before"
pods_per_node

# Test a PVC, not a name: operator-generated names (vmsingle-<cr>) would rot a list.
SELECTION=$(kubectl get deploy -A -o json | SKIP_NS="$SKIP_NAMESPACES" python3 -c '
import json,os,sys
skip_ns = set(os.environ["SKIP_NS"].split())
for d in json.load(sys.stdin)["items"]:
    ns, name = d["metadata"]["namespace"], d["metadata"]["name"]
    spec = d["spec"]
    pvcs = [v for v in (spec["template"]["spec"].get("volumes") or []) if "persistentVolumeClaim" in v]
    if   ns in skip_ns:              verdict = "SKIP\tnamespace in SKIP_NAMESPACES"
    elif pvcs:                       verdict = "SKIP\tmounts a PVC, not stateless"
    elif not spec.get("replicas"):   verdict = "SKIP\tscaled to 0"
    else:                            verdict = "DO\t"
    print(f"{verdict}\t{ns}\t{name}")
') || die "could not list deployments"

printf '%s\n' "$SELECTION" | grep -q . || die "no deployments found, is this the right cluster?"

say "skipping"
printf '%s\n' "$SELECTION" | awk -F'\t' '$1=="SKIP"{printf "   %s/%s  (%s)\n", $3, $4, $2}'

TARGETS=$(printf '%s\n' "$SELECTION" | awk -F'\t' '$1=="DO"{print $3"\t"$4}')
say "restarting $(printf '%s\n' "$TARGETS" | grep -c .) deployments, one at a time"
while IFS=$'\t' read -r ns name; do
  [ -n "$ns" ] || continue
  if ! kubectl -n "$ns" rollout restart "deployment/${name}" >/dev/null 2>&1; then
    bad "${ns}/${name} (restart not accepted)"; continue
  fi
  if kubectl -n "$ns" rollout status "deployment/${name}" --timeout="${ROLLOUT_TIMEOUT}s" >/dev/null 2>&1; then
    ok "${ns}/${name}"
  else
    bad "${ns}/${name} (not Available within ${ROLLOUT_TIMEOUT}s, check: kubectl -n ${ns} describe deploy ${name})"
  fi
done <<< "$TARGETS"

say "pod spread after"
pods_per_node

summary || exit 1
