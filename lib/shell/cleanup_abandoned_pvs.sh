#!/usr/bin/env bash
# Lists PVs nothing will bind again and deletes the ones you pick, WITH the storage behind them.
#
# Deleting the PV alone is the trap this exists for. On a Retain class the PV going away leaves the Longhorn
# volume holding every byte, still attached to the recurring backup jobs it can no longer satisfy, so the only
# thing that tells you is longhorn-backup-stale firing days later on a volume whose PVC no longer exists.
# So: PV and Longhorn volume together. The S3 backup is deliberately left alone and never even asked about,
# because it is the last copy of the data. backupvolume-orphaned alerts on it 30 days later instead.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<EOF
cleanup_abandoned_pvs.sh          (or: make cleanup-abandoned-pvs)

Lists every abandoned PV, then asks which to delete. Abandoned is one of:
  Released    its PVC is gone and the class reclaims Retain, so the PV and its data stayed
  Available   no claimRef at all, i.e. nothing ever claimed it

An Available PV that HAS a claimRef is a static PV waiting for its own PVC, which lib/helm/nfs-volume
creates on purpose. Those are never listed.

Deletes the PV and the Longhorn volume behind it. Never touches the S3 backup: that is the last copy, and
backupvolume-orphaned alerts on it 30 days on if you meant to be rid of it.

Pick with numbers ("1", "1 3", "1,3", or "all"). Empty input aborts and changes nothing.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) usage; die "unknown argument: $1" ;;
esac

require kubectl
use_kubeconfig
assert_api

# name, phase, size, reclaim, claim. Fields are |-separated, NOT tab: tab is IFS whitespace, so bash collapses
# a run of them and one empty field (an unset storageClassName) shifts every later column left by one.
# A PV with no claimRef renders the claim as a bare "/", which is what marks it never-claimed below.
mapfile -t ROWS < <(
  kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{.spec.capacity.storage}{"|"}{.spec.persistentVolumeReclaimPolicy}{"|"}{.spec.claimRef.namespace}{"/"}{.spec.claimRef.name}{"\n"}{end}' \
  | awk -F'[|]' '$2=="Released" || ($2=="Available" && $5=="/")'
)

[ "${#ROWS[@]}" -gt 0 ] || { say "No abandoned PVs. Nothing to do."; exit 0; }

# Longhorn volume names match the PV name for anything its CSI driver provisioned. A PV from another driver
# has none, and only the PV is deleted for it.
has_volume() { kubectl -n longhorn-system get volumes.longhorn.io "$1" >/dev/null 2>&1; }
backupvolumes_for() {
  kubectl -n longhorn-system get backupvolumes.longhorn.io \
    -o jsonpath="{range .items[?(@.spec.volumeName=='$1')]}{.metadata.name}{'\n'}{end}" 2>/dev/null
}

say "Abandoned PVs (${#ROWS[@]})"
printf '      %-42s %-9s %-6s %-8s %-30s %s\n' PV PHASE SIZE RECLAIM CLAIM 'ALSO ON DISK'
for i in "${!ROWS[@]}"; do
  IFS='|' read -r name phase size reclaim claim <<<"${ROWS[$i]}"
  extra=""
  has_volume "$name" && extra="longhorn volume"
  bv="$(backupvolumes_for "$name" | tr '\n' ' ')"
  [ -n "${bv// }" ] && extra="${extra:+$extra + }S3 backup"
  printf '  %2d) %-42s %-9s %-6s %-8s %-30s %s\n' "$((i+1))" "$name" "$phase" "$size" "$reclaim" \
    "$([ "$claim" = "/" ] && echo '(never claimed)' || echo "$claim")" "${extra:-PV only}"
done

echo
read -r -p ">> numbers to delete (e.g. 1 3, or all, empty aborts): " PICK
[ -n "${PICK// }" ] || { say "Nothing selected. No changes."; exit 0; }

SELECTED=()
if [ "$PICK" = "all" ]; then
  SELECTED=("${ROWS[@]}")
else
  for n in ${PICK//,/ }; do
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#ROWS[@]}" ] || die "not a listed number: ${n}"
    SELECTED+=("${ROWS[$((n-1))]}")
  done
fi

say "About to delete ${#SELECTED[@]} PV(s) and the Longhorn volume behind each. The data goes with them. S3 backups are kept."
for row in "${SELECTED[@]}"; do printf '  - %s\n' "${row%%|*}"; done
confirm_word DELETE "this destroys the volume data;" || die "aborted, nothing deleted"

FAILED=""
for row in "${SELECTED[@]}"; do
  IFS='|' read -r name _ _ _ _ <<<"$row"
  say "$name"
  kubectl delete pv "$name" --wait=false >/dev/null 2>&1 && echo "  pv deleted" || { warn "pv delete failed"; FAILED="${FAILED} ${name}"; }
  if has_volume "$name"; then
    kubectl -n longhorn-system delete volumes.longhorn.io "$name" --wait=false >/dev/null 2>&1 \
      && echo "  longhorn volume deleted" || { warn "longhorn volume delete failed"; FAILED="${FAILED} ${name}(volume)"; }
  fi
  # The S3 backup is never touched here, not even offered: it is the only remaining copy once the volume
  # above is gone. backupvolume-orphaned fires 30 days from now if it is still around.
  bv="$(backupvolumes_for "$name" | tr '\n' ' ')"
  [ -n "${bv// }" ] && echo "  S3 backup kept: ${bv% }"
done

[ -z "$FAILED" ] || die "some deletes failed:${FAILED}"
say "Done. The pv-abandoned alert clears on the exporter's next scan."
