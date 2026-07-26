#!/usr/bin/env bash
#
# fix_chart_locks.sh
#
# Find every chart that pins dependencies and, where its committed Chart.lock is out of sync with Chart.yaml
# (the exact failure ArgoCD's repo-server hits on sync), regenerate the lock with `helm dependency update`.
# Detection is `helm dependency build`, which fast-fails on the lock/Chart.yaml digest mismatch, so only truly
# stale charts are rewritten (no timestamp churn on in-sync ones). No git: it edits Chart.lock (+ charts/) in
# place; commit the diff yourself.
#
# The per-chart check is network-bound (an in-sync remote-dep chart still has its dependency charts fetched into
# charts/ before it's confirmed), so charts are checked in parallel. First run is the slow one; charts/ is then
# cached.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require helm

# ---- knobs ----
JOBS=12   # parallel `helm dependency build`s; network-bound, so more than cores is fine. Edit to change.

# Charts with a `dependencies:` block, across both GitOps trees + the shared lib.
mapfile -t CHARTS < <(
  grep -rl --include=Chart.yaml '^dependencies:' "${REPO_ROOT}/argo_apps" "${REPO_ROOT}/lib/helm" 2>/dev/null \
  | while read -r f; do dirname "$f"; done | sort -u
)
[[ ${#CHARTS[@]} -gt 0 ]] || { say "no charts pin dependencies"; exit 0; }

# Ensure every https helm repo a dependency references is available (file:// deps need nothing). Skip URLs
# already added under their real name, so a configured machine gets no cryptic duplicates. Serial + up front so
# the parallel workers below only READ the repo cache (--skip-refresh) and never race on writing its index.
existing="$(helm repo list 2>/dev/null || true)"
while read -r url; do
  [ -n "$url" ] || continue
  printf '%s' "$existing" | grep -qF "$url" && continue
  helm repo add "dep-$(printf '%s' "$url" | shasum | cut -c1-8)" "$url" >/dev/null 2>&1 \
    || warn "could not add helm repo ${url} (that chart may fail below)"
done < <(
  grep -rhE '^[[:space:]]*repository:[[:space:]]*"?https://' --include=Chart.yaml \
    "${REPO_ROOT}/argo_apps" "${REPO_ROOT}/lib/helm" 2>/dev/null \
  | sed -E 's#.*(https://[^"[:space:]]+).*#\1#' | sort -u
)

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
export REPO_ROOT TMPD

say "checking ${#CHARTS[@]} chart(s), ${JOBS} at a time (first run may fetch remote charts)"

# One worker per chart, capped at JOBS concurrent. Each writes "status<TAB>message" to its own temp file, so the
# parent can tally serially afterwards. Distinct chart dirs => no write contention between workers.
printf '%s\0' "${CHARTS[@]}" | xargs -0 -P "$JOBS" -n1 bash -c '
  dir="$1"
  rel="${dir#"${REPO_ROOT}/"}"
  out="${TMPD}/$(printf "%s" "$rel" | tr "/" "_")"
  if helm dependency build "$dir" --skip-refresh >/dev/null 2>&1; then
    printf "ok\t%s (in sync)\n" "$rel" > "$out"
  elif helm dependency update "$dir" --skip-refresh >/dev/null 2>&1 || helm dependency update "$dir" >/dev/null 2>&1; then
    printf "fixed\t%s (Chart.lock regenerated)\n" "$rel" > "$out"
  else
    printf "bad\t%s (run by hand: helm dependency update %s)\n" "$rel" "$rel" > "$out"
  fi
' _

FIXED=0
for f in "$TMPD"/*; do
  [ -e "$f" ] || continue
  IFS=$'\t' read -r status msg < "$f"
  case "$status" in
    ok)    ok "$msg" ;;
    fixed) ok "$msg"; FIXED=$((FIXED+1)) ;;
    *)     bad "$msg" ;;
  esac
done

say "regenerated ${FIXED} stale lock(s)"
summary || exit 1
