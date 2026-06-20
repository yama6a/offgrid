#!/usr/bin/env bash
#
# 03e_nic_hardening.sh  (macOS)
#
# Mitigates the Raspberry Pi 5 `macb` NIC wedge (siderolabs/sbc-raspberrypi #91) at the
# Talos machine-config level, on the running cluster from 03d. It DISCOVERS the NIC's
# facts on a live node, GENERATES config from them, APPLIES via `talosctl patch mc`
# (document-level — never a full re-apply, so the live certSAN fix is preserved), then
# VERIFIES. See 03_operating_system.md ("NIC hardening — the macb wedge").
#
# Implements now:  EthernetConfig (TSO/GSO/GRO off, rings -> max) + WatchdogTimerConfig.
# Deferred (docs): EEE-off + link-watchdog + `ss -K` DaemonSet (ArgoCD, once GitOps lands).
#
# Offload keys + rings come from Talos's own EthernetStatus resource (the canonical netdev
# feature names EthernetConfig accepts — these DIFFER from `ethtool -k`'s umbrella names).
# A short-lived privileged probe pod reads only what has no resource: EEE + watchdog device.
#
# Self-contained: talosctl AND kubectl run as pinned Docker images, mounting
# talos-cluster/ (talosconfig + kubeconfig from 03d). Never triggers the watchdog.
#
# Requires: docker (host networking enabled). The probe node needs registry pull access.
#
set -uo pipefail

# All shared config (TALOSCTL_VERSION, EXPECT_NIC, ...) lives in 03_config.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/03_config.sh"

# ---- knobs ------------------------------------------------------------------
IFACE="${IFACE:-${EXPECT_NIC}}"            # wired NIC to harden (end0)
OUTDIR="${OUTDIR:-${SCRIPT_DIR}/talos-cluster}"   # talosconfig + kubeconfig live here
KUBECTL_IMAGE="${KUBECTL_IMAGE:-registry.k8s.io/kubectl:v1.36.1}"   # ~match cluster
DEBUG_IMAGE="${DEBUG_IMAGE:-alpine:3.21}"  # probe pod; apk-installs ethtool
WATCHDOG_TIMEOUT="${WATCHDOG_TIMEOUT:-15s}"  # desired; floored to 10s (Talos min); Pi hw max ~15s
APPLY_MODE="${APPLY_MODE:-no-reboot}"      # never silently reboot control-plane nodes
# TSO / GSO / GRO -> their kernel netdev feature names (what EthernetConfig/EthernetStatus use).
OFFLOAD_KEYS=(tx-tcp-segmentation tx-generic-segmentation rx-gro)
PROBE_NS="kube-system"                     # Talos exempts kube-system from Pod Security
PROBE_POD="nic-hw-probe"
PATCH_FILE="nic-hardening-patch.yaml"      # written into OUTDIR (=/work in the container)
# -----------------------------------------------------------------------------

