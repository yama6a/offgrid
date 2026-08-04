# Talos: OS choice, custom NVMe image & cluster bring-up

OS for the 3-node Pi 5 cluster: Talos Linux. Immutable, API-managed, Kubernetes-only.
Talos has no official Pi 5 image, so the node image is built separately, in
[yama6a/talos-raspberry-pi5](https://github.com/yama6a/talos-raspberry-pi5).

## Why Talos

- Whole node = one declarative config. Managed via `talosctl`. Everything-as-code without exception.
- Identical nodes. Same image on every board; what makes a node different is just its config (cluster bring-up, below).
- Atomic A/B upgrades + rollback via `talosctl upgrade`. No in-place mutation.
- Minimal attack surface. No shell, no SSH, ~12 host binaries. WiFi/Bluetooth/cron daemons aren't in the image at
  all.
- Kubernetes built in. PCIe, cgroups, link speed are all baked into the image. No manual `config.txt` wrangling like
  on Raspberry Pi OS.

## Trade-offs

- Talos ships no Pi 5 image; BCM2712 + RP1 needs drivers that only exist in the `raspberrypi/linux` fork.
- Upgrading Talos means a new image build, which is a separate repo and its own maintenance.
- API-only, no shell. A hung node gets rebooted, not SSH'd into.

## OSes considered

| OS / distro                                | Verdict                                                                                                   |
|--------------------------------------------|-----------------------------------------------------------------------------------------------------------|
| Talos Linux                                | Chosen. Immutable, declarative, identical nodes, K8s built in.                                            |
| k3s on Ubuntu Server                       | Runner-up. 4K pages + cgroups out of the box, biggest community. But mutable, more moving parts.          |
| k3s / kubeadm on Raspberry Pi OS           | Two Pi-5 traps: manual cgroup `cmdline.txt` edit + 16K-page kernel (must switch to 4K). No gain headless. |
| k0s on Ubuntu                              | Lightest footprint, clean `k0sctl` spec. Smaller ecosystem; no real advantage over Talos here.            |
| NixOS + k3s                                | Fully declarative, closest rival to Talos. Steep Nix learning curve, smaller Pi 5 community.              |
| Flatcar / Fedora CoreOS / openSUSE MicroOS | Also immutable, but Pi 5 support is thinner/younger. Talos wins on the declarative side.                  |
| Harvester                                  | Not even close. Full HCI/KubeVirt stack, needs x86_64 and a lot of RAM.                                   |

## Where the image comes from

`metal-arm64` does not work on a Pi 5: it carries no Pi 5 boot chain (u-boot + BCM2712 device tree) at all. So
the image is built separately, in
[yama6a/talos-raspberry-pi5](https://github.com/yama6a/talos-raspberry-pi5): current Talos on a Raspberry Pi
kernel, with the boot chain and two system extensions baked in. That repo owns the build, the kernel decisions
and the release stream. This one is a consumer of its releases:

- `03a` flashes the release's raw disk image onto each NVMe, once per drive.
- `03e` upgrades running nodes to the release's installer image over the network.

`siderolabs/sbc-raspberrypi` does ship an `rpi_5` overlay now, and its kernel side is fine: vanilla carries the
Pi 5 NIC as of Linux 6.18 and stock Talos enables it. What it cannot do is boot from NVMe. It ships u-boot built
for the Pi 4, with no `brcm,bcm2712-pcie` driver, so u-boot cannot read the disk the firmware just loaded it
from. Tested on a node here: the upgrade applied cleanly, then the board went dark with no layer-2 presence at
all. These nodes boot from NVMe, so that is fatal. The evidence, the full audit of which of the custom build's
steps are still load-bearing, and the plan to retire it are in that repo's `docs/upstream.md` and
`FUTURE_WORK.md`.

## Versions

Every pin lives in the committed `versions.env`; Renovate opens PRs to bump them.

- Talos image (`TALOS_IMAGE_RELEASE`): which release of the image repo above, as
  `<talos version>-<build revision>`. `common.sh` derives `TALOS_VERSION` from the part before the dash, and
  that is the talosctl client version, the expected server version, and what `03c` and `03f` reason about.
  One pin, so the client can never drift from the image.
- Kubernetes (`KUBERNETES_VERSION`): the pin `03c` passes to `gen config` and `03f` upgrades to. Capped by
  the Talos release's own k8s default, so raise it only after bumping the image.

Merging a bump changes only `versions.env`. Applying it needs `03e`, and `03a` for a fresh drive.

## What's baked into the image

Decided and documented in the image repo. What matters on this cluster:

- 4K kernel pages, not the Pi defconfig's 16K, matching stock Talos `metal-arm64` and keeping all three nodes
  the same. Some storage software does not cope with 16K.
- System extensions `iscsi-tools` (Longhorn needs `iscsid`) and `util-linux-tools` (`fstrim`).
- Built-in drivers that `03d` and Longhorn depend on: the Pi 5 watchdog (`BCM2835_WDT`), NVMe over PCIe
  (`PCIE_BRCMSTB`), the NIC (`MACB`), RP1 bring-up (`MFD_RP1`, `FIRMWARE_RP1`, ...), and
  `INET_DIAG_DESTROY`, which is what lets `nic-keeper` force-close sockets with `ss -K`.
- WiFi and Bluetooth disabled at the device-tree level, which is also why `03c` binds the VIP to
  `interface: end0` rather than `physical: true`.

## Upgrades

During first setup the NVMe is flashed once (`03a`). After that, Talos upgrades are atomic A/B over the
network with no reflash. Bump `TALOS_IMAGE_RELEASE` in `versions.env`, then run **`03e_talos_upgrade.sh`**,
which runs `talosctl upgrade --image "$INSTALLER_REF"` one node at a time. Re-run-safe: a node already on the
target image is a no-op. The image package is public, so nodes need no registry auth to pull it.

**Draining during the upgrade (why `03e` cordons/drains itself).** Talos's upgrade sequence cordons the node and
drains it (honoring the eviction API / PodDisruptionBudgets) before the reboot. On this cluster that drain used to
*hang*, three pods it cannot gracefully evict, each for a different reason:

- CNPG single-instance DB (`highAvailability: false`): the operator's PDB is `minAvailable: 1`, so with one instance
  ANY eviction violates it. A hard block, unrelated to storage. The wrapper turns the PDB off automatically for a
  non-HA instance, driving `enablePDB: false`. An HA instance is left alone: it switches over, and its PDB permits
  the eviction.
- Longhorn `instance-manager`: Longhorn's PDB blocks the drain only while the node holds a volume's LAST HEALTHY
  replica, meaning when a volume is already `degraded`. Common here, since the NICs are flaky so a replica is often
  down.
- RabbitMQ broker (`rabbitmq-server-0`): no PDB and no finalizer, just slow to terminate (quorum preStop) and
  unable to reschedule (hard one-per-node anti-affinity on 3 nodes + node-local storage), so Talos's bounded drain
  times out waiting for it.

None of these pods can relocate, because of node-local storage, a per-node storage engine, or hard anti-affinity. So
a graceful drain can only kill them, and they come back on the same node after the reboot.

`03e` therefore takes the drain into its own hands, with native `kubectl`. Per node it:

1. Waits until every replicated store is healthy and in sync (see below).
2. Cordons, runs a bounded graceful drain, then force-deletes any straggler so the node can always reboot.

Talos's own in-upgrade drain then finds an empty node and completes instantly.

Longhorn's `nodeDrainPolicy` deliberately stays at its default. `block-for-eviction` evicts and rebuilds replicas
off the node first, which needs a spare node and is slow, and that is exactly what times out on a 3-node,
replica-2 layout. The health gate is the lighter, self-correcting equivalent: Longhorn auto-rebuilds a degraded
volume onto the spare node on its own while we wait.

**The replication-health gate (run before draining *each* node).** A node reboot is a replication event for every
replicated store that has data on it, so before taking a node down `03e` blocks until they're all healthy *and* in
sync, which crucially also waits out the PREVIOUS node's post-reboot resync before we touch the next one. Gated:

- Longhorn volumes: no volume `degraded` or `faulted`. `healthy` IS Longhorn's all-replicas-in-sync signal (it
  drops to `degraded` while a replica rebuilds), so this both avoids a last-replica reboot and waits for rebuilds.
- CNPG clusters: `phase == "Cluster in healthy state"`, `readyInstances == spec.instances` (the streaming
  standby is up + caught up), and `currentPrimary == targetPrimary` (no switchover/failover mid-flight). So we never
  reboot the node hosting a primary while its standby is still catching up. `maindb` is 3 instances with
  synchronous `any 1`, so the drained instance's absence does not stall writes, but a standby still has to be
  current before we can safely switch over to it.
- RabbitMQ: `AllReplicasReady` + `ClusterAvailable`, so all three brokers are up and quorum queues have full
  membership before we take one down. The `NoWarnings` condition is intentionally ignored: it is `False` for a
  benign reason (memory request not equal to limit) and would block forever.
- etcd: not in this gate. `talosctl upgrade` already refuses to reboot if it would break etcd quorum, and the
  existing `talosctl health` gate between nodes covers full quorum restore.
- Redis: nothing to gate. The `redis-instance` wrapper is a single standalone instance with no replication, its
  data lives on Longhorn (covered above), and it simply restarts after the reboot.

A store that isn't installed (its CRD absent) is treated as healthy, so the gate is a no-op where it doesn't apply.
Each check waits up to `REPLICATION_HEALTH_TIMEOUT`. On timeout `03e` aborts naming the laggards, so fix and re-run;
idempotent, done nodes are no-ops) rather than reboot into a degraded store. (Caveat: CNPG "in sync" here means the
standby is *ready/streaming*, not zero-lag; the operator does a controlled switchover on drain, which needs a
caught-up standby. `readyInstances` is the practical proxy; we do not query `pg_stat_replication` lag.)

