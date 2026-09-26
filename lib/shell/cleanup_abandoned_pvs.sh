#!/usr/bin/env bash
# Lists PVs that nothing will bind again, and deletes the ones you pick together with their Longhorn volume.
# On a Retain class, deleting only the PV leaves the Longhorn volume and its data in place.
# Its recurring backups then fail, and longhorn-backup-stale fires days later for a PVC that no longer exists.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat << EOF
cleanup_abandoned_pvs.sh          (or: make cleanup-abandoned-pvs)

Lists every abandoned PV, then asks which to delete. A PV is abandoned when it is:
  Released    its PVC is gone and the class reclaims Retain, so the PV and its data stayed
  Available   it has no claimRef, so nothing ever claimed it

An Available PV with a claimRef is a static PV that waits for its own PVC.
lib/helm/nfs-volume creates these on purpose. This script never lists them.

Deletes the PV and the Longhorn volume behind it. Never deletes the S3 backup, because it is the last copy.
backupvolume-orphaned alerts on that backup after 30 days.

Pick with numbers ("1", "1 3", "1,3", or "all"). Empty input aborts and changes nothing.
EOF
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  "") ;;
  *)
    usage
    die "unknown argument: $1"
    ;;
esac

require kubectl
use_kubeconfig
assert_api

# Fields are separated by |, not tab. Bash collapses a run of tabs, so an empty field shifts later columns left.
# A PV with no claimRef renders its claim as a bare "/", which marks it as never claimed.
mapfile -t ROWS < <(
  kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{.spec.capacity.storage}{"|"}{.spec.persistentVolumeReclaimPolicy}{"|"}{.spec.claimRef.namespace}{"/"}{.spec.claimRef.name}{"\n"}{end}' \
    | awk -F'[|]' '$2=="Released" || ($2=="Available" && $5=="/")'
)

[ "${#ROWS[@]}" -gt 0 ] || {
  say "No abandoned PVs. Nothing to do."
  exit 0
}

# The Longhorn CSI driver names each volume after its PV. A PV from another driver has no volume to delete.
has_volume() { kubectl -n longhorn-system get volumes.longhorn.io "$1" > /dev/null 2>&1; }
backupvolumes_for() {
  kubectl -n longhorn-system get backupvolumes.longhorn.io \
    -o jsonpath="{range .items[?(@.spec.volumeName=='$1')]}{.metadata.name}{'\n'}{end}" 2> /dev/null
}

say "Abandoned PVs (${#ROWS[@]})"
printf '      %-42s %-9s %-6s %-8s %-30s %s\n' PV PHASE SIZE RECLAIM CLAIM 'ALSO ON DISK'
for i in "${!ROWS[@]}"; do
  IFS='|' read -r name phase size reclaim claim <<< "${ROWS[$i]}"
  extra=""
  has_volume "$name" && extra="longhorn volume"
  bv="$(backupvolumes_for "$name" | tr '\n' ' ')"
  [ -n "${bv// /}" ] && extra="${extra:+$extra and }S3 backup"
  printf '  %2d) %-42s %-9s %-6s %-8s %-30s %s\n' "$((i + 1))" "$name" "$phase" "$size" "$reclaim" \
    "$([ "$claim" = "/" ] && echo '(never claimed)' || echo "$claim")" "${extra:-PV only}"
done

echo
read -r -p ">> numbers to delete (e.g. 1 3, or all, empty aborts): " PICK
[ -n "${PICK// /}" ] || {
  say "Nothing selected. No changes."
  exit 0
}

SELECTED=()
if [ "$PICK" = "all" ]; then
  SELECTED=("${ROWS[@]}")
else
  for n in ${PICK//,/ }; do
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#ROWS[@]}" ] || die "not a listed number: ${n}"
    SELECTED+=("${ROWS[$((n - 1))]}")
  done
fi

say "About to delete ${#SELECTED[@]} PV(s) and the Longhorn volume behind each. The data goes with them. S3 backups are kept."
for row in "${SELECTED[@]}"; do printf '  - %s\n' "${row%%|*}"; done
confirm_word DELETE "this destroys the volume data, so" || die "aborted, nothing deleted"

FAILED=""
for row in "${SELECTED[@]}"; do
  IFS='|' read -r name _ _ _ _ <<< "$row"
  say "$name"
  kubectl delete pv "$name" --wait=false > /dev/null 2>&1 && echo "  pv deleted" || {
    warn "pv delete failed"
    FAILED="${FAILED} ${name}"
  }
  if has_volume "$name"; then
    kubectl -n longhorn-system delete volumes.longhorn.io "$name" --wait=false > /dev/null 2>&1 \
      && echo "  longhorn volume deleted" || {
      warn "longhorn volume delete failed"
      FAILED="${FAILED} ${name}(volume)"
    }
  fi
  bv="$(backupvolumes_for "$name" | tr '\n' ' ')"
  [ -n "${bv// /}" ] && echo "  S3 backup kept: ${bv% }"
done

[ -z "$FAILED" ] || die "some deletes failed:${FAILED}"
say "Done. The pv-abandoned alert clears on the exporter's next scan."