say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
PASS=0; FAIL=0
ok()  { printf '  \033[32m[PASS]\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

talosctl() { docker run --rm -i --network host -v "${OUTDIR}:/work" -w /work \
  -e TALOSCONFIG=/work/talosconfig "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" "$@"; }
kubectl()  { docker run --rm -i --network host -v "${OUTDIR}:/work" \
  -e KUBECONFIG=/work/kubeconfig "${KUBECTL_IMAGE}" "$@"; }

PROBE_UP=0
cleanup() { [ "$PROBE_UP" = 1 ] && kubectl delete pod "$PROBE_POD" -n "$PROBE_NS" \
  --ignore-not-found --now >/dev/null 2>&1; PROBE_UP=0; }
trap cleanup EXIT

# --- small parsers over a `get ethernetstatus -o yaml` blob -------------------
eth_status()  { talosctl -n "$1" get ethernetstatus "$IFACE" -o yaml 2>/dev/null; }
ring_max()    { awk -v k="$2-max:" '/^    rings:/{r=1} r&&$1==k{print $2;exit}' <<<"$1"; }  # $1=blob $2=rx|tx
ring_cur()    { awk -v k="$2:"     '/^    rings:/{r=1} r&&$1==k{print $2;exit}' <<<"$1"; }
feat_val()    { awk -v k="$2:" '$1==k{print $2;exit}' <<<"$1"; }                            # on|off
feat_fixed()  { grep -qE "^[[:space:]]*$2:[[:space:]]+(on|off)[[:space:]]+\[fixed\]" <<<"$1"; }

# === 0. prereqs ==============================================================
say "checking prerequisites"
command -v docker >/dev/null || die "docker not found"
docker info >/dev/null 2>&1 || die "docker not responding (start Rancher/Docker Desktop)"
[ -f "${OUTDIR}/talosconfig" ] || die "missing ${OUTDIR}/talosconfig — run 03d first"
[ -f "${OUTDIR}/kubeconfig" ]  || die "missing ${OUTDIR}/kubeconfig — run 03d first"

# === 1. node list (from talosconfig endpoints) ===============================
say "discovering nodes"
ENDPOINTS="$(talosctl config info 2>/dev/null | awk -F: '/^Endpoints/{print $2}' | tr ',' ' ')"
read -ra NODES_ARR <<< "${ENDPOINTS:-${NODES:-}}"
if [ "${#NODES_ARR[@]}" -eq 0 ]; then
  read -r -p ">> node IP(s), space-separated: " line; read -ra NODES_ARR <<< "$line"
fi
[ "${#NODES_ARR[@]}" -gt 0 ] || die "no nodes (set endpoints in talosconfig / NODES in 03_config.sh)"
echo "   nodes: ${NODES_ARR[*]}"
NODE0_IP="${NODES_ARR[0]}"

# map node IP -> kubernetes node name (to pin the probe pod)
NODEINFO="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null)"
[ -n "$NODEINFO" ] || die "kubectl could not list nodes (check ${OUTDIR}/kubeconfig)"
NODE0_NAME="$(awk -v ip="$NODE0_IP" '$2==ip{print $1; exit}' <<< "$NODEINFO")"
[ -n "$NODE0_NAME" ] || die "no k8s node has InternalIP ${NODE0_IP}"

# === 2a. discover rings + settable offload keys (from Talos EthernetStatus) ===
say "discovering ${IFACE} rings + offload keys (talosctl get ethernetstatus)"
ST="$(eth_status "$NODE0_IP")"
[ -n "$ST" ] || die "no EthernetStatus for ${IFACE} on ${NODE0_IP}"
RX_MAX="$(ring_max "$ST" rx)"; TX_MAX="$(ring_max "$ST" tx)"
RINGS_OK=0; case "${RX_MAX:-}:${TX_MAX:-}" in [0-9]*:[0-9]*) RINGS_OK=1;; esac
[ "$RINGS_OK" = 1 ] && echo "   rings max: rx=${RX_MAX} tx=${TX_MAX}" || echo "   rings: no usable max — skipping rings"

FEATURES=()
for k in "${OFFLOAD_KEYS[@]}"; do
  v="$(feat_val "$ST" "$k")"
  if [ -n "$v" ] && ! feat_fixed "$ST" "$k"; then FEATURES+=("$k"); fi
done
[ "${#FEATURES[@]}" -gt 0 ] && echo "   offloads to disable: ${FEATURES[*]}" || echo "   no settable TSO/GSO/GRO keys found"

# === 2b. probe pod for what has no resource: EEE (docs) + watchdog device =====
say "probe pod on ${NODE0_NAME} (${NODE0_IP}) — EEE + watchdog device"
kubectl delete pod "$PROBE_POD" -n "$PROBE_NS" --ignore-not-found --now >/dev/null 2>&1
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: ${PROBE_POD}, namespace: ${PROBE_NS} }
spec:
  hostNetwork: true
  nodeName: ${NODE0_NAME}
  restartPolicy: Never
  tolerations: [ { operator: Exists } ]
  containers:
  - name: probe
    image: ${DEBUG_IMAGE}
    securityContext: { privileged: true }
    command: ["/bin/sh","-c","apk add --no-cache ethtool >/dev/null 2>&1 || true; exec sleep infinity"]
    volumeMounts: [ { name: dev, mountPath: /dev } ]
  volumes: [ { name: dev, hostPath: { path: /dev } } ]
