# Talos. OS choice & custom NVMe image

OS for the 3-node Pi 5 cluster: **Talos Linux**. Immutable, API-managed, Kubernetes-only. The whole node is one
declarative config: no SSH, no package manager, no drift. Talos has no official Pi 5 image, so we build our own
against the latest Talos on a recent Raspberry Pi kernel. This doc covers why we picked Talos, what we looked at and
rejected, and how the NVMe image gets built, validated, and flashed. Cluster config (IPs, VIP, partitions) is in
`04_talos_setup.md`.

## Why Talos

- **Whole node = one declarative config.** Managed via `talosctl`. Everything-as-code without exception.
- **Identical nodes.** Same image on every board; what makes a node different is just its config (step 04).
- **Atomic A/B upgrades + rollback** via `talosctl upgrade`. No in-place mutation.
- **Minimal attack surface.** No shell, no SSH, ~12 host binaries. WiFi/Bluetooth/cron daemons aren't in the image at
  all.
- **Kubernetes built in.** PCIe, cgroups, link speed are all baked into the image. No manual `config.txt` wrangling like
  on
  Raspberry Pi OS.

## Trade-offs

- **Pi 5 isn't officially supported.** Talos ships no Pi 5 image; BCM2712 + RP1 needs drivers that only exist in the
  `raspberrypi/linux` fork. We build against the [talos-rpi5](https://github.com/talos-rpi5/talos-builder) pipeline,
  rebased onto latest Talos (details below). Upgrading Talos = rebuild the image.
- **We own the build.** New Talos release -> re-run the builder, possibly re-apply the rebases too.
- **API-only, no shell.** A hung node gets rebooted, not SSH'd into.
- **Pi 5 NIC bug:** silent `macb` link wedge that needs mitigation, handled in step 05. The image's job on the NIC side
  is just shipping the newer kernel that makes EEE actually disableable (6.12 can't do it on Pi 5; 6.18 can).

## OSes considered

| OS / distro                                | Verdict                                                                                                   |
|--------------------------------------------|-----------------------------------------------------------------------------------------------------------|
| **Talos Linux**                            | **Chosen.** Immutable, declarative, identical nodes, K8s built in.                                        |
| k3s on Ubuntu Server                       | Runner-up. 4K pages + cgroups out of the box, biggest community. But mutable, more moving parts.          |
| k3s / kubeadm on Raspberry Pi OS           | Two Pi-5 traps: manual cgroup `cmdline.txt` edit + 16K-page kernel (must switch to 4K). No gain headless. |
| k0s on Ubuntu                              | Lightest footprint, clean `k0sctl` spec. Smaller ecosystem; no real advantage over Talos here.            |
| NixOS + k3s                                | Fully declarative, closest rival to Talos. Steep Nix learning curve, smaller Pi 5 community.              |
| Flatcar / Fedora CoreOS / openSUSE MicroOS | Also immutable, but Pi 5 support is thinner/younger. Talos wins on the declarative side.                  |
| Harvester                                  | Not even close. Full HCI/KubeVirt stack, needs x86_64 and a lot of RAM.                                   |

## Why build our own instead of using the community release

The [talos-rpi5](https://github.com/talos-rpi5/talos-builder) project publishes a prebuilt Pi 5 image, but it's stuck
at **Talos v1.11.5 (kernel ~6.12)**. We want latest Talos + a recent Pi kernel + control over the upgrade path, and
that combination doesn't exist as a published image anywhere:

- Raspberry Pi OS ships a Pi 5 kernel, but it's not a Talos kernel. Talos welds a hardened, clang/ThinLTO kernel into
  its initramfs/installer, so you can't just drop a foreign kernel in.
- The official Talos `metal-arm64` image won't boot a Pi 5 headlessly. Even though Talos 1.13 ships kernel 6.18, it's
  missing the fork-only RP1 bring-up (`MFD_RP1`) and has no Pi 5 boot chain (u-boot + BCM2712 device tree).
- The only prebuilt Talos Pi 5 image is the community one, which is old.

So we drive the `talos-rpi5` pipeline but rebase it onto latest Talos. The 6.18 kernel is the whole point: it carries
the upstream RP1 patches that let step 05 disable EEE on the NIC.

## Versions (pinned)

| Component  | Pin                                             | Notes                                                                            |
|------------|-------------------------------------------------|----------------------------------------------------------------------------------|
| Talos      | **`v1.13.4`**                                   | `siderolabs/talos`                                                               |
| pkgs       | **`v1.13.0`**                                   | `siderolabs/pkgs`. Ships a stock 6.18 arm64 kernel config (already 4K pages)     |
| Kernel     | **`raspberrypi/linux` `stable_20260609`**       | = Linux 6.18.34 on `rpi-6.18.y`; in-image string `6.18.34-talos`                 |
| Overlay    | **`talos-rpi5/sbc-raspberrypi5` `main`**        | u-boot `v2025.04-rpi5-3`, rpi firmware `1.20250430`; ported to machinery v1.13.4 |
| Extensions | `iscsi-tools:v0.2.0`, `util-linux-tools:2.41.4` | digest-pinned from the Image Factory                                             |

## The build

Script: **`03_talos_image_builder.sh`** (macOS, Apple Silicon). All config (version knobs, kernel ref, registry,
extensions, output path) lives in **`03_config.sh`**, shared by all three step-03 scripts. A clean run builds and
validates; it exits non-zero if anything goes wrong.

What it does: spins up a local registry + a mergeop-capable buildx builder -> clones and checks out `talos-builder` ->
applies the four rebases -> builds kernel -> overlay -> installer -> raw image -> runs offline validation.

**Prerequisites** (the script checks all of these, with the `brew` fix for each):

- **GNU make >= 4** (`brew install make` -> use `gmake`). macOS ships make 3.81, which the kres Makefiles refuse to run.
- **xz, zstd, jq, curl, go**, and **Docker** (Rancher Desktop works) with an **arm64 Linux VM**.
- **Disk space:** give the Docker VM **>= 120 GB**. 98 GB ran out mid-kernel-build.

**The four rebases** (things the upstream pipeline can't handle at this Talos version, all automated by the script):

1. **Kernel source + config.** Point the kernel at `raspberrypi/linux@<tag>` (sha-verified) and layer a small Pi 5/RP1
   config fragment on top of the stock 6.18 config, then reconcile with `make olddefconfig` under the real clang
   toolchain. The build fails immediately if any required symbol didn't make it in (4K pages, NVMe, MACB, watchdog, RP1,
   BCM2712).
2. **Module list.** Filter `hack/modules-arm64.txt` to what the rpi kernel actually built. The stock list references
   drivers our config doesn't include (e.g. `bnxt_re`), and `nvme` is now built-in rather than a module. The script
   regenerates the list by intersecting against the real kernel module tree.
3. **Overlay port.** The overlay (copies u-boot/config.txt/dtb to disk) was written against older machinery; Talos
   1.13's overlay API added a `ctx` argument. The script bumps machinery to match and patches `main.go` in the overlay.
4. **grub profile.** Build with the overlay's `rpi5` grub profile, not `metal`. Talos 1.13's `metal` default is
   sd-boot, and sd-boot's image path silently skips the overlay installer entirely. So a Pi 5 image built as `metal`
   has the kernel but no u-boot/config.txt/dtb and simply won't boot. The grub profile runs the overlay install
   properly and the EFI partition ends up with the boot bits it needs.

```bash
03_operating_system/03_talos_image_builder.sh
```

First run takes a while. Full clang/ThinLTO kernel compile is 30-40 min on 12 cores (macBook Pro, M2 Pro). Later runs
cache the kernel layer.

## What's baked into the image (and why it has to be)

- **4K kernel pages** (`CONFIG_ARM64_4K_PAGES=y`, not the Pi defconfig's 16K). The 16K risk lands squarely in
  mount/filesystem handling, which is exactly what steps 04 and 05 (Longhorn) touch. Etcd and Kubernetes are fine on
  16K, but **XFS only mounts when its block size <= the kernel page size**, so a 16K-block XFS volume won't mount on a
  4K
  kernel. Some other software has 16K compatibility issues too. 4K is also what stock Talos `metal-arm64` uses. Keep
  page size the same on all three nodes.
- **System extensions** (baked at the installer step): `iscsi-tools` (iscsid, required by Longhorn) and
  `util-linux-tools` (fstrim).
- **Radios off:** `dtoverlay=disable-wifi` + `dtoverlay=disable-bt` in the overlay's `config.txt`, plus the `.dtbo`
  files.
- **Built-in (`=y`) drivers** needed for step 05 and Longhorn: Pi 5 watchdog (`BCM2835_WDT`), NVMe + PCIe
  (`PCIE_BRCMSTB`), the Pi 5 NIC (`MACB` + PHYLINK/PHYLIB/BROADCOM_PHY), RP1 bring-up (`MFD_RP1`, `BCM2712_MIP`, ...).
- **Not baked in** (tuned in step 05): NIC mitigation. TSO/GSO off, ring sizes, EEE disable, watchdog enable, the
  link-watchdog DaemonSet, kubelet socket cleanup. The image just ships the kernel version that makes EEE controllable.

## Registry & upgrades

The build pushes to a **local registry (`localhost:5010`)** — enough for building and validating.

The NVMe gets flashed exactly once (initial install); after that, Talos upgrades are atomic A/B over the network with no
reflash. Bumping Talos = re-run the builder with updated version knobs in `03_config.sh`. If a rebase fails, the script
will tell you. The kernel layer caches, so a userspace-only Talos bump skips the long compile. A network upgrade does
need the installer image somewhere the nodes can pull from (e.g. a registry they can reach) — not set up here.

## Validation (offline, no hardware)

Runs at the end of the builder. macOS can't loop-mount Linux filesystems, so this runs inside a privileged Linux
container. Exits non-zero on any failure.

- **Integrity + size:** `xz -t` passes; compressed image size is in a reasonable range.
- **Partition layout:** loop-mount the raw image; confirm `EFI` + `BOOT` + `META` (grub layout). `STATE` and
  `EPHEMERAL` don't exist yet, they're created on first boot.
- **Pi 5 boot bits in the EFI partition:** `config.txt` (with the disable-wifi/bt lines), `u-boot.bin`,
  `bcm2712-rpi-5-b.dtb`, `overlays/disable-{wifi,bt}.dtbo`.
- **Kernel version:** pulled from the installer UKI's `.uname` section. Asserts 6.18.x, which proves the kernel
  actually got swapped out.
- **Extensions baked:** decompress the UKI's `.initrd` and confirm `iscsi-tools` and `util-linux-tools` are in there.

> No QEMU/VM boot. The Pi 5 (BCM2712 + RP1) isn't emulated by QEMU, so a VM boot would fail for unrelated reasons and
> tell you nothing useful about image correctness. Real boot validation means flashing to a Pi.

## Flash the NVMe

Script: **`03_talos_image_flasher.sh`** (macOS). `dd`s the local built image (`.raw.xz`) to an NVMe over a USB
adapter. Has the usual safeguards: lists disks, requires typing `YES`, writes to `/dev/rdiskN`, ejects. Needs `xz`
(`brew install xz`).

### Per drive

Run the script, pick the USB-NVMe adapter's disk id, confirm. Repeat for each SSD, just swap drives in the adapter.

Then slot the SSD into a Pi, power on with no SD card -> EEPROM (step 02) falls through to NVMe -> Talos boots into
maintenance mode (no role assigned yet).

## Boot & verify (per node)

Script: **`03_talos_boot_verify.sh`** — prompts for the node IP(s) and runs the checklist below against each
(maintenance mode, `--insecure`), **inspecting** each output and printing PASS/FAIL + a summary. It uses the talosctl
container by default (sidesteps the macOS gotcha below); `ping`/`nc` run natively.

```bash
./03_talos_boot_verify.sh        # then enter the node IPs when prompted
```

What it checks per node:

```bash
ping <node-ip>                                       # on the network
nc -vz <node-ip> 50000                               # Talos API reachable
talosctl -n <node-ip> version --insecure             # responds; server = our v1.13.4(-dirty) build
talosctl -n <node-ip> get links --insecure           # end0 (the wired NIC) present/up
talosctl -n <node-ip> get disks --insecure           # /dev/nvme0n1 present
talosctl -n <node-ip> get kernelcmdlines --insecure  # cmdline has console=ttyAMA0,115200 (rpi5 overlay)
```

> Maintenance mode can't report the kernel *version* string — `dmesg` has no `--insecure` flag and needs certs. The
> `6.18.34` kernel is already proven by the builder's offline validation; re-confirm it **after** the cluster is up
> (step 04, certs present): `talosctl -n <ip> dmesg | grep 'Linux version'`.

All green → proceed to `04_talos_setup.md` to bring up the cluster.

### macOS `talosctl` gotcha

If `nc` succeeds but `talosctl ... --insecure` comes back with `no route to host`, the node is fine. The macOS
`talosctl` binary is just misbehaving (confirmed by the official container reaching the same node without issues). Use
the container:

```bash
talosctl() { docker run --rm --network host -v "$HOME/.talos:/root/.talos" ghcr.io/siderolabs/talosctl:v1.13.4 "$@"; }
```

Drop that in `~/.zshrc`, reload, and `talosctl` works normally from there.

## Troubleshooting

**Build:**

- `missing separator` in a Makefile -> you're on make 3.81; use `gmake` (the script already does this).
- `mergeop has been disabled` -> Rancher's default builder can't run siderolabs `bldr`; the script creates a
  `docker-container` buildx builder that can.
- `no space left on device` during kernel finalize -> Docker VM disk is too small; bump it in Rancher Desktop ->
  Virtual Machine, or via a Lima `disk:` override + recreate.
- `BAKE-IN MISSING: <SYM>` -> a kernel config symbol didn't reconcile (unmet dependency); adjust the config fragment.
- `cannot stat .../<mod>.ko` at initramfs -> module list drifted; the script's filter handles this, just re-run.
- `digest mismatch` on the kernel source -> GitHub `/archive/` tarballs aren't byte-stable across requests. The builder
  hashes one download and serves it from a local HTTP server for the rest of the build. Nothing to do.

**Boot:**

- **Node never appears on the network** -> kernel is missing RP1 NIC support, or the overlay/u-boot didn't land on the
  EFI partition (offline validation catches the latter). Attach HDMI or a USB-UART serial console (115200 baud,
  `ttyAMA10`) to see what's happening.
- **Won't boot at all** -> EEPROM boot order / `PCIE_PROBE` (step 02).
- **NVMe not detected** -> PCIe probe / `dtparam`; confirm Gen 2 link with step 02's checks.

## Reference

- talos-builder: <https://github.com/talos-rpi5/talos-builder>
- raspberrypi/linux: <https://github.com/raspberrypi/linux>
- Talos releases: <https://github.com/siderolabs/talos/releases>
- extensions: <https://github.com/siderolabs/extensions>
- Boot assets / imager: <https://www.talos.dev/latest/talos-guides/install/boot-assets/>
- Upgrades: <https://www.talos.dev/latest/talos-guides/upgrading-talos/>
- Pi 5 macb wedge (why the NIC fix lives in step 05 config, not the
  image): <https://github.com/siderolabs/sbc-raspberrypi/issues/91>
- Worked examples: <https://kcirtap.io/posts/talos-rpi5-custom-kernel-build/>
  and <https://rcwz.pl/2025-10-04-installing-talos-on-raspberry-pi-5/>
