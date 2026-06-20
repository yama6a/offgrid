#!/usr/bin/env bash

set -euo pipefail

cd ./03_operating_system
OUTDIR="$PWD/talos-cluster"

talosctl() { docker run --rm --network host -v "$OUTDIR:/work" -w /work \
  -e TALOSCONFIG=/work/talosconfig "ghcr.io/siderolabs/talosctl:v1.13.4" "$@"; }

read -r -p ">> Destroy ENTIRE Talos Cluster? type YES: " ok
[ "${ok}" = "YES" ] || { echo "skipped destruction (phew!)."; exit 0; }

for ip in 192.168.10.201 192.168.10.202 192.168.10.203; do
  echo ">> resetting $ip -> maintenance"
  talosctl reset -e "$ip" -n "$ip" \
    --system-labels-to-wipe STATE,EPHEMERAL \
    --reboot --graceful=false
done