EOF
PROBE_UP=1
kubectl wait --for=condition=Ready "pod/${PROBE_POD}" -n "$PROBE_NS" --timeout=120s >/dev/null \
  || die "probe pod did not become Ready on ${NODE0_NAME}"
pexec() { kubectl exec -n "$PROBE_NS" "$PROBE_POD" -- sh -c "$1"; }
pexec 'i=0; until command -v ethtool >/dev/null 2>&1; do i=$((i+1)); [ $i -gt 60 ] && exit 1; sleep 2; done' \
  >/dev/null || die "probe image lacks ethtool (override DEBUG_IMAGE, or give the node registry access)"

DISC="${OUTDIR}/nic-discovery.txt"
pexec '
  echo "=== EEE ==="; ethtool --show-eee '"$IFACE"' 2>&1
  echo "=== WATCHDOG_DEV ==="; ls -1 /dev/watchdog* 2>&1
' > "$DISC" || die "discovery exec failed"

# prefer /dev/watchdog0 if present, else the bare device, else the Talos default
WD_DEV="$(grep -E '^/dev/watchdog0$' "$DISC" | head -1)"
[ -z "$WD_DEV" ] && WD_DEV="$(grep -E '^/dev/watchdog' "$DISC" | head -1)"
WD_DEV="${WD_DEV:-/dev/watchdog0}"
wd_secs() { case "$1" in *s) echo "${1%s}";; *) echo "$1";; esac; }
WD_T="$(wd_secs "$WATCHDOG_TIMEOUT")"; case "$WD_T" in ''|*[!0-9]*) WD_T=15;; esac
[ "$WD_T" -lt 10 ] && WD_T=10
echo "   watchdog: device=${WD_DEV} timeout=${WD_T}s (Talos min 10s; Pi hw max ~15s)"

say "EEE status (captured for the deferred DaemonSet — NOT applied now)"
sed -n '/=== EEE ===/,/=== WATCHDOG_DEV ===/p' "$DISC" | sed '1d;$d' | sed 's/^/   /'
cleanup; echo "   probe pod removed"

# === 3. generate the patches (multi-doc strategic merge) =====================
ETH_DESIRED=0; if [ "$RINGS_OK" = 1 ] || [ "${#FEATURES[@]}" -gt 0 ]; then ETH_DESIRED=1; fi
DEL_FILE="nic-eth-delete.yaml"
say "generating patches"
# EthernetConfig is delete-then-readd so the features map is authoritative each run:
# strategic merge UNIONS maps, so a stale/renamed feature key would linger and fail the
# WHOLE ethtool reconcile ("bit name not found"), leaving every offload unchanged.
if [ "$ETH_DESIRED" = 1 ]; then
  { echo "apiVersion: v1alpha1"; echo "kind: EthernetConfig"; echo "name: ${IFACE}"; echo '$patch: delete'; } > "${OUTDIR}/${DEL_FILE}"
fi
{
  if [ "$ETH_DESIRED" = 1 ]; then
    echo "apiVersion: v1alpha1"; echo "kind: EthernetConfig"; echo "name: ${IFACE}"
    [ "$RINGS_OK" = 1 ] && { echo "rings:"; echo "  rx: ${RX_MAX}"; echo "  tx: ${TX_MAX}"; }
    if [ "${#FEATURES[@]}" -gt 0 ]; then echo "features:"; for k in "${FEATURES[@]}"; do echo "  ${k}: false"; done; fi
    echo "---"
  fi
  echo "apiVersion: v1alpha1"; echo "kind: WatchdogTimerConfig"
  echo "device: ${WD_DEV}"; echo "timeout: ${WD_T}s"
} > "${OUTDIR}/${PATCH_FILE}"
sed 's/^/   /' "${OUTDIR}/${PATCH_FILE}"

