#!/usr/bin/env bash
#
# 03d_talos_cluster_config.sh  (macOS)
#
# Brings up the Talos control-plane cluster from NVMes already flashed (03b) and
# booted into maintenance mode at their (router-reserved) IPs.
#
# Self-contained: talosctl runs as a pinned Docker image — no host talosctl, no
# shell functions, no PATH games. Generated configs land in ./talos-cluster next
# to this script; the container mounts that dir as /work so every talosctl call
# (generate, apply, config, bootstrap, kubeconfig) sees the same files.
#
# Requires: docker, with host networking enabled in Docker Desktop
#           (Settings -> Resources -> Network -> Enable host networking).
#
# Cluster name, VIP, disk, NIC, and the node list all come from 03_config.sh.
#
set -euo pipefail

# All config (talosctl version, CLUSTER_*, INSTALL_DISK, IFACE, CLUSTER_NODES) in 03_config.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/03_config.sh"

command -v docker >/dev/null || { echo "ERROR: docker not found"; exit 1; }

# Generated configs live next to this script, regardless of where it's invoked from.
OUTDIR="${SCRIPT_DIR}/talos-cluster"
mkdir -p "${OUTDIR}"

# Dockerized talosctl: OUTDIR mounted as /work, its talosconfig used, host network.
# Paths passed to talosctl below are relative to /work (= ${OUTDIR} on the host).
talosctl() {
  docker run --rm \
    --network host \
    -v "${OUTDIR}:/work" \
    -w /work \
    -e TALOSCONFIG=/work/talosconfig \
    "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" "$@"
}

# Working vars from shared config (IFACE is used directly).
CLUSTER="$CLUSTER_NAME"; DISK="$INSTALL_DISK"; EPHEMERAL="$EPHEMERAL_SIZE"; VIP="$CLUSTER_VIP"
HOSTNAMES=(); IPS=()
for e in "${CLUSTER_NODES[@]}"; do HOSTNAMES+=("${e%%:*}"); IPS+=("${e##*:}"); done

echo "== Talos cluster setup (talosctl ${TALOSCTL_VERSION}, dockerized) =="
echo "Cluster:  ${CLUSTER}     VIP: ${VIP}     NIC: ${IFACE}"
echo "Disk:     ${DISK}        EPHEMERAL cap: ${EPHEMERAL}"
for i in "${!IPS[@]}"; do echo "  ${HOSTNAMES[$i]}  ->  ${IPS[$i]}"; done
echo "Output:   ${OUTDIR}"
read -r -p ">> proceed? type YES: " ok; [ "${ok}" = "YES" ] || { echo aborted; exit 1; }

# 1. Secrets + base machine config (generated once; preserved on re-run)
if [ ! -f "${OUTDIR}/controlplane.yaml" ]; then
  talosctl gen config "${CLUSTER}" "https://${VIP}:6443" --install-disk "${DISK}"
fi

# 2. Cluster-wide control-plane patch: VIP on the wired NIC, schedulable CP, certSANs
CERTSANS="$(printf '      - %s\n' "${VIP}" "${IPS[@]}")"
cat > "${OUTDIR}/cp-patch.yaml" <<EOF
machine:
  network:
    interfaces:
      - interface: ${IFACE}
        dhcp: true
        vip:
          ip: ${VIP}
cluster:
  allowSchedulingOnControlPlanes: true
  apiServer:
    certSANs:
${CERTSANS}
EOF

# 3. Partition layout (extra config documents): cap EPHEMERAL, rest -> Longhorn
cat > "${OUTDIR}/volumes.yaml" <<EOF
---
apiVersion: v1alpha1
kind: VolumeConfig
name: EPHEMERAL
provisioning:
  diskSelector:
    match: disk.transport == "nvme"
  maxSize: ${EPHEMERAL}
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: longhorn
provisioning:
  diskSelector:
    match: disk.transport == "nvme"
  minSize: 50GiB
filesystem:
  type: xfs
EOF

# 4. Combined CP config = base + volume docs (rebuilt each run; same for all nodes)
cp "${OUTDIR}/controlplane.yaml" "${OUTDIR}/cp.yaml"
cat "${OUTDIR}/volumes.yaml" >> "${OUTDIR}/cp.yaml"

# 5. Apply to each node (file paths are relative to /work inside the container).
#    Hostname goes through the HostnameConfig document (Talos 1.12+), not the legacy
#    machine.network.hostname — gen config now ships HostnameConfig (auto: stable), and
#    setting both errors with "static hostname is already set in v1alpha1 config".
for i in "${!IPS[@]}"; do
  ip="${IPS[$i]}"; host="${HOSTNAMES[$i]}"
  echo ">> applying config to ${host} (${ip})"
  talosctl apply-config --insecure -n "${ip}" -f cp.yaml \
    -p @cp-patch.yaml \
    -p '{"apiVersion":"v1alpha1","kind":"HostnameConfig","hostname":"'"${host}"'","auto":"off"}'
done

# 6. Point talosctl at the real node IPs (NOT the VIP)
talosctl config endpoint "${IPS[@]}"
talosctl config node "${IPS[0]}"

# 7. Wait for every node to reboot into its configured state before bootstrapping.
#    apply-config (maintenance mode) reboots each node; it comes back serving the API
#    *securely* with our PKI, so a secure `version` (no --insecure) succeeding is the
#    ready signal — a maintenance-mode node only answers --insecure. Beats guessing a
#    fixed wait. nc gates the call so we don't hang on a node that's mid-reboot.
echo
echo ">> waiting for nodes to reboot into their configured state (up to 5 min each)..."
sleep 10   # let the reboots actually begin (avoids a false 'ready' before reboot)
for i in "${!IPS[@]}"; do
  ip="${IPS[$i]}"; host="${HOSTNAMES[$i]}"
  printf '   %-8s %-15s ' "$host" "$ip"
  deadline=$(( $(date +%s) + 300 ))
  until nc -z -G2 "$ip" "$API_PORT" >/dev/null 2>&1 && talosctl -e "$ip" -n "$ip" version >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || { echo "TIMEOUT"; echo "ERROR: ${ip} never came back — check its console/power"; exit 1; }
    printf '.'; sleep 5
  done
  echo "ready"
done

# 8. Bootstrap etcd ONCE, on the first node only
echo
read -r -p ">> bootstrap etcd on ${HOSTNAMES[0]} (${IPS[0]})? ONE TIME ONLY. type YES: " ok
[ "${ok}" = "YES" ] || { echo "skipped bootstrap (re-run later)."; exit 0; }
talosctl bootstrap -n "${IPS[0]}"

# 9. Wait for the cluster, then fetch kubeconfig (-> ${OUTDIR}/kubeconfig)
echo ">> waiting for cluster health (a few minutes)..."
talosctl health --wait-timeout 10m || echo "(health timed out — verify with kubectl below)"
talosctl kubeconfig .
echo
echo ">> Done."
echo ">> talosconfig: ${OUTDIR}/talosconfig   (export TALOSCONFIG=${OUTDIR}/talosconfig)"
echo ">> kubeconfig:  ${OUTDIR}/kubeconfig    (export KUBECONFIG=${OUTDIR}/kubeconfig && kubectl get nodes -o wide)"
