#!/usr/bin/env bash
#
# 03a_talos_image_builder.sh  (macOS, Apple Silicon)
#
# Builds a CUSTOM Talos Linux image for the Raspberry Pi 5 at the latest Talos
# on a recent Raspberry Pi kernel, bakes in the items cluster bring-up (03d) and
# hardening (step 04) need, and ends with an OFFLINE validation stage. A clean
# run = a built AND validated image.
#
# It drives talos-rpi5/talos-builder (which stitches siderolabs/pkgs +
# siderolabs/talos + the talos-rpi5 overlay), but rebases four things the
# upstream build can't do at this Talos version — see the REBASES below.
#
# Prereqs (the script checks them):
#   - gmake (GNU make >= 4)        brew install make      (system make is 3.81)
#   - zstd, xz, jq, curl           brew install zstd xz jq
#   - docker (Rancher Desktop ok) with an arm64 Linux VM, >= ~120 GB free disk
#
# Nothing here touches hardware. Flashing is next (03b_talos_image_flasher.sh).
#
set -euo pipefail

# All config (versions, kernel ref, extensions, registry, paths) lives in 03_config.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/03_config.sh"

BUILDER_REPO="https://github.com/talos-rpi5/talos-builder.git"
WORK="${BUILD_DIR}/talos-builder"
CHK="${WORK}/checkouts"
say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# === 0. prereqs ==============================================================
say "checking prerequisites"
[ "$(uname -m)" = "arm64" ] || echo "WARN: not arm64 — the kernel build will be emulated and very slow"
[ -x "$GMAKE" ] || die "GNU make >= 4 not found at $GMAKE (brew install make)"
"$GMAKE" --version | head -1 | grep -qE 'GNU Make (4|5|6)' || die "need GNU make >= 4"
for t in docker zstd xz jq curl go; do command -v "$t" >/dev/null || die "$t not found"; done
docker info >/dev/null 2>&1 || die "docker not responding (start Rancher/Docker Desktop)"
export PATH="/opt/homebrew/opt/make/libexec/gnubin:${PATH}"   # so make / $(MAKE) == gmake 4.x
mkdir -p "$BUILD_DIR" "$OUT_DIR"

# === 1. local registry + mergeop-capable builder =============================
# siderolabs `bldr` uses BuildKit mergeop, which the dockerd-embedded builder
# (Rancher's default) refuses. A standalone docker-container builder supports it.
say "local registry on ${REGISTRY_HOST}"
docker ps --format '{{.Names}}' | grep -qx "$REGISTRY_NAME" || \
  docker run -d --restart=unless-stopped -p "127.0.0.1:${REGISTRY_PORT}:5000" --name "$REGISTRY_NAME" registry:2 >/dev/null

say "mergeop-capable buildx builder ${BUILDER_NAME}"
if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
  cfg="$(mktemp)"; printf '[registry."%s"]\n  http = true\n  insecure = true\n' "$REGISTRY_HOST" > "$cfg"
  docker buildx create --name "$BUILDER_NAME" --driver docker-container \
    --driver-opt network=host --buildkitd-config "$cfg" >/dev/null
fi
docker buildx use "$BUILDER_NAME"
docker buildx inspect --bootstrap "$BUILDER_NAME" >/dev/null

# === 2. clone builder + checkouts ============================================
say "clone talos-builder ${BUILDER_VERSION} + checkouts (pkgs ${PKG_VERSION}, talos ${TALOS_VERSION}, overlay ${SBCOVERLAY_VERSION})"
# Pin the builder scaffold to BUILDER_VERSION, enforcing the pin even on a cached
# checkout from a previous run/ref (the clone is the only network-heavy step here).
if [ -d "$WORK/.git" ]; then
  ( cd "$WORK" && git fetch -q --depth 1 origin "refs/tags/${BUILDER_VERSION}" && git checkout -q -f FETCH_HEAD )
else
  git clone -q --depth 1 --branch "$BUILDER_VERSION" "$BUILDER_REPO" "$WORK"
