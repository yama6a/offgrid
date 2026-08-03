#!/usr/bin/env bash
# Brings up the Talos control-plane cluster from NVMes already flashed (03b) and booted into maintenance at
# their router-reserved IPs. Generated configs land in secrets/, which the talosctl container mounts as
# /work so every call sees the same files.
#
# Requires: docker with host networking enabled.
set -euo pipefail

# Config (CLUSTER_*, CLUSTER_NODES) in .env; EXPECT_*/INSTALL_DISK/IFACE/TALOSCTL_VERSION in lib/shell/common.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require docker

# Durable creds live in CLUSTER_DIR, which the lib's talosctl() mounts as /work, so /work == ${OUTDIR}.
OUTDIR="${CLUSTER_DIR}"
mkdir -p "${OUTDIR}"

# Throwaway render scratch goes to an OS temp dir, so nothing lingers next to the durable creds and there is
# nothing to clean up. talosctl() mounts it at /scratch. It survives a mid-run failure for inspection.
TALOS_SCRATCH="$(mktemp -d)"
echo "Scratch:  ${TALOS_SCRATCH}   (throwaway render files; OS-reaped)"

CLUSTER="$CLUSTER_NAME"; DISK="$INSTALL_DISK"; EPHEMERAL="$EPHEMERAL_SIZE"; VIP="$CLUSTER_VIP"; LOCALPATH_SIZE="$LOCALPATH_VOLUME_SIZE"; KVER="$KUBERNETES_VERSION"
NODE_INSTANCE_TYPE="rpi5"   # node.kubernetes.io/instance-type label (nic-keeper selector); fixed to the hardware
HOSTNAMES=(); IPS=()
for e in "${CLUSTER_NODES[@]}"; do HOSTNAMES+=("${e%%:*}"); IPS+=("${e##*:}"); done

