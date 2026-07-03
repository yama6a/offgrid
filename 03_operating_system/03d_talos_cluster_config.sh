#!/usr/bin/env bash
#
# 03d_talos_cluster_config.sh  (macOS)
#
# Brings up the Talos control-plane cluster from NVMes already flashed (03b) and
# booted into maintenance mode at their (router-reserved) IPs.
#
# Self-contained: talosctl runs as a pinned Docker image, no host talosctl, no
# shell functions, no PATH games. Generated configs land in ./talos-cluster next
# to this script; the container mounts that dir as /work so every talosctl call
# (generate, apply, config, bootstrap, kubeconfig) sees the same files.
#
# Requires: docker, with host networking enabled in Docker Desktop
#           (Settings -> Resources -> Network -> Enable host networking).
#
# Cluster name, VIP, disk, NIC, and the node list all come from .env.
#
set -euo pipefail

# Config (CLUSTER_*, CLUSTER_NODES, EXPECT_*) in .env; INSTALL_DISK/IFACE/TALOSCTL_VERSION derived in lib/common.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

require docker

# Generated configs live in the canonical talos-cluster dir (CLUSTER_DIR, from the lib). The lib's
# talosctl() mounts it as /work, so the paths passed below are relative to /work (= ${OUTDIR} on the host).
OUTDIR="${CLUSTER_DIR}"
mkdir -p "${OUTDIR}"

# Working vars from shared config (IFACE is used directly).
CLUSTER="$CLUSTER_NAME"; DISK="$INSTALL_DISK"; EPHEMERAL="$EPHEMERAL_SIZE"; VIP="$CLUSTER_VIP"; CNPG_SIZE="$CNPG_VOLUME_SIZE"; KVER="$KUBERNETES_VERSION"
HOSTNAMES=(); IPS=()
for e in "${CLUSTER_NODES[@]}"; do HOSTNAMES+=("${e%%:*}"); IPS+=("${e##*:}"); done

echo "== Talos cluster setup (talosctl ${TALOSCTL_VERSION}, dockerized) =="
echo "Cluster:  ${CLUSTER}     VIP: ${VIP}     NIC: ${IFACE}     k8s: ${KVER}"
echo "Disk:     ${DISK}        EPHEMERAL cap: ${EPHEMERAL}"
for i in "${!IPS[@]}"; do echo "  ${HOSTNAMES[$i]}  ->  ${IPS[$i]}"; done
echo "Output:   ${OUTDIR}"

# 0. GHCR registry auth (OPTIONAL, global). Bake a machine.registries auth into the CP patch so the
#    kubelet/CRI authenticates EVERY pull from ${GHCR_SERVER} on every node, cluster-wide, no
#    per-namespace imagePullSecrets. The token (GITHUB_GHCR_PULL_TOKEN_SECRET) comes from the gitignored .env;
#    it's the PULL token (classic, read:packages) — NOT the write:packages push token 03a uses, so a
#    compromised node can't push. It lands only in cp-patch.yaml under the gitignored talos-cluster dir,
#    never in git. Empty => no auth block (fine if every image is PUBLIC). GitHub Packages ONLY
#    authenticates with a CLASSIC token scoped read:packages.
echo
REGISTRIES_BLOCK=""
if [ -n "${GITHUB_GHCR_PULL_TOKEN_SECRET}" ]; then
  REGISTRIES_BLOCK="$(cat <<EOF
  registries:
    config:
      ${GHCR_SERVER}:
        auth:
          username: ${GHCR_USER}
          password: ${GITHUB_GHCR_PULL_TOKEN_SECRET}
EOF
)"
  echo "  -> ${GHCR_SERVER} auth (from .env GITHUB_GHCR_PULL_TOKEN_SECRET) baked into the machine config for all nodes."
else
  echo "  -> GITHUB_GHCR_PULL_TOKEN_SECRET empty in .env; skipping registry auth (fine if every image is PUBLIC)."
fi

# 1. Durable secrets bundle (secrets.yaml): the cluster's PKI — CA, service-account key, bootstrap/join
#    tokens. This is the ONE sticky artifact in this dir; everything below is disposable scratch re-rendered
#    from it each run. It's generated ONCE and never rotated, so the cluster identity (and thus the
#    talosconfig/kubeconfig that authenticate to it) survives every re-run and rebuild. Migration: if there
#    is no secrets.yaml yet but a controlplane.yaml from before this split exists, EXTRACT the bundle from it
#    so the RUNNING cluster's existing PKI is preserved — a plain `gen secrets` would mint a NEW PKI that no
#    longer matches the live nodes and would lock us out.
if [ ! -f "${OUTDIR}/secrets.yaml" ]; then
  if [ -f "${OUTDIR}/controlplane.yaml" ]; then
    say "extracting secrets.yaml from the existing controlplane.yaml (preserves the running cluster's PKI)"
    talosctl gen secrets --from-controlplane-config controlplane.yaml -o secrets.yaml
  else
    say "generating a fresh secrets.yaml (new cluster PKI — created once, never rotated)"
    talosctl gen secrets -o secrets.yaml
  fi
