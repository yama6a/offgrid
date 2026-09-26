#!/usr/bin/env bash
# Regenerates every committed Chart.lock that is out of sync with its Chart.yaml.
# A stale lock fails the Argo CD sync. This runs no git. Commit the diff yourself.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
JOBS=12 # parallel `helm dependency build` runs. The work waits on the network, so more than the core count is fine.

# ---- state ----
CHARTS=() # set by find_charts_with_remote_deps
TMPD=""   # set by make_scratch_dir, removed by its trap
FIXED=0   # tallied by report_results

# ---- functions ----

# A chart with only file:// dependencies commits no Chart.lock, so there is nothing to check.
find_charts_with_remote_deps() {
  mapfile -t CHARTS < <(
    grep -rl --include=Chart.yaml '^dependencies:' "${REPO_ROOT}/argo_apps" "${REPO_ROOT}/lib/helm" 2> /dev/null \
      | while read -r f; do
        grep -qE '^[[:space:]]*repository:[[:space:]]*"?(https|oci)://' "$f" && dirname "$f"
      done | sort -u
  )
  [[ ${#CHARTS[@]} -gt 0 ]] || {
    say "no charts pin dependencies"
    exit 0
  }
}

# Runs serially before the workers, so they only read the repo cache and never race to write its index.
# Skips a URL already added under any name, so a configured machine gets no duplicate repos.
add_missing_helm_repos() {
  local existing url
  existing="$(helm repo list 2> /dev/null || true)"
  while read -r url; do
    [ -n "$url" ] || continue
    printf '%s' "$existing" | grep -qF "$url" && continue
    helm repo add "dep-$(printf '%s' "$url" | shasum | cut -c1-8)" "$url" > /dev/null 2>&1 \
      || warn "could not add helm repo ${url}. The chart that uses it can fail below."
  done < <(
    grep -rhE '^[[:space:]]*repository:[[:space:]]*"?https://' --include=Chart.yaml \
      "${REPO_ROOT}/argo_apps" "${REPO_ROOT}/lib/helm" 2> /dev/null \
      | sed -E 's#.*(https://[^"[:space:]]+).*#\1#' | sort -u
  )
}

make_scratch_dir() {
  TMPD="$(mktemp -d)"
  trap 'rm -rf "$TMPD"' EXIT
  export REPO_ROOT TMPD
  export -f pin_chart_lock_timestamp # each worker runs in its own `bash -c`
}

# `helm dependency build` fails fast on a digest mismatch, so a chart in sync keeps its lock timestamp.
# Each worker writes "status<TAB>message" to its own file, and report_results reads them in order.
build_charts_in_parallel() {
  say "checking ${#CHARTS[@]} chart(s), ${JOBS} at a time. The first run can fetch remote charts."
  printf '%s\0' "${CHARTS[@]}" | xargs -0 -P "$JOBS" -n1 bash -c '
  dir="$1"
  rel="${dir#"${REPO_ROOT}/"}"
  out="${TMPD}/$(printf "%s" "$rel" | tr "/" "_")"
  if helm dependency build "$dir" --skip-refresh >/dev/null 2>&1; then
    printf "ok\t%s (in sync)\n" "$rel" > "$out"
  elif helm dependency update "$dir" --skip-refresh >/dev/null 2>&1 || helm dependency update "$dir" >/dev/null 2>&1; then
    pin_chart_lock_timestamp "$dir"
    printf "fixed\t%s (Chart.lock regenerated)\n" "$rel" > "$out"
  else
    printf "bad\t%s (run by hand with: helm dependency update %s)\n" "$rel" "$rel" > "$out"
  fi
' _
}

report_results() {
  local f status msg
  for f in "$TMPD"/*; do
    [ -e "$f" ] || continue
    IFS=$'\t' read -r status msg < "$f"
    case "$status" in
      ok) ok "$msg" ;;
      fixed)
        ok "$msg"
        FIXED=$((FIXED + 1))
        ;;
      *) bad "$msg" ;;
    esac
  done
  say "regenerated ${FIXED} stale lock(s)"
}

# ---- main ----

require helm
find_charts_with_remote_deps
add_missing_helm_repos
make_scratch_dir
build_charts_in_parallel
report_results

summary || exit 1