# One optional arg: a hostname to apply to ALONE, for putting a single replaced node back into a cluster that
# already exists (recover_node.sh). It narrows only the apply and the two waits; certSANs and the talosconfig
# endpoints still come from the full list, or the rejoined node would trust an apiserver cert naming just
# itself and talosctl would forget the other two. It also skips the etcd bootstrap, which creates a cluster
# rather than joining one.
TARGETS=("${!IPS[@]}")
JOIN_ONE=""
if [ $# -gt 0 ]; then
  JOIN_ONE="$1"
  TARGETS=()
  for i in "${!HOSTNAMES[@]}"; do [ "${HOSTNAMES[$i]}" = "$JOIN_ONE" ] && TARGETS=("$i"); done
  [ "${#TARGETS[@]}" -eq 1 ] || die "unknown node '${JOIN_ONE}': .env CLUSTER_NODES has ${HOSTNAMES[*]}"
fi

echo "== Talos cluster setup (talosctl ${TALOSCTL_VERSION}, dockerized) =="
echo "Cluster:  ${CLUSTER}     VIP: ${VIP}     NIC: ${IFACE}     k8s: ${KVER}"
echo "Disk:     ${DISK}        EPHEMERAL cap: ${EPHEMERAL}"
for i in "${!IPS[@]}"; do echo "  ${HOSTNAMES[$i]}  ->  ${IPS[$i]}"; done
[ -n "$JOIN_ONE" ] && echo "Applying to ${JOIN_ONE} ONLY, and NOT bootstrapping etcd (single-node rejoin)"
echo "Output:   ${OUTDIR}"

# Bakes a machine.registries auth into the CP patch, so the kubelet authenticates EVERY pull from GHCR on
# every node, with no per-namespace imagePullSecrets. It is the read:packages PULL token, NOT the
# write:packages one 03a uses, so a compromised node cannot push. It lands only in the gitignored
# secrets dir, never in git. Empty means no auth block, which is fine if every image is public.
# GitHub Packages only authenticates with a CLASSIC token.
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

# The cluster's PKI, and the ONE sticky artifact here: everything else is disposable scratch re-rendered
# from it each run. Generated once and never rotated, so the cluster identity survives every re-run.
# Migration: with no secrets.yaml but a pre-split controlplane.yaml present, EXTRACT the bundle from it. A
# plain `gen secrets` would mint a NEW PKI that no longer matches the live nodes and would lock us out.
if [ ! -f "${OUTDIR}/secrets.yaml" ]; then
  if [ -f "${OUTDIR}/controlplane.yaml" ]; then
    say "extracting secrets.yaml from the existing controlplane.yaml (preserves the running cluster's PKI)"
    talosctl gen secrets --from-controlplane-config controlplane.yaml -o secrets.yaml
  else
    say "generating a fresh secrets.yaml (new cluster PKI, created once, never rotated)"
    talosctl gen secrets -o secrets.yaml
  fi
fi

# Rendered FRESH each run from the durable secrets plus the CURRENT versions.env and .env values. That is why
# the config is split from the secrets: a version bump actually reaches the nodes, instead of being frozen
# into a controlplane.yaml we kept from last time. --with-secrets reuses secrets.yaml, so the re-render never rotates PKI.
talosctl gen config "${CLUSTER}" "https://${VIP}:6443" \
  --with-secrets secrets.yaml \
  --install-disk "${DISK}" \
  --kubernetes-version "${KVER}" \
  --output-types controlplane,talosconfig \
  --force
# gen config emits talosconfig (durable) and controlplane.yaml (throwaway) into the same dir. Move the
# throwaway one to scratch so the secrets dir keeps only durable creds.
mv "${OUTDIR}/controlplane.yaml" "${TALOS_SCRATCH}/controlplane.yaml"

# 2. Cluster-wide control-plane patch: VIP on the wired NIC, schedulable CP, certSANs
CERTSANS="$(printf '      - %s\n' "${VIP}" "${IPS[@]}")"
cat > "${TALOS_SCRATCH}/cp-patch.yaml" <<EOF
machine:
${REGISTRIES_BLOCK}
  nodeLabels:
    node.kubernetes.io/instance-type: ${NODE_INSTANCE_TYPE}   # nic-keeper DaemonSet selector (03_operating_system.md)
  kubelet:
    # Talos runs the kubelet in a container and does NOT auto-propagate /var/mnt mounts into it, so without
    # these binds Longhorn's pods and local-path's helper pods cannot see their disks.
    # longhorn gets rshared, which means mounts made inside the bind are visible on the host too. Longhorn
    # creates one sub-mount per replica and the host has to see them. localpath creates none, so plain rw is
    # enough there. See 08_storage.md.
    extraMounts:
      - destination: /var/mnt/longhorn
        type: bind
        source: /var/mnt/longhorn
        options: [bind, rshared, rw]
      - destination: /var/mnt/localpath
        type: bind
        source: /var/mnt/localpath
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
  # The defaults trigger spurious leader elections during the cold-boot I/O storm: Longhorn, CNPG and image
  # pulls saturate the single NVMe, etcd fsync stalls past a second, followers time out, and the election
  # burst lags every watch and informer. Raised 5x, keeping election at 10x heartbeat.
  etcd:
    extraArgs:
      heartbeat-interval: "500"    # ms (etcd default 100)
      election-timeout: "5000"     # ms (etcd default 1000)
  network:
    cni:
      name: none          # hand the CNI to Cilium
  proxy:
    disabled: true        # Cilium kube-proxy replacement; L2 needs it
  apiServer:
    certSANs:
${CERTSANS}
EOF

# Cap EPHEMERAL, carve a fixed-size 'localpath' volume, then let 'longhorn' take the remainder. localpath is
# min==max so it cannot grow into Longhorn's space; longhorn has no maxSize so it claims what is left, once,
# at provision time. See 08_storage.md.
cat > "${TALOS_SCRATCH}/volumes.yaml" <<EOF
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
name: localpath
provisioning:
  diskSelector:
    match: disk.transport == "nvme"
  minSize: ${LOCALPATH_SIZE}
  maxSize: ${LOCALPATH_SIZE}
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
cp "${TALOS_SCRATCH}/controlplane.yaml" "${TALOS_SCRATCH}/cp.yaml"
cat "${TALOS_SCRATCH}/volumes.yaml" >> "${TALOS_SCRATCH}/cp.yaml"

# 4b. Wait for every node to be in MAINTENANCE before applying. After a reset
#     (DANGEROUS_reset_talos_cluster.sh / DANGEROUS_rebuild_cluster.sh) the nodes wipe + reboot
#     asynchronously, so the apply-config --insecure below would fail on a node that hasn't come back
#     yet. A maintenance node answers --insecure; a CONFIGURED one does not (and a freshly-reset node
#     can't boot configured, STATE is wiped), so this check is never fooled by the pre-reset instance:
#     it blocks until the node is genuinely back in maintenance. nc gates the call so we don't hang on a
#     node mid-reboot. On a first install (straight off 03b) the nodes are already in maintenance, so
#     this returns immediately.
say "waiting for nodes in maintenance (up to 5 min each)..."
for i in "${TARGETS[@]}"; do
  ip="${IPS[$i]}"; host="${HOSTNAMES[$i]}"
  printf '   %-8s %-15s ' "$host" "$ip"
  deadline=$(( $(date +%s) + 300 ))
  until nc -z -G2 "$ip" "$API_PORT" >/dev/null 2>&1 && talosctl -e "$ip" -n "$ip" version --insecure >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || { echo "TIMEOUT"; die "${ip} not in maintenance after 300s, check its console/power"; }
    printf '.'; sleep 5
  done
  echo "ready"
done

# 5. Apply to each node. cp.yaml/cp-patch.yaml live in the scratch dir, mounted at /scratch in the
#    container (the rest of the paths are relative to /work). Hostname goes through the HostnameConfig
#    document (needs Talos >= 1.12), not machine.network.hostname: gen config already ships a HostnameConfig
#    (auto: stable), and setting both errors with "static hostname is already set in v1alpha1 config".
for i in "${TARGETS[@]}"; do
  ip="${IPS[$i]}"; host="${HOSTNAMES[$i]}"
  say "applying config to ${host} (${ip})"
  talosctl apply-config --insecure -n "${ip}" -f /scratch/cp.yaml \
    -p @/scratch/cp-patch.yaml \
    -p '{"apiVersion":"v1alpha1","kind":"HostnameConfig","hostname":"'"${host}"'","auto":"off"}'
done

# The rendered scratch (cp.yaml + controlplane.yaml + cp-patch.yaml + volumes.yaml) has now been applied to
# every node; the nodes hold their own live config from here on. It lives in ${TALOS_SCRATCH} (an OS temp
# dir), so there's nothing to clean up: the OS reaps it, and it never sat next to the durable creds.

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
for i in "${TARGETS[@]}"; do
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

if [ -n "$JOIN_ONE" ]; then
  say "${JOIN_ONE} has its config and is rebooting into it; it joins etcd on its own."
  say "Not bootstrapping and not re-fetching the kubeconfig: this cluster already exists."
  exit 0
fi

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
echo "   cp ~/.kube/config ~/.kube/config.bak && KUBECONFIG=\"${SCRIPT_DIR}/secrets/kubeconfig:${HOME}/.kube/config\" kubectl config view --flatten > /tmp/kc && mv /tmp/kc ~/.kube/config"
