# Talos: OS choice, custom NVMe image & cluster bring-up

OS for the 3-node Pi 5 cluster: Talos Linux. Immutable, API-managed, Kubernetes-only.
Talos has no official Pi 5 image, so we build our own against the latest Talos on a recent Raspberry Pi kernel.

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
- Upgrading Talos = rebuild the image.
- We own the build. New Talos release -> re-run the builder, possibly re-apply the rebases too.
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

## Why build our own instead of using the community release

The [talos-rpi5](https://github.com/talos-rpi5/talos-builder) project publishes a prebuilt Pi 5 image, but it lags
well behind latest Talos (and ships an older kernel). We want latest Talos + a recent Pi kernel + control over the
upgrade path, and that combination doesn't exist as a published image anywhere:

- Raspberry Pi OS ships a Pi 5 kernel, but it's not a Talos kernel. Talos welds a hardened, clang/ThinLTO kernel into
  its initramfs/installer, so you can't just drop a foreign kernel in.
- The official Talos `metal-arm64` image won't boot a Pi 5 headlessly. Even though recent Talos ships a similarly
  recent kernel, it's missing the fork-only RP1 bring-up (`MFD_RP1`) and has no Pi 5 boot chain (u-boot + BCM2712
  device tree).
- The only prebuilt Talos Pi 5 image is the community one, which is old.

So we drive the `talos-rpi5` pipeline but rebase it onto latest Talos. The recent Pi kernel is the whole point: it
carries the upstream RP1 patches that allow step 04 to disable EEE on the NIC.

## Versions

Every pin lives in `.env` (template `.env.example`); Renovate opens PRs to bump them, grouped as the "talos
build recipe" and PR-only — merging changes only `.env`, a real bump needs a manual image rebuild (below). What
each is, and the constraints that matter:

- **Talos** (`TALOS_VERSION`, `siderolabs/talos`) — the release we rebase onto.
- **Kubernetes** (`KUBERNETES_VERSION`) — the pin `03d` passes to `gen config` and `03g` upgrades to. Ceiling =
  the Talos release's own k8s default; raise it only after bumping Talos.
- **pkgs** (`PKG_VERSION`, `siderolabs/pkgs`) — ships a stock arm64 kernel config (already 4K pages).
- **Kernel** (`KERNEL_REF`, `raspberrypi/linux` on the current rpi kernel line) — the kernel line is the whole point:
  it carries the RP1 patches step 04 needs to disable EEE on the NIC.
- **Overlay** (`SBCOVERLAY_VERSION`, `talos-rpi5/sbc-raspberrypi5`@`main`) — u-boot + rpi firmware + the Pi 5 boot
  chain; ported to the pinned Talos machinery at build time.
- **Extensions** (`ISCSI_EXT`, `UTIL_EXT`) — digest-pinned system extensions from the Image Factory.

## The build

Script: `03a_talos_image_builder.sh` (MacOS, Apple Silicon). All config (version knobs, kernel ref, registry,
extensions) lives in `.env` (build-cache output path derived in `lib/shell/common.sh`), shared by all the step-03
scripts.
A clean run builds and validates; it exits non-zero if anything goes wrong.

What it does:

1. spins up a local registry + a mergeop-capable buildx builder
2. clones and checks out `talos-builder`
3. applies the four rebases
4. builds kernel
5. overlay
6. installer
7. raw image
8. runs offline validation

Prerequisites (the script checks all of these, with the `brew` fix for each):

- GNU make >= 4 (`brew install make` -> use `gmake`). MacOS ships make 3.81, which the kres Makefiles refuse to run.
- xz, zstd, jq, curl, go, and Docker (Rancher Desktop works) with an arm64 Linux VM.
- Disk space: give the Docker VM >= 120 GB. We had 98 GB and ran out mid-kernel-build.