**Upgrading Kubernetes (separate from the OS).** The Talos OS version and the Kubernetes version upgrade independently.
`03f_k8s_upgrade.sh` updates the k8s control plane (`talosctl upgrade-k8s --to "$KUBERNETES_VERSION"`). So bump *only*
`KUBERNETES_VERSION` in `versions.env`, and then run `03f`. `KUBERNETES_VERSION` can't exceed the pinned Talos release's default
k8s version (its supported ceiling). So it is useful to always first bump Talos.

**Rebalancing after the upgrade (`03g`).** Draining node by node leaves the pods bunched on whichever nodes were
up last, and nothing moves them back: no descheduler, and `topologySpreadConstraints` only on argocd.
`03g_rebalance_workloads.sh` rolling-restarts the stateless Deployments so the scheduler re-places them. `03e`
runs it; `make rebalance-workloads` runs it alone. A measured run went 39/40/15 to 31/32/32.

- A nudge, not guaranteed balance. The scheduler scores each pod alone, so a run can still clump. The real fix,
  if it ever matters, is `topologySpreadConstraints` on the workload charts.
- Refuses to run unless every node is Ready, schedulable, and the count matches `CLUSTER_NODES`. Restarting while
  one is cordoned just packs the survivors.
- Serial, one Deployment at a time: `maxSurge` doubles a Deployment's pods and three Pi 5s are RAM-tight.
- Skips a Deployment when its namespace is in `SKIP_NAMESPACES` (`longhorn-system` CSI sidecars,
  `envoy-gateway-system` ingress data plane), when it mounts a PVC (not stateless, and moving it costs a Longhorn
  detach/attach), or when it is scaled to 0. The PVC test is a property, so operator-generated names like
  `vmsingle-<cr>` cannot rot a list.
