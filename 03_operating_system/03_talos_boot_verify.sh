#!/usr/bin/env bash
#
# 03_talos_boot_verify.sh  (macOS)
#
# Run AFTER flashing (03_talos_image_flasher.sh) and booting each Pi from NVMe
# with no SD card. Checks the nodes in NODES (03_config.sh) in MAINTENANCE mode
# (pre-cluster, so `--insecure`), and inspects the output for correctness —
# printing PASS/FAIL per check and an overall summary.
#
# talosctl runs via the official container: the native macOS client can wrongly
# report "no route to host" even when the node is fine (see 03_operating_system.md).
# ping/nc run natively on the Mac.
#
# This is the step-03 check. Cluster bring-up + its own verify is step 04.
#
set -u

# All config (talosctl version, API port, NODES, the EXPECT_* checks) lives in 03_config.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/03_config.sh"

# talosctl via the official container (reliable on macOS).
tctl() {
  docker run --rm --network host "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" "$@"
}

PASS=0; FAIL=0
ok()   { printf '  \033[32m[PASS]\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# prereqs
docker info >/dev/null 2>&1 || { echo "ERROR: docker not running (needed for the talosctl container)"; exit 1; }
echo ">> pulling ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION} (first run only)"
docker pull -q "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" >/dev/null

# nodes to check (from NODES in 03_config.sh)
read -ra IPS <<< "$NODES"
[ "${#IPS[@]}" -gt 0 ] || { echo "ERROR: no nodes set — edit NODES in 03_config.sh"; exit 1; }

for ip in "${IPS[@]}"; do
  echo ""
  echo "=============== $ip ==============="

  # 1. on the network
  if ping -c1 -t10 "$ip" >/dev/null 2>&1; then
    ok "reachable (ping)"
  else
    bad "not reachable (ping) — skipping the rest for this node"
    continue
  fi

  # 2. Talos API port open
  if nc -z -G2 "$ip" "$API_PORT" >/dev/null 2>&1; then
    ok "Talos API port ${API_PORT} open"
  else
    bad "Talos API port ${API_PORT} closed"
  fi

  # 3. API responds (maintenance mode) and it's our custom build
  out=$(tctl -n "$ip" version --insecure 2>&1); rc=$?
  if [ $rc -eq 0 ] && echo "$out" | grep -q 'Server:'; then
    sv=$(echo "$out" | awk '/Server:/{s=1} s&&/Tag:/{print $2; exit}')
    if [ "${sv%-dirty}" = "$EXPECT_TALOS" ]; then
      ok "running our custom Talos build (server ${sv})"
    else
      ok "Talos API responds (server ${sv:-?})"
      printf '         \033[33mnote:\033[0m server %s != expected %s\n' "${sv:-?}" "$EXPECT_TALOS"
    fi
  else
    bad "version --insecure failed: $(echo "$out" | tail -1)"
  fi

  # 4. wired NIC present (and up)
  out=$(tctl -n "$ip" get links --insecure 2>&1); rc=$?
  if [ $rc -eq 0 ] && echo "$out" | grep -qE "[[:space:]]${EXPECT_NIC}([[:space:]]|\$)"; then
    state=$(echo "$out" | grep -E "[[:space:]]${EXPECT_NIC}([[:space:]]|\$)" | grep -oiwE 'up|down' | head -1)
    ok "NIC ${EXPECT_NIC} present${state:+ (${state})}"
  elif [ $rc -ne 0 ]; then
    bad "get links --insecure failed: $(echo "$out" | tail -1)"
  else
    bad "NIC ${EXPECT_NIC} not found in links"
  fi

  # 5. NVMe disk seen
  out=$(tctl -n "$ip" get disks --insecure 2>&1); rc=$?
  if [ $rc -eq 0 ] && echo "$out" | grep -qE "[[:space:]/]${EXPECT_DISK}([[:space:]]|\$)"; then
    ok "NVMe /dev/${EXPECT_DISK} seen"
  elif [ $rc -ne 0 ]; then
    bad "get disks --insecure failed: $(echo "$out" | tail -1)"
  else
    bad "/dev/${EXPECT_DISK} not found in disks"
  fi

  # 6. the Pi 5 overlay/kernel booted (dmesg needs certs, so check the kernel cmdline
  #    for the rpi5 overlay's signature arg instead — maintenance-mode safe)
  out=$(tctl -n "$ip" get kernelcmdlines -o yaml --insecure 2>&1); rc=$?
  if [ $rc -eq 0 ] && echo "$out" | grep -qF "$EXPECT_CMDLINE"; then
    ok "Pi 5 overlay/kernel booted (cmdline has ${EXPECT_CMDLINE})"
  elif [ $rc -ne 0 ]; then
    bad "get kernelcmdlines --insecure failed: $(echo "$out" | tail -1)"
  else
    bad "rpi5 overlay arg '${EXPECT_CMDLINE}' not in kernel cmdline"
  fi
done

echo ""
echo "=============== summary: ${PASS} passed, ${FAIL} failed ==============="
if [ "$FAIL" -eq 0 ]; then
  echo "All nodes good. Next: cluster bring-up — 04_talos_setup.md"
else
  echo "Some checks failed. This script runs talosctl via the container to avoid the"
  echo "native macOS 'no route to host' gotcha."
  echo "Node never appears / NIC or NVMe missing -> see Troubleshooting in 03_operating_system.md."
fi
[ "$FAIL" -eq 0 ]