fi
perl -i -pe "s/^PKG_VERSION = .*/PKG_VERSION = ${PKG_VERSION}/" "$WORK/Makefile"
perl -i -pe "s/^TALOS_VERSION = .*/TALOS_VERSION = ${TALOS_VERSION}/" "$WORK/Makefile"
rm -rf "$CHK/pkgs" "$CHK/talos" "$CHK/sbc-raspberrypi5"
# NB: the Makefile uses $(PWD)/checkouts, so make must run with cwd=$WORK (not `make -C`).
( cd "$WORK" && "$GMAKE" checkouts )
# The Makefile clones the overlay with `git clone --branch`, which only takes a branch
# or tag — not a SHA. So it clones main (a full clone), and we pin to SBCOVERLAY_VERSION
# here (a commit reachable in main's history). pkgs/talos pin via --branch (they're tags).
git -C "$CHK/sbc-raspberrypi5" checkout -q "$SBCOVERLAY_VERSION" || die "could not pin overlay to ${SBCOVERLAY_VERSION}"

# === 3. REBASE 1 — kernel: raspberrypi/linux source + Pi5 config fragment ====
# pkgs ships a stock 6.18 arm64 config (already 4K). We point the kernel source
# at raspberrypi/linux (for the RP1/BCM2712 drivers that are fork-only) and add a
# small fragment, reconciled with olddefconfig under the real clang toolchain.
say "REBASE 1 — kernel source -> raspberrypi/linux ${KERNEL_REF} (served locally), + Pi5 config fragment"
# GitHub's /archive/ tarballs are NOT byte-stable (different CDN nodes serve different
# gzip), so the sha bldr downloads can differ from one we hash on the host. Download
# once and serve it from a local HTTP server so bldr fetches the exact bytes we hashed.
SRCDIR="${BUILD_DIR}/srcserve"; mkdir -p "$SRCDIR"
curl -fL --retry 3 -o "$SRCDIR/linux.tar.gz" \
  "https://github.com/raspberrypi/linux/archive/refs/tags/${KERNEL_REF}.tar.gz"
KSHA256=$(shasum -a 256 "$SRCDIR/linux.tar.gz" | awk '{print $1}')
KSHA512=$(shasum -a 512 "$SRCDIR/linux.tar.gz" | awk '{print $1}')
docker rm -f "$SRCSERVER_NAME" >/dev/null 2>&1 || true
trap 'docker rm -f "$SRCSERVER_NAME" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$SRCSERVER_NAME" -p "127.0.0.1:${SRCSERVER_PORT}:80" \
  -v "$SRCDIR:/usr/share/nginx/html:ro" nginx:alpine >/dev/null

# Pkgfile: pin kernel version + the local file's shas.
perl -0pi -e "s/  linux_version: .*\n  linux_sha256: .*\n  linux_sha512: .*\n/  linux_version: ${KERNEL_REF}\n  linux_sha256: ${KSHA256}\n  linux_sha512: ${KSHA512}\n/" "$CHK/pkgs/Pkgfile"
# kernel source fetch: the locally-served tarball (deterministic), extracted as .tar.gz.
# Pattern uses .* (not \S+) — the stock cdn URL has spaces inside a {{ }} template.
perl -0pi -e 's{- url: https://cdn\.kernel\.org/.*\.tar\.xz\n\s+destination: linux\.tar\.xz}{- url: "http://localhost:'"${SRCSERVER_PORT}"'/linux.tar.gz"\n        destination: linux.tar.gz}' "$CHK/pkgs/kernel/prepare/pkg.yaml"
perl -i -pe 's/tar -xJf linux\.tar\.xz/tar -xzf linux.tar.gz/' "$CHK/pkgs/kernel/prepare/pkg.yaml"
grep -q 'localhost:'"${SRCSERVER_PORT}" "$CHK/pkgs/kernel/prepare/pkg.yaml" || die "kernel source URL rewrite failed"

