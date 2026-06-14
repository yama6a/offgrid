# Talos — OS choice & NVMe image

OS for the 3-node Pi 5 cluster: **Talos Linux** — immutable, API-managed, Kubernetes-only. The whole node is one
declarative config: no SSH, no package manager, no drift. This doc covers *why Talos*, what we rejected, and how to
build/flash the NVMe image. (Cluster config — IPs, VIP, partitions — lives in step 04.)

## Why Talos

- **Whole node = one declarative config.** Managed over an API with `talosctl`. Fits everything-as-code.
- **Identical nodes.** Same image on every board; per-node identity is just config (step 04).
- **Atomic A/B upgrades + rollback** (`talosctl upgrade`), no in-place mutation.
- **Minimal attack surface** — no shell, no SSH, ~12 host binaries; WiFi/Bluetooth/cron daemons aren't even present.
- **Kubernetes built in.** PCIe enable, cgroups, and link speed are baked into the image — no `config.txt` step (unlike
  Raspberry Pi OS).

## Trade-offs (what we accept)

- **Pi 5 is community-tested, not official.** We use the [`talos-rpi5`](https://github.com/talos-rpi5/talos-builder)
  build (it carries the custom RP1 kernel the Pi 5 needs). Upgrades = repin/rebuild that image.
- **API-only.** No shell — a hung node is recovered by reboot, not by logging in.
- **Pi 5 NIC bug** (silent `macb` link wedge) needs mitigation — handled in step 05.

## OSes considered

| OS / distro                                | Verdict                                                                                                   |
|--------------------------------------------|-----------------------------------------------------------------------------------------------------------|
| **Talos Linux**                            | **Chosen** — immutable, declarative, identical nodes, K8s built in.                                       |
| k3s on Ubuntu Server                       | Runner-up. 4K pages + cgroups out of the box, biggest community. But mutable, more moving parts.          |
| k3s / kubeadm on Raspberry Pi OS           | Two Pi-5 traps: manual cgroup `cmdline.txt` edit + 16K-page kernel (must switch to 4K). No gain headless. |
| k0s on Ubuntu                              | Lightest footprint, clean `k0sctl` spec. Smaller ecosystem; no edge over Talos for us.                    |
| NixOS + k3s                                | Also fully declarative; closest rival. Steep Nix curve, smaller Pi-5 community.                           |
| Flatcar / Fedora CoreOS / openSUSE MicroOS | Immutable too, but weaker/younger Pi-5 support; Talos wins on declarativeness.                            |
| Harvester                                  | Dismissed — full HCI/KubeVirt platform, needs x86_64 + large RAM.                                         |

## Choosing the image version

`talos-rpi5` releases are tagged by the **Talos version** they're built from (e.g. `v1.11.5` → Talos 1.11.5). Each
release ships two assets: a **raw disk image** for the first flash, and an **installer image**
(`ghcr.io/talos-rpi5/installer:<ver>`) for later `talosctl upgrade`.

Find the latest working one:

```
# latest stable tag
curl -s https://api.github.com/repos/talos-rpi5/talos-builder/releases/latest | jq .tag_name -r
# its downloadable assets — note the EXACT .raw.zst filename
curl -s https://api.github.com/repos/talos-rpi5/talos-builder/releases/latest | jq .assets[0].browser_download_url -r | awk -F/ '{print $NF}'
```

Rules of thumb:

- Take the **latest release** matching the Talos version you want; prefer a clean tag over a `-pre` / `-rc` if both
  exist.
- **Verify the asset filename** — it has changed across releases (`metal-arm64.raw.zst` or `metal-arm64-rpi.raw.zst`).
  The script's `IMAGE_ASSET` must match what the release actually publishes.
- Keep your `talosctl` within one minor of the image's Talos version.

> Pinned in `03_talos_image_flasher.sh`: **`v1.11.5`**, asset `metal-arm64.raw.zst`.

## Build & flash the NVMe

Script: `03_talos_image_flasher.sh` (macOS). What it does:

1. Downloads the pinned `talos-rpi5` raw image (`.raw.zst`) — cached, so it downloads once.
2. Decompresses it.
3. Writes it to the NVMe over the USB adapter (`dd` to `/dev/rdiskN`), with disk selection + a `YES` confirm before
   erasing.

Requires `curl` + `zstd` (`brew install zstd`).

## Per drive

- Run the script, pick the USB-NVMe adapter's disk id, confirm. Repeat for each SSD (swap the drive in the adapter).
- Slot the SSD into a Pi, power on **with no SD card** → EEPROM falls through to NVMe → Talos boots into **maintenance
  mode** (configured but no role yet).

## Verify

- Confirm that the device shows up in the network, e.g. `ping <node-ip>`
- Confirm the Talos API is reachable: `nc -vz <node-ip> 50000`
- Disk seen: `talosctl -n <node-ip> get disks --insecure` → confirm `/dev/nvme0n1`.

### macOS `talosctl` gotcha

If `nc` succeeds but: `talosctl -n <node-ip> get disks --insecure` returns:

```text
error getting version: rpc error: code = Unavailable desc = connection error: desc = "transport: Error while dialing: dial tcp <node-ip>:50000: connect: no route to host"
```

then the node is probably fine and the macOS `talosctl` client is misbehaving. This was verified by running the official
Linux container, which successfully connected to the node. The Talos API is available in maintenance mode, but only a
subset of commands are implemented.

Use the official container instead:

```bash
docker run --rm -it \
  --network host \
  ghcr.io/siderolabs/talosctl:v1.13.4 \
  "$@"
```

Convenient shell wrapper:

```bash
talosctl() {
  docker run --rm \
    --network host \
    -v "$HOME/.talos:/root/.talos" \
    ghcr.io/siderolabs/talosctl:v1.13.4 \
    "$@"
}
```

Add the function to `~/.bashrc` or `~/.zshrc`, reload the shell, and use `talosctl` normally.
