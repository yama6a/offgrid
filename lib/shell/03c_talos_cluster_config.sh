#!/usr/bin/env bash
# Renders the Talos machine config from inventory.yaml + versions.env + .env, and applies it. Generated configs
# land in secrets/, which the talosctl container mounts as /work so every call sees the same files.
#
# Two modes, differing ONLY in how the render is applied:
#   (default)   nodes must be in MAINTENANCE. Applies insecurely, bootstraps etcd, writes the kubeconfig.
#               This is first bring-up, or a rebuild after DANGEROUS_reset_talos_cluster.sh.
#   --reapply   nodes must already be RUNNING. Applies over the Talos API with --mode auto, and never
#               bootstraps. This is how a config change reaches a live cluster without wiping it.
#
# A worker gets a strict subset of the control-plane config: no VIP, no certSANs, no etcd tuning, and no
# bootstrap. Which one a node gets comes from its `role` in inventory.yaml, so adding a worker is not a
# separate operation, it is just another node in the list.
#
# Requires: docker with host networking enabled.
set -euo pipefail

# CLUSTER_* in .env; EXPECT_*/INSTALL_DISK/IFACE/TALOSCTL_VERSION/installer_ref_for in lib/shell/common.sh;
# the node list, each node's role and its hardware type in inventory.yaml.
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

CLUSTER="$CLUSTER_NAME"; DISK="$INSTALL_DISK"; EPHEMERAL="$EPHEMERAL_SIZE"; VIP="$CLUSTER_VIP"; KVER="$KUBERNETES_VERSION"

# Control-plane nodes first, so etcd exists before a worker tries to join it.
TARGETS=("${CP_HOSTS[@]}" "${WORKER_HOSTS[@]}")

# --reapply targets RUNNING nodes instead of maintenance ones; see the header.
# The optional hostname applies to that node ALONE, for putting a replaced node back into a cluster that
# already exists (recover_node.sh), for adding one new node, or for reapplying to just one. It narrows only the
# apply and the waits; certSANs and the talosconfig endpoints still come from the full control-plane list, or
# the rejoined node would trust an apiserver cert naming just itself and talosctl would forget the others. It
# also skips the etcd bootstrap, which creates a cluster rather than joining one.
REAPPLY=false
JOIN_ONE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reapply) REAPPLY=true; shift ;;
    -*)        die "unknown flag: $1 (see the usage header)" ;;
    *)         JOIN_ONE="$1"; shift ;;
  esac
done
if [ -n "$JOIN_ONE" ]; then
  [ -n "${NODE_ROLE[$JOIN_ONE]:-}" ] || die "unknown node '${JOIN_ONE}': inventory.yaml has ${ALL_HOSTS[*]}"
  TARGETS=("$JOIN_ONE")
fi

echo "== Talos cluster setup (talosctl ${TALOSCTL_VERSION}, dockerized) =="
echo "Cluster:  ${CLUSTER}     VIP: ${VIP}     NIC: ${IFACE}     k8s: ${KVER}"
echo "Disk:     ${DISK}        EPHEMERAL cap: ${EPHEMERAL}"
for h in "${TARGETS[@]}"; do
  printf '  %-12s %-16s %-13s %s\n' "$h" "${NODE_IP[$h]}" "${NODE_ROLE[$h]}" "${NODE_TYPE[$h]}"
done
if [ "$REAPPLY" = true ]; then
  echo "Mode:     REAPPLY to running nodes (--mode auto), NOT bootstrapping etcd"
elif [ -n "$JOIN_ONE" ]; then
  echo "Mode:     joining ${JOIN_ONE} ONLY, from maintenance, NOT bootstrapping etcd"
fi
echo "Output:   ${OUTDIR}"

# Bakes a machine.registries auth into the CP patch, so the kubelet authenticates EVERY pull from GHCR on
# every node, with no per-namespace imagePullSecrets. It is a read:packages PULL token for YOUR private
# images; the Talos image package is public and needs none. It lands only in the gitignored
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

# The worker base, from the SAME secrets.yaml so the PKI matches. Not passed --install-image: the ref differs
# per hardware type, so it is patched per node at apply time instead.
if [ "${#WORKER_HOSTS[@]}" -gt 0 ]; then
  talosctl gen config "${CLUSTER}" "https://${VIP}:6443" \
    --with-secrets secrets.yaml \
    --install-disk "${DISK}" \
    --kubernetes-version "${KVER}" \
    --output-types worker \
    --force
  mv "${OUTDIR}/worker.yaml" "${TALOS_SCRATCH}/worker.yaml"