- NOT wired into `03f`: `upgrade-k8s` rolls the control plane and kubelet in place and moves no pods.

## Flash the NVMe

Script: `03a_talos_image_flasher.sh` (MacOS). Downloads the pinned release's `.raw.xz`, checks its sha256
against the release's `sha256sums.txt`, then `dd`s it to an NVMe over a USB adapter. Cached per release tag,
so the second and third drives re-download nothing. Usual safeguards: lists disks, requires typing `YES`,
writes to `/dev/rdiskN`, ejects.

### Per drive

Run the script, pick the USB-NVMe adapter's disk id, confirm. Repeat for each SSD, just swap drives in the
adapter. Then slot the SSD into a Pi, power on with no SD card -> Talos boots into maintenance mode (no role
assigned yet).

## Boot & verify (per node)

Script: `03b_talos_boot_verify.sh`, reads the node IPs (`CLUSTER_NODES` in `.env`) and runs the checklist below against
each (maintenance mode, `--insecure`), inspecting each output and printing PASS/FAIL + a summary. It uses the talosctl
container (sidesteps the MacOS gotcha below); `ping`/`nc` run natively.

```bash
./03b_talos_boot_verify.sh        # checks the nodes listed in .env
```

What it checks per node:

```bash
ping <node-ip>                                       # on the network
nc -vz <node-ip> 50000                               # Talos API reachable
talosctl -n <node-ip> version --insecure             # responds; server = our (-dirty) custom build
talosctl -n <node-ip> get links --insecure           # end0 (the wired NIC) present/up
talosctl -n <node-ip> get disks --insecure           # /dev/nvme0n1 present
talosctl -n <node-ip> get kernelcmdlines --insecure  # cmdline has console=ttyAMA0,115200 (rpi5 overlay)
```