# === 4. apply to EVERY node (document merge — preserves v1alpha1 certSANs) ====
say "applying to all nodes (talosctl patch mc, --mode ${APPLY_MODE})"
for ip in "${NODES_ARR[@]}"; do
  # drop any prior EthernetConfig first (clears stale keys); ignore "not found" on fresh nodes
  [ "$ETH_DESIRED" = 1 ] && talosctl -n "$ip" patch mc --patch "@${DEL_FILE}" --mode "${APPLY_MODE}" >/dev/null 2>&1
  out="$(talosctl -n "$ip" patch mc --patch "@${PATCH_FILE}" --mode "${APPLY_MODE}" 2>&1)"; rc=$?
  if [ $rc -eq 0 ]; then ok "patched ${ip}"; else
    bad "patch ${ip} failed: $(tail -1 <<< "$out")"
    grep -qi 'reboot' <<< "$out" && echo "         (a reboot would be required — refusing; not rebooting control-plane nodes)"
  fi
done

# === 5. verify (authoritative resources, per node, polled for the async apply) =
say "verify — EthernetConfig in effect (EthernetStatus) on every node"
for ip in "${NODES_ARR[@]}"; do
  st=""; rxok=0; txok=0; offok=0
  for _ in $(seq 1 30); do                   # up to ~150s (the EthernetSpec controller backs off after errors)
    st="$(eth_status "$ip")"
    if [ "$RINGS_OK" = 1 ]; then
      [ "$(ring_cur "$st" rx)" = "$RX_MAX" ] && rxok=1 || rxok=0
      [ "$(ring_cur "$st" tx)" = "$TX_MAX" ] && txok=1 || txok=0
    else rxok=1; txok=1; fi
    offok=1; for k in "${FEATURES[@]}"; do [ "$(feat_val "$st" "$k")" = off ] || offok=0; done
    [ $rxok = 1 ] && [ $txok = 1 ] && [ $offok = 1 ] && break
    sleep 3
  done
  for k in "${FEATURES[@]}"; do
    [ "$(feat_val "$st" "$k")" = off ] && ok "${ip}: ${k} = off" || bad "${ip}: ${k} still $(feat_val "$st" "$k")"
  done
  if [ "$RINGS_OK" = 1 ]; then
    [ $rxok = 1 ] && ok "${ip}: ring rx = ${RX_MAX} (max)" || bad "${ip}: ring rx = $(ring_cur "$st" rx) != ${RX_MAX}"
    [ $txok = 1 ] && ok "${ip}: ring tx = ${TX_MAX} (max)" || bad "${ip}: ring tx = $(ring_cur "$st" tx) != ${TX_MAX}"
  fi
done

say "verify — watchdog armed (WatchdogTimerStatus) on every node"
for ip in "${NODES_ARR[@]}"; do
  ws="$(talosctl -n "$ip" get watchdogtimerstatus -o yaml 2>/dev/null)"
  if grep -q "timeout: ${WD_T}s" <<< "$ws" && grep -q 'device:' <<< "$ws"; then
    ok "${ip}: watchdog armed ($(awk '/device:/{print $2}' <<<"$ws"), ${WD_T}s)"
  else
    bad "${ip}: watchdog not armed"
  fi
done

# === 6. summary ==============================================================
echo ""
echo "=============== summary: ${PASS} passed, ${FAIL} failed ==============="
if [ "$FAIL" -eq 0 ]; then
  echo "NIC machine-config defences applied + verified. Next (deferred, ArgoCD):"
  echo "  EEE-off + link-watchdog + 'ss -K' DaemonSet — see 03_operating_system.md."
else
  echo "Some checks failed. If 'patch mc' demanded a reboot it was refused (see above);"
  echo "if the watchdog wasn't armed, lower WATCHDOG_TIMEOUT (Pi hw max ~15s)."
fi
[ "$FAIL" -eq 0 ]