The four rebases (things the upstream pipeline can't handle at this Talos version, all automated by the script):

1. Kernel source + config: Point the kernel at `raspberrypi/linux@<tag>` and layer a small Pi 5/RP1 config fragment on
   top of the stock kernel config, then reconcile with `make olddefconfig` under the real clang toolchain. The build fails
   immediately if any required symbol didn't make it in (4K pages, NVMe, MACB, watchdog, RP1, BCM2712).
2. Module list: Filter `hack/modules-arm64.txt` to what the rpi kernel actually built. The stock list references
   drivers our config doesn't include (e.g. `bnxt_re`), and `nvme` is now built-in rather than a module. The script
   regenerates the list by intersecting against the real kernel module tree.
3. Overlay port: The overlay (copies u-boot/config.txt/dtb to disk) was written against older machinery; a newer
   Talos's overlay API added a `ctx` argument. The script bumps machinery to match and patches `main.go` in the overlay.
4. Grub profile: Build with the overlay's `rpi5` grub profile, not `metal`. Talos's `metal` default is
   sd-boot, and sd-boot's image path silently skips the overlay installer entirely. So a Pi 5 image built as `metal`
   has the kernel but no u-boot/config.txt/dtb and won't boot. The grub profile runs the overlay install
   properly and the EFI partition ends up with the boot bits it needs.

```bash
lib/shell/03a_talos_image_builder.sh
```

The first run takes a while. Full clang/ThinLTO kernel compile is 30-40 min on 12 cores (macBook Pro, M2 Pro). Later
runs faster with cache kernel layer.

## What's baked into the image

- 4K kernel pages (`CONFIG_ARM64_4K_PAGES=y`, not the Pi defconfig's 16K). Etcd and Kubernetes are fine on 16K, but
  there is some software that has 16K compatibility issues. 4K is also what stock Talos `metal-arm64` uses. We Keep page
  size the same on all three nodes.
- System extensions (baked at the installer step): `iscsi-tools` (iscsid, required by Longhorn) and
  `util-linux-tools` (fstrim).
- Radios off: `dtoverlay=disable-wifi` + `dtoverlay=disable-bt` in the overlay's `config.txt`, plus the `.dtbo`
  files. This saves some marginal power and CPU cycles (kernel probes). And we will never use WiFi or Bluetooth anyway.
- Built-in (`=y`) drivers needed for step 04 (hardening) and Longhorn: Pi 5 watchdog (`BCM2835_WDT`), NVMe + PCIe
  (`PCIE_BRCMSTB`), the Pi 5 NIC (`MACB` + PHYLINK/PHYLIB/BROADCOM_PHY), RP1 bring-up (`MFD_RP1`, `BCM2712_MIP`, ...).

## Registry & upgrades

The build runs against a **local** registry (`localhost:5010`): it's fast, supports the BuildKit mergeop `bldr` needs,
and works offline. That's where we put the kernel, overlay, and installer layers which `03a` builds.

**Publishing the installer (for network upgrades).** After validation, `03a` optionally publishes the finished
installer image to GHCR that can be used for talos upgrades (`03f`). For that, set `GITHUB_GHCR_PUSH_TOKEN_SECRET` (a
classic token scoped `write:packages`) in `.env`. This will let `03a` push the installer image to
`ghcr.io/<GHCR_USER>/<INSTALLER_PACKAGE>:<TALOS_VERSION>-arm64`. Id you leave the token empty to skip publishing. This
allows a first bootstrap of all nodes, but later upgrades won't work.

**Upgrading the cluster.** During first setup, the NVMe is flashed once (`03b`). After that, Talos upgrades are
atomic A/B over the network without needing manua reflashing. For that, bump the Talos version in `.env`, re-run
`03a` to build + publish the new installer, then run **`03f_talos_upgrade.sh`** which runs
`talosctl upgrade --image "$INSTALLER_REF"` one node at a time. This is re-run-safe (an already-upgraded node is a
no-op). The nodes pull the installer using the `read:packages` auth `03d` baked into their machine config in `03d`.

**Upgrading Kubernetes (separate from the OS).** The Talos OS version and the Kubernetes version upgrade independently.
`03g_k8s_upgrade.sh` updates the k8s control plane (`talosctl upgrade-k8s --to "$KUBERNETES_VERSION"`). So bump *only*
`KUBERNETES_VERSION` in `.env`, and then run `03g`. `KUBERNETES_VERSION` can't exceed the pinned Talos release's default
k8s version (its supported ceiling). So it is useful to always first bump Talos.

## Validation (offline, no hardware)

Runs at the end of the builder. MacOS can't loop-mount Linux filesystems, so this runs inside a privileged Linux
container. Exits non-zero on any failure.

- Integrity + size: `xz -t` passes; compressed image size is in a reasonable range.
- Partition layout: loop-mount the raw image; confirm `EFI` + `BOOT` + `META` (grub layout). `STATE` and
  `EPHEMERAL` don't exist yet, they're created on first boot.
- Pi 5 boot bits in the EFI partition: `config.txt` (with the disable-wifi/bt lines), `u-boot.bin`,
  `bcm2712-rpi-5-b.dtb`, `overlays/disable-{wifi,bt}.dtbo`.
- Kernel version: pulled from the installer UKI's `.uname` section. Asserts the expected rpi kernel line, which proves
  the kernel actually got swapped out.
- Extensions baked: decompress the UKI's `.initrd` and confirm `iscsi-tools` and `util-linux-tools` are in there.

## Flash the NVMe

Script: `03b_talos_image_flasher.sh` (MacOS). `dd`s the locally built image (`.raw.xz`) to an NVMe over a USB adapter.
Has the usual safeguards: lists disks, requires typing `YES`, writes to `/dev/rdiskN`, ejects.

### Per drive

Run the script, pick the USB-NVMe adapter's disk id, confirm. Repeat for each SSD, just swap drives in the adapter. Then
slot the SSD into a Pi, power on with no SD card -> Talos boots into maintenance mode (no role assigned yet).

## Boot & verify (per node)

Script: `03c_talos_boot_verify.sh`, reads the node IPs (`CLUSTER_NODES` in `.env`) and runs the checklist below against
each (maintenance mode, `--insecure`), inspecting each output and printing PASS/FAIL + a summary. It uses the talosctl
container (sidesteps the MacOS gotcha below); `ping`/`nc` run natively.

```bash
./03c_talos_boot_verify.sh        # checks the nodes listed in .env
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
talosctl() { docker run --rm --network host -v "$HOME/.talos:/root/.talos" ghcr.io/siderolabs/talosctl:<TALOS_VERSION> "$@"; }  # match TALOS_VERSION in .env
```

Drop that in `~/.zshrc` or `~/.bash_profile`, reload, and `talosctl` works normally from there.

## Cluster bring-up

Per-node identity (hostname, role) is applied now via `talosctl`. The CNI is disabled at the Talos layer (`cni: none`)
and kube-proxy is off (`proxy.disabled: true`), both replaced by Cilium in [step 04](04_networking.md). All three nodes
are control-plane and schedulable. Nodes come up NotReady until Cilium lands, that's expected, not a fault.

> The cluster name, VIP, install disk, NIC, and the node list (hostname + IP per node) all live in `.env`, nothing is
> hardcoded in the script. Edit them there to match your network.

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

### What `03d_talos_cluster_config.sh` does

1. Reads cluster name, install disk, EPHEMERAL cap, NIC, the VIP, and each node's hostname + IP from
   `.env`, prints a summary, and waits for a `YES` confirmation.
2. Prepares the config. The **durable secrets bundle** (`secrets.yaml` — the cluster PKI: CA, service-account
   key, bootstrap/join tokens) is generated **once** and never rotated, so the cluster identity survives every
   re-run and rebuild. Everything else is **disposable scratch re-rendered each run**: `talosctl gen config
   --with-secrets secrets.yaml --force` regenerates the base machine config from that bundle + the *current*
   `.env` knobs, so a version bump in `.env` actually lands (unlike the old preserved `controlplane.yaml`,
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
   `NODE_INSTANCE_TYPE` in `.env`), and the Cilium prep: `cluster.network.cni.name: none`,
   `cluster.proxy.disabled: true` (Cilium does kube-proxy replacement), and `machine.features.kubePrism.enabled: true`
   (Cilium's API endpoint at `localhost:7445`; default-on in recent Talos, set explicitly here to document the dependency).
   Finally it raises etcd's timeouts — `cluster.etcd.extraArgs: {heartbeat-interval: "500", election-timeout: "5000"}`,
   5x etcd's 100ms/1000ms defaults. All three nodes are control-plane + worker and etcd shares the single NVMe with
   Longhorn + CNPG, so during the cold-boot I/O storm etcd's fsyncs stall past the default 1000ms election window and
   trigger a burst of spurious leader elections — which disrupts apiserver watches and lags the controllers (e.g.
   cert-manager's HTTP-01 solver endpoints fail to program in time, wedging cert issuance). The 5s election timeout
   rides out the stalls; the only cost is ~5s vs ~1s failover if a leader truly dies, a non-issue on this cluster.
4. Appends the partition layout: `EPHEMERAL` capped (default 64 GiB) + a fixed-size `localpath` user volume
   (default 50 GiB, `min == max`, at `/var/mnt/localpath`, node-local storage for CNPG + RabbitMQ via
   [local-path-provisioner](08_storage.md)) + a `longhorn` user volume taking the rest of the NVMe
   (`/var/mnt/longhorn`). Both `/var/mnt` paths also get a `kubelet.extraMounts` bind so the containerized kubelet
   can see them. Sit empty until their apps sync (step 04+).
5. `apply-config` to each node (only the hostname differs), then deletes the rendered scratch (`cp.yaml`,
   `controlplane.yaml`, and their inputs `cp-patch.yaml` + `volumes.yaml`) — the nodes now hold their own
   live config, so the only config left on disk is the durable `secrets.yaml` (plus the
   `talosconfig`/`kubeconfig` creds). On an apply failure the script aborts before the cleanup, leaving the
   files for inspection.
6. Waits for every node to reboot back into its configured state (polls the secure Talos API per node, up to 5 min
   each), so the bootstrap prompt only appears once the nodes are actually ready, no guessing.
7. `bootstrap` etcd once on the first node (after a confirm); the others join automatically.
8. Waits for health, writes `kubeconfig`.

> NIC selector: the VIP is bound to `interface: end0` (the Pi 5 wired NIC) rather than `physical: true`, so it can
> never latch onto WiFi. Confirm the name on a live node with `talosctl get links` if unsure (`EXPECT_NIC` in `.env`,
> default `end0`).

> GHCR registry auth (optional, global): to pull private container images, `03d` reads `GITHUB_GHCR_PULL_TOKEN_SECRET`
> (a GitHub classic token scoped `read:packages`) from the gitignored `.env` and bakes a
> `machine.registries.config."ghcr.io".auth` block into the control-plane patch. The kubelet/CRI then authenticates
> every pull from `ghcr.io` on every node, cluster-wide, with no per-namespace `imagePullSecrets` to wire into
> workloads. We chose node-level auth over an in-cluster (sealed-secret) pull secret precisely because it's global
> and namespace-agnostic; the cost is that the token lives in the machine config (in the gitignored
> `secrets/cp-patch.yaml`, never committed) rather than in the sealed-secrets pipeline, and rotating it means
> editing `.env` and re-running `03d`. The host + username are plain config (`GHCR_SERVER`/`GHCR_USER`); leave
> `GITHUB_GHCR_PULL_TOKEN_SECRET` empty to skip (the auth block is simply omitted). This is the **pull** token —
> distinct
> from the `write:packages` `GITHUB_GHCR_PUSH_TOKEN_SECRET` `03a` uses to publish, which never touches node config. GHCR
> only accepts a classic token; fine-grained tokens do not work for package pulls.

### Run

```bash
./03d_talos_cluster_config.sh
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
   `03e_nic_hardening.sh`, see [NIC hardening](#nic-hardening-the-macb-wedge). Run before Cilium, so the NIC is
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
| silent TSO/GSO TX-ring hang     | offloads off + RX/TX rings -> NIC max (`EthernetConfig`)   | `03e` now              |
| full node hang                  | hardware watchdog reboots the node (`WatchdogTimerConfig`) | `03e` now              |
| EEE LPI-wake race               | `ethtool --set-eee end0 eee off`                           | `nic-keeper` DaemonSet |
| post-wedge kubelet socket stall | `ss -K` after recovery                                     | `nic-keeper` DaemonSet |
| silent-wedge detection/recovery | link-watchdog: `ip link` down/up                           | `nic-keeper` DaemonSet |

### `03e_nic_hardening.sh` (implemented now)

Fully automated, idempotent, safe to re-run. Reuses the dockerized `talosctl` + `kubectl`
and `secrets/` from cluster bring-up.

```bash
./03e_nic_hardening.sh
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
   run hit `dial 192.168.100.1:6443: network is unreachable`. So before exiting, 03e polls the
   apiserver over the VIP (`kubectl get --raw=/readyz`) and requires `SETTLE_STREAK` (default 5)
   consecutive OKs within `SETTLE_WAIT` (default 60s); one success isn't enough (a single good
   hit is what fooled 04). A non-steady API fails the step, so `DANGEROUS_rebuild_cluster.sh`
   aborts at 03e instead of cascading a confusing failure into 04.
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
hostNetwork), delivered by ArgoCD ([05_gitops.md](05_gitops.md)) at sync-wave 2 — no imperative
step. Chart: `argo_apps/platform/charts/02_nic_keeper/`; Application:
`argo_apps/platform/apps/02_nic_keeper.yaml`.

The three runtime `macb` failure modes machine-config can't reach (the other two are `03e`'s, see
the [table above](#nic-hardening-the-macb-wedge)):

| runtime trigger                    | what happens                                                    | defence                                       |
|------------------------------------|-----------------------------------------------------------------|-----------------------------------------------|
| EEE LPI-wake race                  | link wakes from low-power idle too slowly, drops frames         | assert `ethtool --set-eee end0 eee off`       |
| silent wedge                       | link stays up, carrier fine, but no traffic passes              | active ping probe -> bounce `ip link` down/up |
| post-recovery kubelet socket stall | kubelet's old TCP sockets to the API server hang after a bounce | `ss -K` drops them so they reconnect          |

On each node the single consolidated loop:

1. Asserts EEE off on start (and after every bounce — a bounce can re-enable it).
2. Probes link health every `checkIntervalSeconds` (5s): pings the default gateway and reads
   `/sys/class/net/end0/carrier`. The ping is the real signal — a wedge keeps carrier up, so
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
| DaemonSet                      | the fix is per-node, on the host's NIC + netns — one pod per node.                                                                                                                                                                                                                                                                                                                                                  |
| One consolidated agent         | EEE, link-watchdog and socket-drop share state (one wedge -> all three react); one loop beats three pods racing.                                                                                                                                                                                                                                                                                                    |
| Runtime, not machine-config    | no Talos `EthernetConfig` field for EEE; wedge detection is reactive; socket-drop is post-recovery.                                                                                                                                                                                                                                                                                                                 |
| Active ping, not carrier       | the wedge is link-up-no-traffic; carrier reads healthy, only a probe catches it.                                                                                                                                                                                                                                                                                                                                    |
| `NET_ADMIN` + `NET_RAW`        | NET_ADMIN covers `ethtool` EEE / `ip link` / `ss -K`; NET_RAW is required for `ping`'s ICMP socket. Still least-privilege, beats `privileged: true`.                                                                                                                                                                                                                                                                |
| Auto-sync (prune + selfHeal)   | safe leaf — it can't cut the cluster off its own network, so drift just auto-corrects. Cilium (wave 0) runs the SAME prune+selfHeal even though it CAN cut the cluster off its own network — a convenience trade-off, knowingly accepted.                                                                                                                                                                                                                                |
| `instance-type: rpi5` selector | the macb wedge is Pi 5-only. Stamped by Talos `machine.nodeLabels` in [`03d`](#what-03d_talos_cluster_configsh-does) (`NODE_INSTANCE_TYPE` in `.env`); that key works because it's on the kubelet NodeRestriction allowlist (an arbitrary `kubernetes.io/*` label is rejected by admission). Not `os: linux` (too broad) nor `control-plane:DoesNotExist` (every node here is control-plane -> matches zero nodes). |

Caveats / preconditions:

- Kernel: older Pi 5 kernels can't toggle EEE; the loop logs `event=eee-unsupported` and keeps
  running the link-watchdog. The custom image already ships a new-enough kernel (see [the build](#the-build)).
- `CONFIG_INET_DIAG_DESTROY` is required for `ss -K`; absent, the loop logs `event=ss-k-unsupported`
  once and skips the socket-drop (link bounce + EEE still run).
- A brief link bounce (~2s, `linkDownSeconds`) is expected on every recovery.
- Never trips the `03e` hardware watchdog: every action is short and the loop always makes progress
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

> Live cluster (label not yet present): if the cluster predates the `03d` change, stamp the label
> without a reboot the same way `03e` patches config:
>
`talosctl -n <node-ip> patch mc --mode no-reboot --patch '{"machine":{"nodeLabels":{"node.kubernetes.io/instance-type":"rpi5"}}}'`
> (repeat per node). Otherwise the DaemonSet has nothing to schedule onto.

### Caveats

- Feature keys are kernel netdev names, not `ethtool -k` names. `EthernetConfig`
  (and `EthernetStatus`) use `tx-tcp-segmentation` / `tx-generic-segmentation` / `rx-gro`,
  not the umbrella `tcp-segmentation-offload` etc. Talos accepts a wrong key but it
  fails the whole ethtool reconcile (`bit name not found`), so every offload silently
  stays on. `03e` sources the keys from `EthernetStatus` to avoid this; don't hand-edit.
- `features` map is replaced, not merged. Strategic merge unions maps, so a stale or
  renamed key would linger and break the reconcile. `03e` deletes the `EthernetConfig`
  document (`$patch: delete`) then re-adds it, authoritative + idempotent each run.
- Discovered, not hardcoded: ring max + the watchdog device/timeout ceiling are
  driver/hardware-specific (Pi `bcm2712` watchdog max ~15s; Talos min 10s), `03e` reads
  them live and clamps.
- certSAN-preserving apply: only `talosctl patch mc` (document merge). Never
  `apply-config`/full replace, which would clobber the live certSAN fix.
- `kube-system` PSS exemption: Talos applies Pod Security elsewhere; the privileged
  probe pod runs in `kube-system`, which is exempt.
- Image: see step 03a (build) for the recent kernel that makes EEE controllable; the EEE
  step itself is in the deferred DaemonSet, not the image.

## Troubleshooting

Build:

- `ping failed` can happen because of the NIC bug. Re-run the validator a few times. If it fails occasionally, just move
  on, we will fix/mitigate this in a later step.
- `missing separator` in a Makefile -> you're on make 3.81; use `gmake` (the script already does this).
- `mergeop has been disabled` -> Rancher's default builder can't run siderolabs `bldr`; the script creates a
  `docker-container` buildx builder that can.
- `no space left on device` during kernel finalize -> Docker VM disk is too small; bump it in Rancher Desktop ->
  Virtual Machine, or via a Lima `disk:` override + recreate.
- `BAKE-IN MISSING: <SYM>` -> a kernel config symbol didn't reconcile (unmet dependency); adjust the config fragment.
- `cannot stat .../<mod>.ko` at initramfs -> module list drifted; the script's filter handles this, just re-run.
- `digest mismatch` on the kernel source -> GitHub `/archive/` tarballs aren't byte-stable across requests. The builder
  hashes one download and serves it from a local HTTP server for the rest of the build. Nothing to do.

Boot:

- Node never appears on the network -> kernel is missing RP1 NIC support, or the overlay/u-boot didn't land on the
  EFI partition (offline validation catches the latter). Attach HDMI or a USB-UART serial console (115200 baud,
  `ttyAMA10`) to see what's happening.
- Won't boot at all -> EEPROM boot order / `PCIE_PROBE` (step 02).
- NVMe not detected -> PCIe probe / `dtparam`; confirm Gen 2 link with step 02's checks.

(Cilium / networking troubleshooting lives in [04_networking.md](04_networking.md).)

## Reference

- talos-builder: <https://github.com/talos-rpi5/talos-builder>
- raspberrypi/linux: <https://github.com/raspberrypi/linux>
- Talos releases: <https://github.com/siderolabs/talos/releases>
- extensions: <https://github.com/siderolabs/extensions>
- Boot assets / imager: <https://www.talos.dev/latest/talos-guides/install/boot-assets/>
- Upgrades: <https://www.talos.dev/latest/talos-guides/upgrading-talos/>
- Pi 5 macb wedge (why the NIC fix lives in step 04 config, not the
  image): <https://github.com/siderolabs/sbc-raspberrypi/issues/91>
- Cilium on Talos (KubePrism, kube-proxy replacement, cgroup/securityContext):
  <https://docs.cilium.io/en/stable/installation/k8s-install-helm/>
- Envoy Gateway (the cluster's Gateway API data plane; Cilium's gatewayAPI is
  disabled): <https://gateway.envoyproxy.io/>
- Cilium LB-IPAM + L2 announcements: <https://docs.cilium.io/en/stable/network/lb-ipam/>
- ingress-nginx retirement (why Gateway API): <https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/>
- Worked examples: <https://kcirtap.io/posts/talos-rpi5-custom-kernel-build/>
  and <https://rcwz.pl/2025-10-04-installing-talos-on-raspberry-pi-5/>