All green -> proceed to [Cluster bring-up](#cluster-bring-up) below.

### MacOS `talosctl` gotcha

If `nc` succeeds but `talosctl ... --insecure` comes back with `no route to host`, the node is probably fine. The MacOS
`talosctl` binary is just misbehaving (confirmed by the official container reaching the same node without issues). Use
the container:

```bash
talosctl() { docker run --rm --network host -v "$HOME/.talos:/root/.talos" ghcr.io/siderolabs/talosctl:<TALOS_VERSION> "$@"; }  # match TALOS_VERSION in versions.env
```

Drop that in `~/.zshrc` or `~/.bash_profile`, reload, and `talosctl` works normally from there.

## Cluster bring-up

Per-node identity (hostname, role) is applied now via `talosctl`. The CNI is disabled at the Talos layer (`cni: none`)
and kube-proxy is off (`proxy.disabled: true`), both replaced by Cilium in [step 04](04_networking.md). All three nodes
are control-plane and schedulable. Nodes come up NotReady until Cilium lands, that's expected, not a fault.

> The cluster name, VIP, and the node list (hostname + IP per node) live in `.env`; the install disk + NIC are fixed
> constants in `common.sh` (Pi 5 hardware). Nothing is hardcoded in the script: edit `.env` to match your network.

### Router reservations (manual, once)

Reserve one MAC/IP pair per Pi so each always boots at a known IP. My values:

| Node   | IP (my choice) |
|--------|----------------|
| pi-cp1 | 192.168.10.201 |
| pi-cp2 | 192.168.10.202 |
| pi-cp3 | 192.168.10.203 |

Boot the Pis one by one, read their MAC addresses from the router's client list, and add a reservation for each. (You
can do this with a standard PiOS image on an SD card first, or with the Talos image on the NVMe, as long as the Pi
boots, its MAC shows up and you can reserve the IP.)

The VIP is not reserved in the router: it must be outside the DHCP pool, Talos claims it via ARP, and it can move
between nodes, so it can't be pinned to a MAC. My subnet is `192.168.0.0/16` with DHCP `192.168.2.1`-`192.168.10.254`,
so I picked `192.168.100.1` for the VIP (inside the subnet, outside the DHCP range)

### Prereqs

- The nodes are all booted from NVMe and reachable in maintenance mode at their reserved IPs.
- Docker, with host networking enabled in Docker Desktop. The script runs `talosctl` as a pinned container, so no host
  `talosctl`/`kubectl` is required for bring-up.

### What `03c_talos_cluster_config.sh` does

1. Reads cluster name, install disk, EPHEMERAL cap, NIC, the VIP, and each node's hostname + IP from
   `.env`, prints a summary, and waits for a `YES` confirmation.
2. Prepares the config. The durable secrets bundle (`secrets.yaml`, the cluster PKI: CA, service-account
   key, bootstrap/join tokens) is generated **once** and never rotated, so the cluster identity survives every
   re-run and rebuild. Everything else is **disposable scratch re-rendered each run**: `talosctl gen config
   --with-secrets secrets.yaml --force` regenerates the base machine config from that bundle + the *current*
   `versions.env`/`.env` values, so a version bump in `versions.env` actually lands (unlike the old preserved `controlplane.yaml`,
   which froze the version it was first generated with). Kubernetes is pinned explicitly with
   `--kubernetes-version "$KUBERNETES_VERSION"` rather than taking the Talos release default, so the k8s
   version is a reviewed knob, not an implicit side effect of a Talos bump. `worker.yaml` is skipped (every
   node here is control-plane); the API endpoint is the VIP. (The base would default to Flannel; the patch
   below turns the CNI off so Cilium can take over.) Migration note: the first run after this split, if only a
   pre-split `controlplane.yaml` exists, extracts `secrets.yaml` *from it* (`gen secrets
   --from-controlplane-config`) so the running cluster's existing PKI is preserved rather than replaced.