fi

# Point talosctl at the real CONTROL-PLANE ips (NOT the VIP) immediately, because `gen config` above just
# rewrote talosconfig and a freshly generated one has NO endpoints. Doing it here rather than after the apply
# means aborting anywhere below still leaves a usable talosconfig behind. A worker cannot proxy the Talos API,
# so it is never an endpoint; `-n <worker-ip>` still reaches it through one of these.
talosctl config endpoint "${CP_IPS[@]}"
talosctl config node "${CP_IPS[0]}"

# 2. Cluster-wide control-plane patch: VIP on the wired NIC, schedulable CP, certSANs.
#    certSANs name the VIP and the CONTROL-PLANE ips only: a worker serves no apiserver.
CERTSANS="$(printf '      - %s\n' "${VIP}" "${CP_IPS[@]}")"
cat > "${TALOS_SCRATCH}/cp-patch.yaml" <<EOF
machine:
${REGISTRIES_BLOCK}
  kubelet:
    # Talos runs the kubelet in a container and does NOT auto-propagate /var/mnt mounts into it, so without
    # this bind Longhorn's pods cannot see their disk. rshared means mounts made inside the bind are visible
    # on the host too, which Longhorn needs: it creates one sub-mount per replica. See 08_storage.md.
    extraMounts:
      - destination: /var/mnt/longhorn
        type: bind
        source: /var/mnt/longhorn
        options: [bind, rshared, rw]
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

# 3. Worker patch: the same kubelet mounts and KubePrism, and nothing else. A worker carries no VIP (so no
#    interfaces block either, which is what keeps a NIC name we cannot predict out of the config), no certSANs,
#    no etcd and no CNI/proxy keys: those are control-plane bootstrap settings that a worker never reads.
if [ "${#WORKER_HOSTS[@]}" -gt 0 ]; then
  cat > "${TALOS_SCRATCH}/worker-patch.yaml" <<EOF
machine:
${REGISTRIES_BLOCK}
  kubelet:
    # Same bind as the control plane: Longhorn runs on every node that carries a disk, and the kubelet cannot
    # see /var/mnt without it. See 08_storage.md.
    extraMounts:
      - destination: /var/mnt/longhorn
        type: bind
        source: /var/mnt/longhorn
        options: [bind, rshared, rw]
  features:
    kubePrism:
      enabled: true
      port: 7445
EOF
fi

# Cap EPHEMERAL, then let 'longhorn' take the whole remainder: no maxSize, so it claims what is left, once,
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
name: longhorn
provisioning:
  diskSelector:
    match: disk.transport == "nvme"
  minSize: 50GiB
filesystem:
  type: xfs
EOF

# 4. Combined config per role = base + the SAME volume docs (rebuilt each run). Every node carries a disk, so
#    the volume layout does not vary by role.
cp "${TALOS_SCRATCH}/controlplane.yaml" "${TALOS_SCRATCH}/cp.yaml"
cat "${TALOS_SCRATCH}/volumes.yaml" >> "${TALOS_SCRATCH}/cp.yaml"
if [ "${#WORKER_HOSTS[@]}" -gt 0 ]; then
  cat "${TALOS_SCRATCH}/volumes.yaml" >> "${TALOS_SCRATCH}/worker.yaml"
fi

# 4b. Wait for every node to be in MAINTENANCE before applying. After a reset
#     (DANGEROUS_reset_talos_cluster.sh / DANGEROUS_rebuild_cluster.sh) the nodes wipe + reboot
#     asynchronously, so the apply-config --insecure below would fail on a node that hasn't come back
#     yet. A maintenance node answers --insecure; a CONFIGURED one does not (and a freshly-reset node
#     can't boot configured, STATE is wiped), so this check is never fooled by the pre-reset instance:
#     it blocks until the node is genuinely back in maintenance. nc gates the call so we don't hang on a
#     node mid-reboot. On a first install (straight off 03a) the nodes are already in maintenance, so
#     this returns immediately.
#     In --reapply the test is the exact opposite: the node must answer SECURELY, which proves it already holds
#     our PKI and is not sitting in maintenance waiting to be initialised.
if [ "$REAPPLY" = true ]; then
  say "checking the target nodes are running and hold our PKI"
  for host in "${TARGETS[@]}"; do
    ip="${NODE_IP[$host]}"
    printf '   %-12s %-16s ' "$host" "$ip"
    talosctl -e "$ip" -n "$ip" version >/dev/null 2>&1 \
      || die "${ip} does not answer the secure API, so it is not a running node of this cluster. Drop --reapply to initialise it from maintenance."
    echo "running"
  done
