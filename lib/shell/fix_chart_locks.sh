#!/usr/bin/env bash
# Regenerates any committed Chart.lock that is out of sync with its Chart.yaml, which is the exact failure
# ArgoCD's repo-server hits on sync. Detection is `helm dependency build`, which fast-fails on the digest
# mismatch, so in-sync charts are left alone and get no timestamp churn.
# Runs no git: it edits Chart.lock and charts/ in place, commit the diff yourself.
# The per-chart check is network-bound, so charts are checked in parallel. The first run is the slow one.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

require helm

# ---- knobs ----
JOBS=12   # parallel `helm dependency build`s; network-bound, so more than cores is fine

# Charts that pin at least one REMOTE (https/oci) dependency. A file://-only chart is lockless (its deps live in
# this repo, nothing to pin), so it commits no Chart.lock and there is nothing here to check or fix.
mapfile -t CHARTS < <(
  grep -rl --include=Chart.yaml '^dependencies:' "${REPO_ROOT}/argo_apps" "${REPO_ROOT}/lib/helm" 2>/dev/null \
  | while read -r f; do
      grep -qE '^[[:space:]]*repository:[[:space:]]*"?(https|oci)://' "$f" && dirname "$f"
    done | sort -u
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