fi

# 1b. Render the base control-plane config FRESH each run from the durable secrets + the CURRENT .env knobs
#     (k8s version, install disk, VIP endpoint). Regenerating every run (--force) is the whole point of the
#     split: a version bump in .env actually lands here, instead of being frozen into a preserved
#     controlplane.yaml. --with-secrets reuses secrets.yaml so the re-render never rotates PKI; worker.yaml
#     is skipped (every node here is control-plane); talosconfig is re-issued off the same CA (still valid).
talosctl gen config "${CLUSTER}" "https://${VIP}:6443" \
  --with-secrets secrets.yaml \
  --install-disk "${DISK}" \
  --kubernetes-version "${KVER}" \
  --output-types controlplane,talosconfig \
  --force

# 2. Cluster-wide control-plane patch: VIP on the wired NIC, schedulable CP, certSANs
CERTSANS="$(printf '      - %s\n' "${VIP}" "${IPS[@]}")"
cat > "${OUTDIR}/cp-patch.yaml" <<EOF
machine:
${REGISTRIES_BLOCK}
  nodeLabels:
    node.kubernetes.io/instance-type: ${NODE_INSTANCE_TYPE}   # nic-keeper DaemonSet selector (03_operating_system.md)
  kubelet:
    # Longhorn's data path lives on the dedicated 'longhorn' user volume (see volumes.yaml below),
    # mounted at /var/mnt/longhorn on the host. Talos runs the kubelet in a container and does NOT
    # auto-propagate /var/mnt mounts into it, so Longhorn's pods can't see the disk without this
    # explicit bind. rshared lets Longhorn's per-replica sub-mounts propagate back to the host.
    # The 'cnpg' mount is the same idea for the local-path-provisioner that backs CNPG (off Longhorn):
    # its helper pods + the hostPath PVs both resolve /var/mnt/cnpg against the kubelet's view, so the
    # bind is required too; plain rw suffices (no sub-mount propagation like Longhorn).
    # See 08_storage.md and 08_storage.md.
    extraMounts:
      - destination: /var/mnt/longhorn
        type: bind
        source: /var/mnt/longhorn
        options: [bind, rshared, rw]
      - destination: /var/mnt/cnpg
        type: bind
        source: /var/mnt/cnpg
        options: [bind, rw]
  features:
    kubePrism:
      enabled: true
      port: 7445
  network:
    interfaces:
      - interface: ${IFACE}
        dhcp: true
        vip:
          ip: ${VIP}
cluster:
  allowSchedulingOnControlPlanes: true
  network:
    cni:
      name: none          # hand the CNI to Cilium
  proxy:
    disabled: true        # Cilium kube-proxy replacement; L2 needs it
  apiServer:
    certSANs:
${CERTSANS}
EOF

# 3. Partition layout (extra config documents): cap EPHEMERAL, carve a fixed-size 'cnpg' volume,
#    then 'longhorn' takes the remainder. The 'cnpg' volume is min==max (a fixed slice) so CNPG's
#    local-path storage can't grow into Longhorn's space; 'longhorn' has no maxSize so it grows once
#    at provision time to claim whatever is left. See 08_storage.md / 08_storage.md.
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
name: cnpg
provisioning:
  diskSelector:
    match: disk.transport == "nvme"
  minSize: ${CNPG_SIZE}
  maxSize: ${CNPG_SIZE}
filesystem:
  type: xfs
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