else
  say "waiting for nodes in maintenance (up to 5 min each)..."
  for host in "${TARGETS[@]}"; do
    ip="${NODE_IP[$host]}"
    printf '   %-12s %-16s ' "$host" "$ip"
    deadline=$(( $(date +%s) + 300 ))
    until nc -z -G2 "$ip" "$API_PORT" >/dev/null 2>&1 && talosctl -e "$ip" -n "$ip" version --insecure >/dev/null 2>&1; do
      [ "$(date +%s)" -lt "$deadline" ] || { echo "TIMEOUT"; die "${ip} not in maintenance after 300s. If it is already RUNNING, you want --reapply."; }
      printf '.'; sleep 5
    done
    echo "ready"
  done
fi

# 4c. Report each node's hardware while it is still in maintenance, which is the only window where it is
#     visible before the config commits to a disk. Reports rather than asserts, because the point is to work
#     with hardware this repo has never seen: the NIC name in particular is firmware-dependent and nothing here
#     depends on it (a worker has no interfaces block, and the VIP node's NIC is checked by 03b). The install
#     disk is the exception: getting that wrong writes the wrong device.
#     Skipped in --reapply: it reads over the insecure API, which a running node refuses, and the disk it would
#     check has already been committed to anyway.
if [ "$REAPPLY" = false ]; then
  for host in "${TARGETS[@]}"; do
    ip="${NODE_IP[$host]}"
    say "${host} (${ip}, ${NODE_TYPE[$host]}) hardware"
    talosctl -e "$ip" -n "$ip" get cpus  --insecure 2>/dev/null | tail -n +2 | sed 's/^/   cpu   /' || true
    talosctl -e "$ip" -n "$ip" get links --insecure 2>/dev/null | tail -n +2 | sed 's/^/   link  /' || true
    disks="$(talosctl -e "$ip" -n "$ip" get disks --insecure 2>/dev/null || true)"
    printf '%s\n' "$disks" | tail -n +2 | sed 's/^/   disk  /'
    grep -qE "[[:space:]/]${EXPECT_DISK}([[:space:]]|\$)" <<< "$disks" \
      || die "${host} has no ${EXPECT_DISK}; --install-disk ${DISK} would write a device that is not there"
    n="$(grep -oE '[[:space:]]nvme[0-9]+n[0-9]+[[:space:]]' <<< "$disks" | wc -l | tr -d ' ')"
    [ "${n:-0}" -le 1 ] || warn "${host} shows ${n} NVMe disks; the volume diskSelector matches on transport, so it could pick either"
  done
fi

# 5. Apply to each node. cp.yaml/cp-patch.yaml live in the scratch dir, mounted at /scratch in the
#    container (the rest of the paths are relative to /work). Hostname goes through the HostnameConfig
#    document (needs Talos >= 1.12), not machine.network.hostname: gen config already ships a HostnameConfig
#    (auto: stable), and setting both errors with "static hostname is already set in v1alpha1 config".
#    install.image and the instance-type label are per NODE, not per role, so they ride in their own patch:
#    the installer ref follows the hardware type, and nic-keeper selects on the label.
#    --reapply swaps --insecure for the authenticated API and --mode auto, which reboots only if the change
#    needs it. It runs --dry-run first and makes you confirm, because unlike a bring-up this is being done to a
#    cluster that is currently serving.
apply_to() {   # apply_to <host> [extra talosctl flags...]
  local host="$1"; shift
  local ip="${NODE_IP[$host]}" base rpatch npatch
  case "${NODE_ROLE[$host]}" in
    controlplane) base="/scratch/cp.yaml";     rpatch="/scratch/cp-patch.yaml" ;;
    worker)       base="/scratch/worker.yaml"; rpatch="/scratch/worker-patch.yaml" ;;
  esac
  npatch="$(printf '{"machine":{"install":{"image":"%s"},"nodeLabels":{"node.kubernetes.io/instance-type":"%s"}}}' \
            "$(installer_ref_for "$host")" "${NODE_TYPE[$host]}")"
  # -e is not optional on the secure path: `gen config --force` above rewrites talosconfig, and a freshly
  # generated one carries NO endpoints (step 6 sets them, which is after this). Without it the apply dies with
  # "failed to determine endpoints". --insecure never needed it, since that dials -n directly.
  talosctl apply-config -e "${ip}" -n "${ip}" -f "$base" \
    -p @"$rpatch" \
    -p "$npatch" \
    -p '{"apiVersion":"v1alpha1","kind":"HostnameConfig","hostname":"'"${host}"'","auto":"off"}' \
    "$@"
}

