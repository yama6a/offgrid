#!/usr/bin/env bash
#
# lib/common.sh — shared helpers for every bootstrap script in this repo.
#
# Source it near the top of a script; it self-locates the repo root and pulls in the single root
# config.sh (the one source of truth for all knobs/values):
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/../lib/common.sh"      # repo-root scripts: "${SCRIPT_DIR}/lib/common.sh"
#
# It does NOT set shell options — each script keeps its own `set` line (`-euo` for one-shot scripts
# that should abort early; `-uo` for the PASS/FAIL scripts that accumulate failures and report).
#
# Provides:
#   say / die / warn                  consistent leveled output
#   PASS / FAIL + ok / bad + summary  check counters and the trailing summary banner
#   require <tool…>                   tool preflight (die with an install hint on the first missing)
#   CLUSTER_DIR / use_kubeconfig / assert_api   the 03d talos-cluster credentials
#   talosctl                          dockerized talosctl against that talosconfig
#   seal_secret <name> <ns> <key> <value> <out>  seal + sanity-check a SealedSecret (12/15/16)

[[ -n "${_COMMON_SH:-}" ]] && return
_COMMON_SH=1

# Repo root = the dir above this file (lib/). Robust regardless of which script sources it.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The single source of truth for all knobs/values (sibling of this file, in lib/).
# shellcheck source=config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

# ---- output helpers (consistent across every script) ------------------------
say()  { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
warn() { printf '  \033[33m[warn]\033[0m %s\n' "$*"; }

# PASS/FAIL check counters. ok/bad take a single message.
PASS=0; FAIL=0
ok()  { printf '  \033[32m[PASS]\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
# Print the summary banner (with a leading blank line) and return non-zero if anything failed — so a
# caller can `summary || exit 1`. Scripts that print extra guidance keep their own trailing test.
summary() {
  printf '\n=============== summary: %d passed, %d failed ===============\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

# ---- tool preflight ---------------------------------------------------------
# require <tool…> — die on the first tool missing from PATH, with an install hint.
require() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null && continue
    case "$t" in
      kubectl)  die "kubectl not found on PATH — install it (https://kubernetes.io/docs/tasks/tools/)" ;;
      helm)     die "helm not found on PATH — install it (https://helm.sh/docs/intro/install/)" ;;
      yq)       die "yq not found on PATH — install it (https://github.com/mikefarah/yq, brew install yq)" ;;
      kubeseal) die "kubeseal not found on PATH — install it (brew install kubeseal)" ;;
      docker)   die "docker not found on PATH (and it needs host networking enabled)" ;;
      *)        die "$t not found on PATH" ;;
    esac
  done
}

# ---- cluster credentials (written by 03d to the gitignored talos-cluster dir) ----
CLUSTER_DIR="${REPO_ROOT}/03_operating_system/talos-cluster"   # canonical talosconfig + kubeconfig

# Point KUBECONFIG at the 03d kubeconfig (respecting a pre-set value) and assert it exists.
use_kubeconfig() {
  export KUBECONFIG="${KUBECONFIG:-${CLUSTER_DIR}/kubeconfig}"   # the 03d kubeconfig (points at the VIP)
  [ -f "$KUBECONFIG" ] || die "missing ${KUBECONFIG} — run step 03 (03d) first"
}
# Assert the API answers via the current KUBECONFIG.
assert_api() { kubectl get nodes >/dev/null 2>&1 || die "kubectl can't reach the API via ${KUBECONFIG}"; }

# ---- dockerized talosctl (talos-phase + reset scripts) ----------------------
# Runs talosctl in Docker against the talosconfig in CLUSTER_DIR (host networking, stdin attached).
talosctl() {
  docker run --rm -i --network host \
    -v "${CLUSTER_DIR}:/work" -w /work \
    -e TALOSCONFIG=/work/talosconfig \
    "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" "$@"
}

# ---- sealed-secrets helper (steps 12/15/16) ---------------------------------
# seal_secret <name> <ns> <key> <value> <outfile>
# Build a generic Secret (client-side), seal it strict-scope against this cluster's controller, then
# sanity-check the result (kind: SealedSecret present, encryptedData has the key, no plaintext leak).
# Emits ok/bad for each check; returns non-zero if kubeseal itself failed (no file written).
seal_secret() {
  local name="$1" ns="$2" key="$3" value="$4" out="$5"
  mkdir -p "$(dirname "$out")"
  if kubectl create secret generic "$name" -n "$ns" \
        --dry-run=client -o yaml \
        --from-literal="${key}=${value}" \
     | kubeseal --controller-namespace "$SS_CONTROLLER_NS" --controller-name "$SS_CONTROLLER_NAME" \
         --format yaml --scope strict > "${out}.tmp" 2>/dev/null; then
    mv "${out}.tmp" "$out"
    ok "SealedSecret written (overwritten if it existed)"
  else
    rm -f "${out}.tmp"
    bad "kubeseal failed — SealedSecret NOT written (controller sealed-secrets/${SS_CONTROLLER_NS} up?)"
    return 1
  fi
  if [ -s "$out" ]; then
    grep -q 'kind: SealedSecret' "$out" && ok "output is a SealedSecret" || bad "not a SealedSecret manifest"
    grep -q "$key" "$out"               && ok "encryptedData has ${key}" || bad "encryptedData missing ${key}"
    grep -qF "$value" "$out" && bad "PLAINTEXT secret in output — DO NOT COMMIT" || ok "no plaintext secret in output"
  else
    bad "sealed output is empty/missing"
  fi
}