# Pi5/RP1 fragment (symbol names from the rpi tree's arch/arm64/configs/bcm2712_defconfig).
cat > "$CHK/pkgs/kernel/build/pi5-rpi.fragment" <<'FRAG'
# Raspberry Pi 5 (BCM2712 + RP1) over the stock Talos arm64 config, reconciled
# with `make olddefconfig` against the raspberrypi/linux source.
# 4K pages (NOT the Pi defconfig's 16K) — Longhorn/XFS compat (see 03_operating_system.md).
CONFIG_ARM64_4K_PAGES=y
# CONFIG_ARM64_16K_PAGES is not set
# RP1 south-bridge bring-up (NIC end0/macb, USB, GPIO live behind it) — fork-only
CONFIG_MFD_RP1=y
CONFIG_MBOX_RP1=y
CONFIG_FIRMWARE_RP1=y
CONFIG_PINCTRL_RP1=y
CONFIG_COMMON_CLK_RP1=y
CONFIG_COMMON_CLK_RP1_SDIO=y
# BCM2712 SoC: pinctrl, PCIe MSI-X peripheral (NVMe/RP1 IRQs), IOMMU
CONFIG_PINCTRL_BCM2712=y
CONFIG_BCM2712_MIP=y
CONFIG_BCM2712_IOMMU=y
# Boot path + Pi 5 hardware watchdog (step 04 WatchdogTimerConfig binds here)
CONFIG_PCIE_BRCMSTB=y
CONFIG_BLK_DEV_NVME=y
CONFIG_MACB=y
CONFIG_WATCHDOG=y
CONFIG_BCM2835_WDT=y
FRAG

# Patch the kernel build to merge the fragment + olddefconfig + fail-fast verify,
# inserted right after the stock `cp -v /pkg/config-${CARCH} .config`.
python3 - "$CHK/pkgs/kernel/build/pkg.yaml" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
anchor="        cp -v /pkg/config-${CARCH} .config\n        cp -v /pkg/certs/* certs/\n"
block=anchor+'''        if [ "${CARCH}" = "arm64" ] && [ -f /pkg/pi5-rpi.fragment ]; then
          cat /pkg/pi5-rpi.fragment >> .config
          make ARCH="${ARCH}" LLVM=1 olddefconfig
          for s in \\
            CONFIG_ARM64_4K_PAGES=y CONFIG_BLK_DEV_NVME=y CONFIG_MACB=y \\
            CONFIG_BCM2835_WDT=y CONFIG_MFD_RP1=y CONFIG_FIRMWARE_RP1=y \\
            CONFIG_PINCTRL_RP1=y CONFIG_PINCTRL_BCM2712=y CONFIG_BCM2712_MIP=y \\
            CONFIG_PCIE_BRCMSTB=y CONFIG_COMMON_CLK_RP1=y ; do
            grep -qx "$s" .config || { echo "BAKE-IN MISSING: $s"; exit 1; }
          done
          grep -qx '# CONFIG_ARM64_16K_PAGES is not set' .config || { echo "ERROR: 16K pages set"; exit 1; }
          echo ">> Pi 5 kernel config reconciled and bake-ins verified"
        fi
'''
assert anchor in s, "kernel/build/pkg.yaml anchor not found (upstream changed?)"
open(p,"w").write(s.replace(anchor, block, 1))
PY

# === 4. build kernel =========================================================
say "build kernel (clang/ThinLTO — the long pole; verifies bake-ins early then compiles)"
( cd "$WORK" && "$GMAKE" REGISTRY="$REGISTRY_HOST" REGISTRY_USERNAME="$REGISTRY_USER" kernel )

# === 5. REBASE 2 — filter modules-arm64.txt to what the rpi kernel built ======
say "REBASE 2 — filter modules-arm64.txt to modules the kernel actually built"
PKGS_TAG=$(cd "$CHK/pkgs" && git describe --tag --always --dirty --match 'v[0-9]*')
KIMG="${REGISTRY_HOST}/${REGISTRY_USER}/kernel:${PKGS_TAG}"
docker pull -q "$KIMG" >/dev/null
cid=$(docker create "$KIMG" sh); docker export "$cid" 2>/dev/null | tar t 2>/dev/null > "$BUILD_DIR/kfiles.txt"; docker rm "$cid" >/dev/null
KVER=$(grep -oE 'usr/lib/modules/[^/]+' "$BUILD_DIR/kfiles.txt" | head -1 | cut -d/ -f4)
grep "usr/lib/modules/${KVER}/" "$BUILD_DIR/kfiles.txt" | sed "s#usr/lib/modules/${KVER}/##" | grep -vE '/$' | sort -u > "$BUILD_DIR/kexist.txt"
MF="$CHK/talos/hack/modules-arm64.txt"
grep -Fxf "$BUILD_DIR/kexist.txt" "$MF" > "$MF.new" && mv "$MF.new" "$MF"
echo "   modules list pinned to kernel ${KVER}"

