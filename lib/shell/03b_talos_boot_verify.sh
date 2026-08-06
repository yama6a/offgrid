#!/usr/bin/env bash
# Verifies EVERY node after flashing (03a) and booting from its NVMe: reachable, Talos API answering, the right
# Talos version, and the install disk present. Nodes are still in MAINTENANCE mode, hence `--insecure`.
# The last per-node gate before cluster bring-up (03c).
#
# Two of the checks are rpi5-only, the NIC being named end0 and the overlay's kernel cmdline, and they run only
# on that hardware type. Everything else applies to any node, so nothing is exempt from being verified: on
# another type the NIC is REPORTED instead, because its name is firmware-dependent and we deliberately do not
# record one to assert against.
set -u

# The EXPECT_* checks and TALOSCTL_VERSION are in lib/shell/common.sh; the node list is inventory.yaml.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- 03b-only boot-verify expectations --------------------------------------
EXPECT_TALOS="$TALOS_VERSION"                # our build's Talos version (a local "-dirty" build matches too)
EXPECT_CMDLINE="console=ttyAMA0,115200"      # rpi5 overlay signature in the kernel cmdline

# talosctl via the official container, INSECURE + no talosconfig (maintenance mode, reliable on macOS).
# Distinct from the lib's talosctl() (which mounts the cluster talosconfig), these nodes aren't a cluster yet.
tctl() {
  docker run --rm --network host "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" "$@"
}

# prereqs
docker info >/dev/null 2>&1 || die "docker not running (needed for the talosctl container)"
say "pulling ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION} (first run only)"
docker pull -q "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" >/dev/null

for host in "${ALL_HOSTS[@]}"; do
  ip="${NODE_IP[$host]}"; type="${NODE_TYPE[$host]}"
  echo ""
  echo "=============== ${host}  ${ip}  (${type}) ==============="

  # 1. Reachable. The Talos API is the verdict; ICMP is only context, because a Pi 5 in maintenance mode drops
  #    sparse pings while TCP stays solid: EEE is still powering the PHY down between packets until 03d turns
  #    it off, and 03d runs after 03c. Measured 20-40% single-packet loss on these NICs against 0% on the x86
  #    node. So a lost ping must not skip the five real checks below, and must not fail the run.
  #    Three packets rather than one for the same reason: one is a coin toss, not a measurement.
  if ping -c3 -t10 "$ip" >/dev/null 2>&1; then icmp="ok"; else icmp="no reply"; fi
  if nc -z -G2 "$ip" "$API_PORT" >/dev/null 2>&1; then
    ok "reachable, Talos API port ${API_PORT} open (icmp: ${icmp})"
    [ "$icmp" = "ok" ] || warn "${host} did not answer ICMP; harmless here, the API is what the bring-up needs"
  else
    bad "unreachable: Talos API port ${API_PORT} closed (icmp: ${icmp}), skipping the rest for this node"
    continue
  fi

  # 3. API responds (maintenance mode) and the image is the version versions.env pins. This is the check that
  #    catches a drive flashed from a stale cached image, on any hardware type.
  out=$(tctl -n "$ip" version --insecure 2>&1); rc=$?
  if [ $rc -eq 0 ] && echo "$out" | grep -q 'Server:'; then
    sv=$(echo "$out" | awk '/Server:/{s=1} s&&/Tag:/{print $2; exit}')
    if [ "${sv%-dirty}" = "$EXPECT_TALOS" ]; then
      ok "Talos ${sv}, the version versions.env pins"
    else
      ok "Talos API responds (server ${sv:-?})"
      printf '         \033[33mnote:\033[0m server %s != expected %s\n' "${sv:-?}" "$EXPECT_TALOS"
    fi
  else
    bad "version --insecure failed: $(echo "$out" | tail -1)"
  fi

  # 4. wired NIC. Asserted by NAME only on rpi5, where end0 is fixed and the VIP binds to it. On any other type
  #    the name comes from firmware and we hold no expectation, so print what it has and let a human read it.
  out=$(tctl -n "$ip" get links --insecure 2>&1); rc=$?
  if [ $rc -ne 0 ]; then
    bad "get links --insecure failed: $(echo "$out" | tail -1)"
  elif [ "$type" = rpi5 ]; then
    if echo "$out" | grep -qE "[[:space:]]${EXPECT_NIC}([[:space:]]|\$)"; then
      state=$(echo "$out" | grep -E "[[:space:]]${EXPECT_NIC}([[:space:]]|\$)" | grep -oiwE 'up|down' | head -1)
      ok "NIC ${EXPECT_NIC} present${state:+ (${state})}"
    else
      bad "NIC ${EXPECT_NIC} not found in links"
    fi
  else
    # Printed, not parsed: the KIND column is empty for a physical NIC, so the field count differs per row and
    # picking one out by position is guesswork. A human reads the name off this and puts it in the docs.
    ok "links readable, no name asserted on ${type}. Its wired NIC is one of:"
    echo "$out" | sed 's/^/           /'
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

  # 6. rpi5 ONLY: that the overlay's kernel actually booted, not stock arm64. dmesg needs certs, so check the
  #    kernel cmdline for the overlay's signature arg instead, which is maintenance-mode safe. A factory image
  #    has no equivalent signature worth asserting, so there is nothing to check on other types.
  if [ "$type" = rpi5 ]; then
    out=$(tctl -n "$ip" get kernelcmdlines -o yaml --insecure 2>&1); rc=$?
    if [ $rc -eq 0 ] && echo "$out" | grep -qF "$EXPECT_CMDLINE"; then
      ok "Pi 5 overlay/kernel booted (cmdline has ${EXPECT_CMDLINE})"
    elif [ $rc -ne 0 ]; then
      bad "get kernelcmdlines --insecure failed: $(echo "$out" | tail -1)"
    else
      bad "rpi5 overlay arg '${EXPECT_CMDLINE}' not in kernel cmdline"
    fi
  fi
done

summary
if [ "$FAIL" -eq 0 ]; then
  echo "All nodes good. Next: cluster bring-up, ./03c_talos_cluster_config.sh"
else
  echo "Some checks failed. This script runs talosctl via the container to avoid the"
  echo "native macOS 'no route to host' gotcha."
  echo "Node never appears / NIC or NVMe missing -> see Troubleshooting in 03_operating_system.md."
fi
[ "$FAIL" -eq 0 ]