if [ "$REAPPLY" = true ]; then
  say "dry run: what each node WOULD do with this config"
  for host in "${TARGETS[@]}"; do
    echo "   --- ${host} (${NODE_IP[$host]}) ---"
    apply_to "$host" --mode auto --dry-run 2>&1 | sed 's/^/   /'
  done
  # Talos provisions a volume once and, with `grow` unset as it is here, "the existing volume size is never
  # changed". So an EPHEMERAL_SIZE edit applies to a NEW node and silently does nothing to these.
  warn "volume sizes are fixed at provision time; changing them here reaches new nodes only, not these"
  printf '>> apply to %d running node(s)? some changes reboot. type yes: ' "${#TARGETS[@]}"
  read -r confirm </dev/tty 2>/dev/null || confirm=""
  [ "$confirm" = "yes" ] || die "aborted, nothing applied"
fi

for host in "${TARGETS[@]}"; do
  say "applying ${NODE_ROLE[$host]} config to ${host} (${NODE_IP[$host]})"
  if [ "$REAPPLY" = true ]; then apply_to "$host" --mode auto
  else                           apply_to "$host" --insecure
  fi
done

# The rendered scratch (cp.yaml + controlplane.yaml + cp-patch.yaml + volumes.yaml) has now been applied to
# every node; the nodes hold their own live config from here on. It lives in ${TALOS_SCRATCH} (an OS temp
# dir), so there's nothing to clean up: the OS reaps it, and it never sat next to the durable creds.

# 7. Wait for every node to reboot into its configured state before bootstrapping.
#    apply-config (maintenance mode) reboots each node; it comes back serving the API
#    *securely* with our PKI, so a secure `version` (no --insecure) succeeding is the
#    ready signal, a maintenance-mode node only answers --insecure. Beats guessing a
#    fixed wait. nc gates the call so we don't hang on a node that's mid-reboot.
#    In --reapply the same test covers both outcomes: --mode auto reboots only when the change needs it, and a
#    node that never went away passes on the first poll.
say "waiting for nodes to settle into their configured state (up to 5 min each)..."
sleep 10   # let any reboot actually begin (avoids a false 'ready' before it goes down)
for host in "${TARGETS[@]}"; do
  ip="${NODE_IP[$host]}"
  printf '   %-12s %-16s ' "$host" "$ip"
  deadline=$(( $(date +%s) + 300 ))
  until nc -z -G2 "$ip" "$API_PORT" >/dev/null 2>&1 && talosctl -e "$ip" -n "$ip" version >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || { echo "TIMEOUT"; die "${ip} never came back, check its console/power"; }
    printf '.'; sleep 5
  done
  echo "ready"
done

sleep 10

if [ "$REAPPLY" = true ]; then
  say "reapplied to ${#TARGETS[@]} node(s). Nothing was bootstrapped: the cluster was already running."
  say "Verify: make check-health   and   make talosctl -- -n <ip> get mc v1alpha1 -o yaml"
  exit 0
fi

if [ -n "$JOIN_ONE" ]; then
  if [ "${NODE_ROLE[$JOIN_ONE]}" = worker ]; then
    say "${JOIN_ONE} has its config and is rebooting into it; its kubelet registers on its own."
  else
    say "${JOIN_ONE} has its config and is rebooting into it; it joins etcd on its own."
  fi
  say "Not bootstrapping and not re-fetching the kubeconfig: this cluster already exists."
  exit 0
fi

# 8. Bootstrap etcd ONCE, on the first control-plane node only
talosctl bootstrap -n "${CP_IPS[0]}"

sleep 10

# 9. Wait for the cluster, then fetch kubeconfig (-> ${OUTDIR}/kubeconfig)
say "waiting for cluster health (a few minutes)..."
talosctl health --wait-timeout 10m || warn "health timed out, verify with kubectl below"
talosctl kubeconfig .
say "Done."
echo "   talosconfig: ${OUTDIR}/talosconfig   (export TALOSCONFIG=${OUTDIR}/talosconfig)"
echo "   kubeconfig:  ${OUTDIR}/kubeconfig    (export KUBECONFIG=${OUTDIR}/kubeconfig && kubectl get nodes -o wide)"
echo "   cp ~/.kube/config ~/.kube/config.bak && KUBECONFIG=\"${SCRIPT_DIR}/secrets/kubeconfig:${HOME}/.kube/config\" kubectl config view --flatten > /tmp/kc && mv /tmp/kc ~/.kube/config"