# === 6. REBASE 3 — port the overlay to the current machinery =================
# The overlay API gained a ctx arg; the upstream overlay targets old machinery.
say "REBASE 3 — port sbc-raspberrypi5 overlay to machinery ${MACHINERY_VERSION}"
OSRC="$CHK/sbc-raspberrypi5/installers/rpi5/src"
( cd "$OSRC" && GOWORK=off GOFLAGS=-mod=mod go get "github.com/siderolabs/talos/pkg/machinery@${MACHINERY_VERSION}" && GOWORK=off go mod tidy )
perl -i -pe 's/adapter\.Execute\(&RpiInstaller\{\}\)/adapter.Execute(context.Background(), &RpiInstaller{})/' "$OSRC/main.go"
perl -i -pe 's/func \(i \*RpiInstaller\) GetOptions\(extra/func (i *RpiInstaller) GetOptions(_ context.Context, extra/' "$OSRC/main.go"
perl -i -pe 's/func \(i \*RpiInstaller\) Install\(options/func (i *RpiInstaller) Install(_ context.Context, options/' "$OSRC/main.go"
grep -q '"context"' "$OSRC/main.go" || perl -0pi -e 's/(import \(\n)/$1\t"context"\n/' "$OSRC/main.go"
( cd "$OSRC" && GOWORK=off CGO_ENABLED=0 go build -o /dev/null . ) || die "overlay does not compile against ${MACHINERY_VERSION}"

# === 7. REBASE 4 — extensions + grub profile + network in the Makefile ========
# Bake both extensions (one --system-extension-image flag each) and image with the
# overlay's `rpi5` (grub) profile, NOT `metal` (1.13's sd-boot default silently
# skips the overlay installer, so a Pi-5 image built as `metal` has no boot bits).
say "REBASE 4 — wire extensions + grub (rpi5) profile + --network host"
python3 - "$WORK/Makefile" "$ISCSI_EXT" "$UTIL_EXT" <<'PY'
import re,sys
p,iscsi,util=sys.argv[1],sys.argv[2],sys.argv[3]
s=open(p).read()
s=re.sub(r'^EXTENSIONS \?=.*$',
         f'EXTENSIONS ?= {iscsi} {util}\nEXTENSION_FLAGS = $(foreach e,$(EXTENSIONS),--system-extension-image=$(e))',
         s, count=1, flags=re.M)
s=s.replace('--system-extension-image="$(EXTENSIONS)"', '$(EXTENSION_FLAGS)')  # quoted (imager run)
s=s.replace('--system-extension-image=$(EXTENSIONS)', '$(EXTENSION_FLAGS)')      # unquoted (IMAGER_ARGS)
s=s.replace('run --rm -t -v ./_out:/out', 'run --rm -t --network host -v ./_out:/out')
s=re.sub(r'(\$\(REGISTRY_USERNAME\)/imager:\$\(TALOS_TAG\) \\\n\t+)metal --arch', r'\1rpi5 --arch', s)
open(p,'w').write(s)
PY

# === 8. build overlay + installer + raw image ================================
say "build overlay"
( cd "$WORK" && "$GMAKE" REGISTRY="$REGISTRY_HOST" REGISTRY_USERNAME="$REGISTRY_USER" overlay )
say "build installer + imager -> raw disk image (grub/rpi5 profile)"
( cd "$WORK" && "$GMAKE" REGISTRY="$REGISTRY_HOST" REGISTRY_USERNAME="$REGISTRY_USER" installer )

# The imager's own output name (NOT the staged IMAGE_NAME the flasher reads).
IMAGER_RAW_XZ="$CHK/talos/_out/metal-arm64.raw.xz"
[ -f "$IMAGER_RAW_XZ" ] || die "imager did not produce $IMAGER_RAW_XZ"
STAGED="$OUT_DIR/$IMAGE_NAME"
cp "$IMAGER_RAW_XZ" "$STAGED"
TALOS_TAG=$(cd "$CHK/talos" && git describe --tag --always --dirty --match 'v[0-9]*')