3. Applies a control-plane patch to every node: the VIP bound to the wired NIC, `allowSchedulingOnControlPlanes:
   true`, `certSANs` (VIP + node IPs), the node label `machine.nodeLabels: node.kubernetes.io/instance-type=rpi5`
   (so the `nic-keeper` DaemonSet targets rpi5 hardware only,
   see [Runtime: the recovery DaemonSet](#runtime-the-recovery-daemonset-nic-keeper-gitops);
   `NODE_INSTANCE_TYPE` knob in `03c`), and the Cilium prep: `cluster.network.cni.name: none`,
   `cluster.proxy.disabled: true` (Cilium does kube-proxy replacement), and `machine.features.kubePrism.enabled: true`
   (Cilium's API endpoint at `localhost:7445`; default-on in recent Talos, set explicitly here to document the dependency).
   Finally it raises etcd's timeouts (`cluster.etcd.extraArgs: {heartbeat-interval: "500", election-timeout: "5000"}`),
   5x etcd's 100ms/1000ms defaults. All three nodes are control-plane + worker and etcd shares the single NVMe with
   Longhorn + CNPG, so during the cold-boot I/O storm etcd's fsyncs stall past the default 1000ms election window and
   trigger a burst of spurious leader elections, which disrupts apiserver watches and lags the controllers (e.g.
   cert-manager's HTTP-01 solver endpoints fail to program in time, wedging cert issuance). The 5s election timeout
   rides out the stalls. The only cost is ~5s instead of ~1s failover when a leader really is gone, which does not
   matter on this cluster.
4. Appends the partition layout: `EPHEMERAL` capped (default 64 GiB) + a `longhorn` user volume taking the whole
   rest of the NVMe (`/var/mnt/longhorn`, no `maxSize`, so it claims what is left once at provision time). That
   path also gets a `kubelet.extraMounts` bind so the containerized kubelet can see it. Sits empty until
   [Longhorn](08_storage.md) syncs (step 04+).
5. `apply-config` to each node (only the hostname differs), then deletes the rendered scratch (`cp.yaml`,
   `controlplane.yaml`, and their inputs `cp-patch.yaml` + `volumes.yaml`), so the nodes now hold their own
   live config, so the only config left on disk is the durable `secrets.yaml` (plus the
   `talosconfig`/`kubeconfig` creds). On an apply failure the script aborts before the cleanup, leaving the
   files for inspection.
6. Waits for every node to reboot back into its configured state (polls the secure Talos API per node, up to 5 min
   each), so the bootstrap prompt only appears once the nodes are actually ready, no guessing.
7. `bootstrap` etcd once on the first node (after a confirm); the others join automatically.
8. Waits for health, writes `kubeconfig`.

> NIC selector: the VIP is bound to `interface: end0` (the Pi 5 wired NIC) rather than `physical: true`, so it can
> never latch onto WiFi. Confirm the name on a live node with `talosctl get links` if unsure (`EXPECT_NIC` constant
> in `common.sh`, default `end0`).

> GHCR registry auth (optional, global): to pull private container images, `03c` reads `GITHUB_GHCR_PULL_TOKEN_SECRET`
> (a GitHub classic token scoped `read:packages`) from the gitignored `.env` and bakes a
> `machine.registries.config."ghcr.io".auth` block into the control-plane patch. The kubelet/CRI then authenticates
> every pull from `ghcr.io` on every node, cluster-wide, with no per-namespace `imagePullSecrets` to wire into
> workloads. We chose node-level auth over an in-cluster (sealed-secret) pull secret precisely because it's global
> and namespace-agnostic; the cost is that the token lives in the machine config (in the gitignored
> `secrets/cp-patch.yaml`, never committed) rather than in the sealed-secrets pipeline, and rotating it means
> editing `.env` and re-running `03c`. The username is plain `.env` config (`GHCR_USER`); the registry host
> (`GHCR_SERVER`) is a fixed constant in `common.sh`. Leave `GITHUB_GHCR_PULL_TOKEN_SECRET` empty to skip, which
> simply omits the auth block. It is only for YOUR private images: the Talos image package is public and needs
> no auth. GHCR only accepts a classic token; fine-grained tokens do not work for package pulls.

### Run

```bash
./03c_talos_cluster_config.sh
```

All values come from `.env`; review the printed summary, then type `YES`. After `apply-config` the nodes
reboot, the script waits for each to come back up (polling the secure API) and only then asks you to confirm the
bootstrap. No manual stopwatch.

> Bootstrap runs on one node only. Never re-run it on another node, or you split etcd into two clusters.

### Verify

```bash
export KUBECONFIG=./secrets/kubeconfig
kubectl get nodes -o wide                  # 3x NotReady, no CNI yet; flips to Ready after step 04 (Cilium)
talosctl -n <cp1-ip> etcd members          # 3 members
```

## Then: networking & hardening

Once the cluster is up (nodes NotReady, no CNI yet), in order:

1. NIC machine-config defences: `EthernetConfig` + `WatchdogTimerConfig`. Done by
   `03d_nic_hardening.sh`, see [NIC hardening](#nic-hardening-the-macb-wedge). Run before Cilium, so the NIC is
   hardened ahead of the network-heavy CNI rollout.
2. Cilium: CNI + LoadBalancer + gateway + WireGuard encryption; this is what flips the nodes to Ready. Done
   by `04_cilium.sh` (step 04), decision basis + detail in [04_networking.md](04_networking.md). The one
   imperative install; everything after it is GitOps.
3. ArgoCD: done by `05_argocd.sh` (step 05); it self-manages, then adopts Cilium, and everything below
   becomes declarative. See [05_gitops.md](05_gitops.md).
4. NIC recovery DaemonSet (`nic-keeper`: EEE-off + link-watchdog + `ss -K`): GitOps (ArgoCD), runs at
   sync-wave 2. See [Runtime: the recovery DaemonSet](#runtime-the-recovery-daemonset-nic-keeper-gitops) below.
5. etcd snapshot schedule.
6. Monitoring stack, then Longhorn on the reserved partition.

## NIC hardening: the macb wedge

The Pi 5 `macb` NIC wedges ([sbc-raspberrypi #91](https://github.com/siderolabs/sbc-raspberrypi/issues/91)).
A newer kernel does not fix it; the mitigation is config/runtime. Three triggers, and
the defence for each:

| macb trigger                    | defence                                                    | where                  |
|---------------------------------|------------------------------------------------------------|------------------------|
| silent TSO/GSO TX-ring hang     | offloads off + RX/TX rings -> NIC max (`EthernetConfig`)   | `03d` now              |
| full node hang                  | hardware watchdog reboots the node (`WatchdogTimerConfig`) | `03d` now              |
| EEE LPI-wake race               | `ethtool --set-eee end0 eee off`                           | `nic-keeper` DaemonSet |
| post-wedge kubelet socket stall | `ss -K` after recovery                                     | `nic-keeper` DaemonSet |
| silent-wedge detection/recovery | link-watchdog: `ip link` down/up                           | `nic-keeper` DaemonSet |

### `03d_nic_hardening.sh` (implemented now)

Fully automated, idempotent, safe to re-run. Reuses the dockerized `talosctl` + `kubectl`
and `secrets/` from cluster bring-up.

```bash
./03d_nic_hardening.sh
```

What it does:

1. Nodes from the talosconfig endpoints (`talosctl config info`); maps IP -> k8s node name.
2. Discovers the NIC facts instead of hardcoding them. Rings (pre-set max) and the exact
   offload feature keys come from Talos's own `EthernetStatus` resource. These are the
   kernel netdev names `EthernetConfig` accepts (e.g. `tx-tcp-segmentation`,
   `tx-generic-segmentation`, `rx-gro`), which differ from `ethtool -k`'s umbrella names.
   A temporary privileged probe pod (hostNetwork, pinned to one node, `kube-system`) reads
   only what has no resource: EEE controllability (`ethtool --show-eee`, captured for the
   deferred DaemonSet, not applied) and the watchdog device.
3. Generates the config: `EthernetConfig` (rings = discovered max; the settable,
   non-`[fixed]` TSO/GSO/GRO keys -> `false`) + `WatchdogTimerConfig` (discovered device;
   timeout clamped to `[10s, ~Pi-max]`).
4. Applies to every node with `talosctl patch mc --patch @... --mode no-reboot`, a
   document-level strategic merge that leaves `v1alpha1` untouched (so the live certSAN
   fix is preserved); never a full re-apply, never a reboot. `EthernetConfig` is
   delete-then-readd so its `features` map is authoritative each run (see caveats).
5. Verifies against the authoritative resources, per node, polled (the apply is async):
   `EthernetStatus` -> offloads off + rings at max; `WatchdogTimerStatus` -> armed with the
   set timeout. It never triggers the watchdog.
6. Waits for the network to settle. The `EthernetConfig` ring-resize re-inits the `macb`
   rings, which bounces `end0`'s link for a few seconds, and the control-plane VIP rides on
   `end0`. The verify in (5) only proves the config landed (`talosctl` hits node IPs directly),
   not that the VIP is reachable again; that blip is exactly what made a following `04_cilium`
   run hit `dial 192.168.100.1:6443: network is unreachable`. So before exiting, 03d polls the
   apiserver over the VIP (`kubectl get --raw=/readyz`) and requires `SETTLE_STREAK` (default 5)
   consecutive OKs within `SETTLE_WAIT` (default 60s); one success isn't enough (a single good
   hit is what fooled 04). A non-steady API fails the step, so `DANGEROUS_rebuild_cluster.sh`
   aborts at 03d instead of cascading a confusing failure into 04.
7. Cleans up the probe pod.

Reading the output: `[PASS]`/`[FAIL]` per check, then `summary: N passed, M failed`.
Exit 0 = all green. A `[FAIL]` on `patch` mentioning reboot means the change wanted a
reboot (it refused), investigate before forcing. A watchdog `[FAIL]` usually means the
timeout exceeded the hardware max, lower `WATCHDOG_TIMEOUT`. A `[FAIL]` on the settle check
means the VIP/API didn't steady within `SETTLE_WAIT`, let the NIC/control-plane settle (or raise
`SETTLE_WAIT`) before running 04, rather than pushing on into a flaky API.

### Runtime: the recovery DaemonSet (`nic-keeper`, GitOps)

The wedge itself is assumed tolerable, so runtime recovery lives in GitOps (ArgoCD), not
machine-config: the three triggers below have no `EthernetConfig` field and need a live agent.
That agent is `nic-keeper`, one DaemonSet pod per rpi5 node (namespace `kube-system`,
hostNetwork), delivered by ArgoCD ([05_gitops.md](05_gitops.md)) at sync-wave 2. No imperative
step. Chart: `argo_apps/platform/charts/02_nic_keeper/`; Application:
`argo_apps/platform/apps/02_nic_keeper.yaml`.

The three runtime `macb` failure modes machine-config can't reach (the other two are `03d`'s, see
the [table above](#nic-hardening-the-macb-wedge)):

| runtime trigger                    | what happens                                                    | defence                                       |
|------------------------------------|-----------------------------------------------------------------|-----------------------------------------------|
| EEE LPI-wake race                  | link wakes from low-power idle too slowly, drops frames         | assert `ethtool --set-eee end0 eee off`       |
| silent wedge                       | link stays up, carrier fine, but no traffic passes              | active ping probe -> bounce `ip link` down/up |
| post-recovery kubelet socket stall | kubelet's old TCP sockets to the API server hang after a bounce | `ss -K` drops them so they reconnect          |

On each node the single consolidated loop:

1. Asserts the NIC's power-saving mode off on start, and after every bounce, since a bounce can re-enable it.
2. Probes link health every `checkIntervalSeconds` (5s): pings the default gateway and reads
   `/sys/class/net/end0/carrier`. The ping is the real signal, because a wedge keeps carrier up, so
   carrier alone misses it.
3. On `failThreshold` (4) consecutive failures: `ip link set end0 down` -> brief sleep -> `up`,
   re-assert EEE off, `ss -K dport = :6443` to drop stale API-server sockets, then honours
   `cooldownSeconds` (60s) before probing again (anti-flap).

One structured stdout line per event (`<ts> nic-keeper iface=end0 event=<name> ...`). The loop
script lives in the chart's `templates/configmap.yaml` (mounted + exec'd); every knob is in its
`values.yaml`.

Decisions:

| decision                       | why                                                                                                                                                                                                                                                                                                                                                                                                                 |
|--------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| DaemonSet                      | the fix is per-node, on the host's NIC + netns, so one pod per node.                                                                                                                                                                                                                                                                                                                                                  |
| One consolidated agent         | EEE, link-watchdog and socket-drop share state (one wedge -> all three react); one loop beats three pods racing.                                                                                                                                                                                                                                                                                                    |
| Runtime, not machine-config    | no Talos `EthernetConfig` field for EEE; wedge detection is reactive; socket-drop is post-recovery.                                                                                                                                                                                                                                                                                                                 |
| Active ping, not carrier       | the wedge is link-up-no-traffic; carrier reads healthy, only a probe catches it.                                                                                                                                                                                                                                                                                                                                    |
| `NET_ADMIN` + `NET_RAW`        | NET_ADMIN covers `ethtool` EEE / `ip link` / `ss -K`; NET_RAW is required for `ping`'s ICMP socket. Still least-privilege, beats `privileged: true`.                                                                                                                                                                                                                                                                |
| Auto-sync (prune + selfHeal)   | safe leaf: it cannot cut the cluster off its own network, so drift just auto-corrects. Cilium (wave 0) runs the SAME prune+selfHeal even though it CAN cut the cluster off its own network: a convenience trade-off, knowingly accepted.                                                                                                                                                                                                                                |
| `instance-type: rpi5` selector | the macb wedge is Pi 5-only. Stamped by Talos `machine.nodeLabels` in [`03c`](#what-03c_talos_cluster_configsh-does) (`NODE_INSTANCE_TYPE` knob in `03c`); that key works because it's on the kubelet NodeRestriction allowlist (an arbitrary `kubernetes.io/*` label is rejected by admission). Not `os: linux` (too broad) nor `control-plane:DoesNotExist` (every node here is control-plane -> matches zero nodes). |

Caveats / preconditions:

- Kernel: older Pi 5 kernels can't toggle EEE; the loop logs `event=eee-unsupported` and keeps
  running the link-watchdog. The custom image already ships a new-enough kernel (see [the build](#the-build)).
- `CONFIG_INET_DIAG_DESTROY` is required for `ss -K`; absent, the loop logs `event=ss-k-unsupported`
  once and skips the socket-drop (link bounce + EEE still run).
- A brief link bounce (~2s, `linkDownSeconds`) is expected on every recovery.
- Never trips the `03d` hardware watchdog: every action is short and the loop always makes progress
  (no unbounded waits).
- Thresholds are tunable in `values.yaml` (`checkIntervalSeconds`, `failThreshold`, `linkDownSeconds`,
  `cooldownSeconds`, `ssKillFilter`, `pingTarget`). The agent only ever touches `iface` (`end0`).

Verify (GitOps, no imperative step):

```bash
export KUBECONFIG=./secrets/kubeconfig
kubectl get ds -n kube-system nic-keeper                           # DESIRED = CURRENT = READY = 3
kubectl logs -n kube-system -l app.kubernetes.io/name=nic-keeper   # one pod per node; event=eee-off ok
kubectl get nodes -L node.kubernetes.io/instance-type              # all three show rpi5
```

A recovery, in the affected node's pod logs:

```
... event=probe-fail target=192.168.10.1 carrier=1 count=4/4
... event=wedge fail_count=4 threshold=4 carrier=1 (bouncing link)
... event=ss-kill filter='dport = :6443' result=...
... event=recovery link bounced + eee re-asserted; cooldown=60s
```

> Live cluster (label not yet present): if the cluster predates the `03c` change, stamp the label
> without a reboot the same way `03d` patches config:
>
`talosctl -n <node-ip> patch mc --mode no-reboot --patch '{"machine":{"nodeLabels":{"node.kubernetes.io/instance-type":"rpi5"}}}'`
> (repeat per node). Otherwise the DaemonSet has nothing to schedule onto.

### Caveats

- Feature keys are kernel netdev names, not `ethtool -k` names. `EthernetConfig`
  (and `EthernetStatus`) use `tx-tcp-segmentation` / `tx-generic-segmentation` / `rx-gro`,
  not the umbrella `tcp-segmentation-offload` etc. Talos accepts a wrong key but it
  fails the whole ethtool reconcile (`bit name not found`), so every offload silently
  stays on. `03d` sources the keys from `EthernetStatus` to avoid this; don't hand-edit.
- `features` map is replaced, not merged. Strategic merge unions maps, so a stale or
  renamed key would linger and break the reconcile. `03d` deletes the `EthernetConfig`
  document (`$patch: delete`) then re-adds it, authoritative + idempotent each run.
- Discovered, not hardcoded: ring max + the watchdog device/timeout ceiling are
  driver/hardware-specific (Pi `bcm2712` watchdog max ~15s; Talos min 10s), `03d` reads
  them live and clamps.
- certSAN-preserving apply: only `talosctl patch mc` (document merge). Never
  `apply-config`/full replace, which would clobber the live certSAN fix.
- `kube-system` PSS exemption: Talos applies Pod Security elsewhere; the privileged
  probe pod runs in `kube-system`, which is exempt.
- Image: the recent kernel that makes EEE controllable comes from the image repo; the EEE
  step itself is in the deferred DaemonSet, not the image.

## Troubleshooting

Image build:

- Problems building the image live in its own repo, see
  [docs/build.md](https://github.com/yama6a/talos-raspberry-pi5/blob/main/docs/build.md).

Flash:

- `download failed` -> `TALOS_IMAGE_RELEASE` names a release that does not exist. Check the image repo's
  releases page.
- `checksum mismatch` -> a truncated download. Delete `.cache/images/<release>/` and re-run.

Boot:

- Node never appears on the network -> kernel is missing RP1 NIC support, or the overlay/u-boot didn't land on the
  EFI partition (offline validation catches the latter). Attach HDMI or a USB-UART serial console (115200 baud,
  `ttyAMA10`) to see what's happening.
- Won't boot at all -> EEPROM boot order / `PCIE_PROBE` (step 02).
- NVMe not detected -> PCIe probe / `dtparam`; confirm Gen 2 link with step 02's checks.
- Node is gone for good and needs replacing -> [15_node_recovery.md](15_node_recovery.md). Do NOT re-run `03c`
  as-is: it ends by bootstrapping etcd, which is for creating a cluster, not rejoining one.

(Cilium / networking troubleshooting lives in [04_networking.md](04_networking.md).)

## Reference

- Pi 5 Talos image (the build, the kernel, the releases): <https://github.com/yama6a/talos-raspberry-pi5>
- Talos releases: <https://github.com/siderolabs/talos/releases>
- Upgrades: <https://www.talos.dev/latest/talos-guides/upgrading-talos/>
- Pi 5 macb wedge (why the NIC fix lives in step 04 config, not the
  image): <https://github.com/siderolabs/sbc-raspberrypi/issues/91>
- Cilium on Talos (KubePrism, kube-proxy replacement, cgroup/securityContext):
  <https://docs.cilium.io/en/stable/installation/k8s-install-helm/>
- Envoy Gateway (the cluster's Gateway API data plane; Cilium's gatewayAPI is
  disabled): <https://gateway.envoyproxy.io/>
- Cilium LB-IPAM + L2 announcements: <https://docs.cilium.io/en/stable/network/lb-ipam/>
- ingress-nginx retirement (why Gateway API): <https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/>