# 4b. Wait for every node to be in MAINTENANCE before applying. After a reset
#     (DANGEROUS_reset_talos_cluster.sh / DANGEROUS_rebuild_cluster.sh) the nodes wipe + reboot
#     asynchronously, so the apply-config --insecure below would fail on a node that hasn't come back
#     yet. A maintenance node answers --insecure; a CONFIGURED one does not (and a freshly-reset node
#     can't boot configured, STATE is wiped), so this check is never fooled by the pre-reset instance:
#     it blocks until the node is genuinely back in maintenance. nc gates the call so we don't hang on a
#     node mid-reboot. On a first install (straight off 03b) the nodes are already in maintenance, so
#     this returns immediately.
say "waiting for nodes in maintenance (up to 5 min each)..."
for i in "${!IPS[@]}"; do
  ip="${IPS[$i]}"; host="${HOSTNAMES[$i]}"
  printf '   %-8s %-15s ' "$host" "$ip"
  deadline=$(( $(date +%s) + 300 ))
  until nc -z -G2 "$ip" "$API_PORT" >/dev/null 2>&1 && talosctl -e "$ip" -n "$ip" version --insecure >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || { echo "TIMEOUT"; die "${ip} not in maintenance after 300s, check its console/power"; }
    printf '.'; sleep 5
  done
  echo "ready"
done

# 5. Apply to each node (file paths are relative to /work inside the container).
#    Hostname goes through the HostnameConfig document (Talos 1.12+), not the legacy
#    machine.network.hostname, gen config now ships HostnameConfig (auto: stable), and
#    setting both errors with "static hostname is already set in v1alpha1 config".
for i in "${!IPS[@]}"; do
  ip="${IPS[$i]}"; host="${HOSTNAMES[$i]}"
  say "applying config to ${host} (${ip})"
  talosctl apply-config --insecure -n "${ip}" -f cp.yaml \
    -p @cp-patch.yaml \
    -p '{"apiVersion":"v1alpha1","kind":"HostnameConfig","hostname":"'"${host}"'","auto":"off"}'
done

# 5b. All the rendered scratch — cp.yaml + controlplane.yaml (base config) and their inputs cp-patch.yaml +
#     volumes.yaml — has now been applied to every node; the nodes hold their own live config from here on.
#     Drop it so the only config left on disk is the durable secrets.yaml (plus the talosconfig/kubeconfig
#     creds). cp.yaml/controlplane.yaml carry cluster secrets and cp-patch.yaml carries the GHCR pull token,
#     so not leaving them lying around is a bonus; re-render is one `03d` run away. (On an apply failure
#     `set -e` exits before this line, leaving them in place for inspection.)
rm -f "${OUTDIR}/cp.yaml" "${OUTDIR}/controlplane.yaml" "${OUTDIR}/cp-patch.yaml" "${OUTDIR}/volumes.yaml"

# 6. Point talosctl at the real node IPs (NOT the VIP)
talosctl config endpoint "${IPS[@]}"
talosctl config node "${IPS[0]}"

# 7. Wait for every node to reboot into its configured state before bootstrapping.
#    apply-config (maintenance mode) reboots each node; it comes back serving the API
#    *securely* with our PKI, so a secure `version` (no --insecure) succeeding is the
#    ready signal, a maintenance-mode node only answers --insecure. Beats guessing a
#    fixed wait. nc gates the call so we don't hang on a node that's mid-reboot.
say "waiting for nodes to reboot into their configured state (up to 5 min each)..."
sleep 10   # let the reboots actually begin (avoids a false 'ready' before reboot)
for i in "${!IPS[@]}"; do
  ip="${IPS[$i]}"; host="${HOSTNAMES[$i]}"
  printf '   %-8s %-15s ' "$host" "$ip"
  deadline=$(( $(date +%s) + 300 ))
  until nc -z -G2 "$ip" "$API_PORT" >/dev/null 2>&1 && talosctl -e "$ip" -n "$ip" version >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || { echo "TIMEOUT"; die "${ip} never came back, check its console/power"; }
    printf '.'; sleep 5
  done
  echo "ready"
done

sleep 10

# 8. Bootstrap etcd ONCE, on the first node only
talosctl bootstrap -n "${IPS[0]}"

sleep 10

# 9. Wait for the cluster, then fetch kubeconfig (-> ${OUTDIR}/kubeconfig)
say "waiting for cluster health (a few minutes)..."
talosctl health --wait-timeout 10m || warn "health timed out, verify with kubectl below"
talosctl kubeconfig .
say "Done."
echo "   talosconfig: ${OUTDIR}/talosconfig   (export TALOSCONFIG=${OUTDIR}/talosconfig)"
echo "   kubeconfig:  ${OUTDIR}/kubeconfig    (export KUBECONFIG=${OUTDIR}/kubeconfig && kubectl get nodes -o wide)"
echo "   cp ~/.kube/config ~/.kube/config.bak && KUBECONFIG=\"${SCRIPT_DIR}/talos-cluster/kubeconfig:${HOME}/.kube/config\" kubectl config view --flatten > /tmp/kc && mv /tmp/kc ~/.kube/config"