# === 9. OFFLINE VALIDATION (the "done" test) =================================
say "OFFLINE VALIDATION"
INSTALLER_IMG="${REGISTRY_HOST}/${REGISTRY_USER}/installer:${TALOS_TAG}-arm64"
docker pull -q "$INSTALLER_IMG" >/dev/null
UKI_DIR="$BUILD_DIR/uki"; rm -rf "$UKI_DIR"; mkdir -p "$UKI_DIR"
cid=$(docker create "$INSTALLER_IMG" sh); docker cp "$cid:/usr/install/arm64/vmlinuz.efi" "$UKI_DIR/vmlinuz.efi" >/dev/null 2>&1; docker rm "$cid" >/dev/null
chmod 644 "$UKI_DIR/vmlinuz.efi"

# 9a. raw image: integrity + partition layout + Pi 5 boot bits  (privileged Linux container)
docker run --rm --privileged -e IMAGE_NAME="$IMAGE_NAME" -v "$OUT_DIR:/work" -v /dev:/dev alpine:3.20 sh -c '
  set -e; apk add -q util-linux xz >/dev/null 2>&1; cd /work; F="$IMAGE_NAME"; RAW="${IMAGE_NAME%.xz}"
  fail=0
  xz -t "$F" && echo "PASS  integrity (xz -t)" || { echo "FAIL  integrity"; fail=1; }
  sz=$(stat -c%s "$F"); [ "$sz" -gt 50000000 ] && [ "$sz" -lt 600000000 ] && echo "PASS  size ($sz bytes)" || { echo "FAIL  size $sz"; fail=1; }
  xz -dkf "$F"; LOOP=$(losetup -fP --show "$RAW")
  for lbl in EFI BOOT META; do lsblk -no PARTLABEL "$LOOP" | grep -qx "$lbl" && echo "PASS  partition $lbl" || { echo "FAIL  partition $lbl"; fail=1; }; done
  mkdir -p /e; mount "${LOOP}p1" /e
  for f in config.txt u-boot.bin bcm2712-rpi-5-b.dtb overlays/disable-wifi.dtbo overlays/disable-bt.dtbo; do
    [ -e "/e/$f" ] && echo "PASS  boot bit $f" || { echo "FAIL  boot bit $f"; fail=1; }
  done
  grep -q "dtoverlay=disable-wifi" /e/config.txt && grep -q "dtoverlay=disable-bt" /e/config.txt \
    && echo "PASS  config.txt disables wifi+bt" || { echo "FAIL  config.txt overlays"; fail=1; }
  umount /e; losetup -d "$LOOP"; rm -f "$RAW"
  exit $fail
' || die "raw image validation failed"

# 9b. kernel version + baked extensions, from the installer UKI
docker run --rm -v "$UKI_DIR:/w" alpine:3.20 sh -c '
  apk add -q python3 xz zstd >/dev/null 2>&1
  python3 - <<PY
import struct
d=open("/w/vmlinuz.efi","rb").read(); pe=struct.unpack_from("<I",d,0x3c)[0]
nsec=struct.unpack_from("<H",d,pe+6)[0]; optsz=struct.unpack_from("<H",d,pe+20)[0]; st=pe+24+optsz
sec={}
for i in range(nsec):
    o=st+i*40; n=d[o:o+8].rstrip(b"\x00").decode("latin1"); _,_,rsz,roff=struct.unpack_from("<IIII",d,o+8); sec[n]=(roff,rsz)
for s in (".uname",".initrd"):
    o,z=sec[s]; open("/tmp/"+s,"wb").write(d[o:o+z])
PY
  uname=$(cat /tmp/.uname)
  case "$uname" in 6.18.*) echo "PASS  kernel $uname";; *) echo "FAIL  kernel $uname"; exit 1;; esac
  ext=$( (zstd -dc /tmp/.initrd 2>/dev/null; xz -dc /tmp/.initrd 2>/dev/null) | strings | grep -ioE "iscsi-tools|util-linux-tools" | sort -u )
  echo "$ext" | grep -qx iscsi-tools && echo "PASS  extension iscsi-tools" || { echo "FAIL  iscsi-tools"; exit 1; }
  echo "$ext" | grep -qx util-linux-tools && echo "PASS  extension util-linux-tools" || { echo "FAIL  util-linux-tools"; exit 1; }
' || die "installer/kernel validation failed"

# === 10. done ================================================================
say "BUILD + VALIDATION PASSED"
echo "   image:     $STAGED"
echo "   installer: ${REGISTRY_HOST}/${REGISTRY_USER}/installer:${TALOS_TAG}  (local registry)"
echo "   flash:     ./03b_talos_image_flasher.sh"
