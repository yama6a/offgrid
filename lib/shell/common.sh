#!/usr/bin/env bash
#
# lib/shell/common.sh, shared helpers for every bootstrap script in this repo.
#
# Source it near the top of a script; it self-locates the repo root, loads the gitignored .env (the
# single source of truth for editable config AND secrets — tokens/passwords are read from .env, never
# prompted), and derives the computed values (node array, install paths, version aliases, build-cache
# key, the published installer ref). Every script now lives beside this file in lib/shell/, so:
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/common.sh"             # common.sh is a sibling in lib/shell/
#
# It does NOT set shell options, each script keeps its own `set` line (`-euo` for one-shot scripts
# that should abort early; `-uo` for the PASS/FAIL scripts that accumulate failures and report).
#
# Provides:
#   say / die / warn                  consistent leveled output
#   PASS / FAIL + ok / bad + summary  check counters and the trailing summary banner
#   require <tool...>                   tool preflight (die with an install hint on the first missing)
#   CLUSTER_DIR / use_kubeconfig / assert_api   the 03d secrets credentials
#   talosctl                          dockerized talosctl against that talosconfig
#   seal_secret <name> <ns> <key> <value> <out>  seal + sanity-check a SealedSecret (07/09)
#   step / run_step                   numbered step runner for the DANGEROUS_* orchestrators
#   verify_ingress <ns> <secs> [host] best-effort: poll that the ingress serves LE certs over HTTP/2

[[ -n "${_COMMON_SH:-}" ]] && return
_COMMON_SH=1

# Repo root = two dirs above this file (lib/shell/). Robust regardless of which script sources it.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ---- pinned version recipe: the COMMITTED versions.env (shared, renovate-managed) -----------------
# The build recipe (versions + digest pins), same for everyone, so it's committed (not in .env). Sourced
# FIRST; the derived block below (BUILD_KEY, *_VERSION aliases) reads it. die() isn't defined yet, error raw.
VERSIONS_FILE="${REPO_ROOT}/versions.env"
if [ ! -f "$VERSIONS_FILE" ]; then
  printf '\033[1;31mERROR: missing %s (committed recipe; it should be in the repo checkout)\033[0m\n' \
    "$VERSIONS_FILE" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$VERSIONS_FILE"

# ---- personal config + secrets: the gitignored .env (copy .env.example -> .env and edit it) --------
# Holds the plain scalar config (topology, domains, ...) + secrets; fixed identifiers (namespaces,
# operator names, hardware NIC/disk) are NOT here, they're constants below, and versions are in
# versions.env. Gitignored so your IPs/domains/usernames/tokens stay out of git; .env.example is the
# committed template. die() isn't defined yet (helpers are below), so error raw.
ENV_FILE="${REPO_ROOT}/.env"
if [ ! -f "$ENV_FILE" ]; then
  printf '\033[1;31mERROR: missing %s\n       copy the template and edit it:  cp .env.example .env\033[0m\n' \
    "$ENV_FILE" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

# ---- secrets (read from .env, never prompted; default empty so an older .env missing a key is safe) ----
# Scripts run under `set -u`; defaulting here means a script can reference any of these even if the key
# isn't in .env yet. Empty = "skip the feature it enables" (see each key's comment in .env.example).
: "${GITHUB_GHCR_PULL_TOKEN_SECRET:=}"    # 03d bakes into node machine config (kubelet pulls private ghcr.io)
: "${GITHUB_GHCR_PUSH_TOKEN_SECRET:=}"    # 03a docker-login + push of the installer image (build host only)
: "${ARGOCD_GITHUB_PAT_SECRET:=}"         # 05 seeds ArgoCD's repo-creds Secret
: "${NTFY_PHONE_PASSWORD_SECRET:=}"       # 10 seeds the ntfy 'phone' user (Grafana pushes alerts to ntfy, phone subscribes)
: "${GOOGLE_SSO_CLIENT_ID:=}"      # 07 writes into the google-sso values
: "${GOOGLE_SSO_CLIENT_SECRET:=}"  # 07 seals it for Envoy Gateway OIDC
: "${CLOUDFLARE_API_TOKEN_SECRET:=}"  # 07 seals it into cert-manager for DNS-01 (empty = HTTP-01 only)
: "${AWS_DEPLOY_ACCESS_KEY_ID:=}"          # 13 runs Terraform with these; empty = skip S3 backups (13/14 no-op)
: "${AWS_DEPLOY_SECRET_ACCESS_KEY_SECRET:=}"  # 13 Terraform deployer secret (never sealed into the cluster)
# Not a secret, but defaulted here for the same reason (an older .env missing the key must not trip set -u).
: "${POLL_SYNC_ENABLED:=false}"    # 08 patches timeout.reconciliation from this (false=300s fallback / true=60s)
: "${CLOUDFLARE_ZONES:=}"          # 07 writes into the gateway + ingress-lib values (DNS-01 zones; empty = none, HTTP-01 only)
: "${AWS_REGION:=}"                    # 13 Terraform region + 14 CNPG S3 endpoint region
: "${S3_BACKUP_BUCKET:=}"              # 13 Terraform bucket name + 14 injects it into pg-cluster values
: "${S3_BACKUP_TRANSITION_DAYS:=30}"   # 13 lifecycle: Glacier-IR transition age
: "${S3_BACKUP_RETENTION_DAYS:=180}"   # 13 lifecycle: expiry age (recovery window)
: "${CNPG_BACKUP_RPO:=15min}"          # 14 sets archive_timeout in pg-cluster values

# ---- fixed cluster identifiers (NOT user config; not in .env) -------------------------------------
# Pinned by the hardware + platform install, not per-deployment. Changing one only makes sense alongside
# the matching component (a different SBC, a re-namespaced operator), so they live here, not in .env.
EXPECT_NIC="end0"          # Pi 5 wired NIC (the VIP binds to it)
EXPECT_DISK="nvme0n1"      # the NVMe (install target)
API_PORT=50000            # Talos API port
GHCR_SERVER="ghcr.io"     # registry the GHCR tokens + installer package are scoped to
INSTALLER_PACKAGE="talos-installer"                           # GHCR package 03a publishes the installer to (03f pulls it)
SS_CONTROLLER_NS="sealed-secrets"                            # kubeseal --controller-namespace (== 02_sealed_secrets)
SS_CONTROLLER_NAME="sealed-secrets"                          # kubeseal --controller-name
SS_POD_SELECTOR="app.kubernetes.io/name=sealed-secrets"     # the controller pods (readiness probe)
SS_KEY_LABEL="sealedsecrets.bitnami.com/sealed-secrets-key"  # label on its key Secrets (06 backup/restore)
MONITORING_NS="monitoring"                                   # the monitoring-stack namespace (09/krr)

# ---- derived config (computed from the .env scalars; not user-editable) ---------------------------
# These can't live in a flat .env (arrays, interpolation, a shasum-keyed path), so they're computed here.
read -ra CLUSTER_NODES <<< "${CLUSTER_NODES}"   # .env CLUSTER_NODES is a space-separated "host:ip" string -> array
NODES="${CLUSTER_NODES[*]##*:}"                 # IPs only (space-separated); used by boot-verify + reset
IFACE="${EXPECT_NIC}"                           # wired NIC the VIP binds to (dhcp + vip)
INSTALL_DISK="/dev/${EXPECT_DISK}"              # nvme0n1 -> /dev/nvme0n1
MACHINERY_VERSION="${TALOS_VERSION}"            # overlay rebuilt against this (must match TALOS_VERSION)
TALOSCTL_VERSION="${TALOS_VERSION}"             # talosctl container (talosctl() below; boot-verify)
# Build-cache key + dirs (shared: 03a builder writes, 03b flasher reads). Keyed by the pinned inputs so
# 03a/03b resolve the SAME paths: change any version/ref/tag and the build lands in a fresh .cache/<key>.
BUILD_KEY="${TALOS_VERSION}-${KERNEL_REF}-$(printf '%s' \
  "${BUILDER_VERSION}|${PKG_VERSION}|${SBCOVERLAY_VERSION}|${MACHINERY_VERSION}|${ISCSI_EXT}|${UTIL_EXT}" \
  | shasum -a 256 | cut -c1-8)"
BUILD_DIR="${REPO_ROOT}/.cache/${BUILD_KEY}"   # build scratch + output (gitignored; repo-root .cache/)
OUT_DIR="${BUILD_DIR}/out"                      # final image is staged here for the flasher
# Published installer image (03a pushes it to GHCR, 03f upgrades nodes from it). Tag off TALOS_VERSION
# (not the build's `git describe`), so 03a and 03f compute the SAME ref deterministically, no git state.
INSTALLER_IMAGE="${GHCR_SERVER}/${GHCR_USER}/${INSTALLER_PACKAGE}"  # e.g. ghcr.io/<user>/talos-installer
INSTALLER_REF="${INSTALLER_IMAGE}:${TALOS_VERSION}-arm64"           # exact tag 03a pushes / 03f pulls

# ---- output helpers (consistent across every script) ------------------------
say()  { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
warn() { printf '  \033[33m[warn]\033[0m %s\n' "$*"; }

# PASS/FAIL check counters. ok/bad take a single message.
PASS=0; FAIL=0
ok()  { printf '  \033[32m[PASS]\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
# Print the summary banner (with a leading blank line) and return non-zero if anything failed, so a
# caller can `summary || exit 1`. Scripts that print extra guidance keep their own trailing test.
summary() {
  printf '\n=============== summary: %d passed, %d failed ===============\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

# ---- tool preflight ---------------------------------------------------------
# require <tool...>, die on the first tool missing from PATH, with an install hint.
require() {
  local t
  for t in "$@"; do
    command -v "$t" >/dev/null && continue
    case "$t" in
      kubectl)  die "kubectl not found on PATH, install it (https://kubernetes.io/docs/tasks/tools/)" ;;
      helm)     die "helm not found on PATH, install it (https://helm.sh/docs/intro/install/)" ;;
      yq)       die "yq not found on PATH, install it (https://github.com/mikefarah/yq, brew install yq)" ;;
      kubeseal) die "kubeseal not found on PATH, install it (brew install kubeseal)" ;;
      docker)   die "docker not found on PATH (and it needs host networking enabled)" ;;
      *)        die "$t not found on PATH" ;;
    esac
  done
}

# ---- cluster credentials (written by 03d to the gitignored secrets/ symlink at the repo root) ----
CLUSTER_DIR="${REPO_ROOT}/secrets"   # canonical talosconfig + kubeconfig (symlink -> off-repo creds store)

# Point KUBECONFIG at the canonical 03d kubeconfig and assert it exists.
use_kubeconfig() {
  export KUBECONFIG="${CLUSTER_DIR}/kubeconfig"   # the 03d kubeconfig (points at the VIP)
  [ -f "$KUBECONFIG" ] || die "missing ${KUBECONFIG}, run step 03 (03d) first"
}
# Assert the API answers via the current KUBECONFIG.
assert_api() { kubectl get nodes >/dev/null 2>&1 || die "kubectl can't reach the API via ${KUBECONFIG}"; }

# ---- dockerized talosctl (talos-phase + reset scripts) ----------------------
# Runs talosctl in Docker against the talosconfig in CLUSTER_DIR (host networking, stdin attached).
# MacOS talosCTL is completely broken for some reason.
# TALOS_SCRATCH (optional): a host temp dir (mktemp -d) mounted at /scratch, for a script's throwaway
# render files (machine configs, patches) that must be container-visible but must NOT persist in the
# durable secrets dir. Empty/unset => not mounted (the :+ form is nounset-safe). 03d/03e set it.
talosctl() {
  docker run --rm -i --network host \
    -v "${CLUSTER_DIR}:/work" -w /work \
    ${TALOS_SCRATCH:+-v "${TALOS_SCRATCH}:/scratch"} \
    -e TALOSCONFIG=/work/talosconfig \
    "ghcr.io/siderolabs/talosctl:${TALOSCTL_VERSION}" "$@"
}

# ---- sealed-secrets helper (steps 07/09) ------------------------------------
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
    bad "kubeseal failed, SealedSecret NOT written (controller sealed-secrets/${SS_CONTROLLER_NS} up?)"
    return 1
  fi
  if [ -s "$out" ]; then
    grep -q 'kind: SealedSecret' "$out" && ok "output is a SealedSecret" || bad "not a SealedSecret manifest"
    grep -q "$key" "$out"               && ok "encryptedData has ${key}" || bad "encryptedData missing ${key}"
    grep -qF "$value" "$out" && bad "PLAINTEXT secret in output, DO NOT COMMIT" || ok "no plaintext secret in output"
  else
    bad "sealed output is empty/missing"
  fi
}

# ---- orchestrator step runner (DANGEROUS_* bootstrap/rebuild) ----------------
# The two orchestrators run the numbered step scripts in sequence under a shared "STEP N/TOTAL" counter.
# The caller sets STEP=0 and STEP_TOTAL=<n> once up front; every step then goes through step()/run_step(),
# so the numbers stay correct when a step is added or removed (only STEP_TOTAL changes — no hand-renumber).

# step <label...>  — bump the counter and print the banner (for an inline step that isn't a script call).
step() { STEP=$((STEP+1)); say "STEP ${STEP}/${STEP_TOTAL}, $*"; }

# run_step <label> <dir> <script> [best-effort] [hint]
# Numbered runner for a step that IS a single script call: bump+banner (via step), run <dir>/<script> in a
# subshell with stdin detached (orchestrators are non-interactive after their one confirm), then on success
# print "<script> done", and on failure either die (default) or warn + return 1 ("best-effort"). Pass a
# custom recovery hint as the 5th arg; otherwise a generic "resume from <script> by hand" is used.
run_step() {
  local label="$1" dir="$2" script="$3" mode="${4:-fatal}" hint="${5:-}"
  step "${script} (${label})"
  if ( cd "$dir" && bash "./$script" </dev/null ); then ok "${script} done"; return 0; fi
  if [ "$mode" = best-effort ]; then
    warn "${hint:-${script} did not complete; re-run it by hand + commit/push if needed}"
    return 1
  fi
  die "${hint:-${script} failed, fix and resume from ${script%.sh} by hand}"
}

# ---- ingress data-path verification (DANGEROUS_* bootstrap/rebuild) ----------
# _ingress_serves_ok <host> <lbip>: 0 only for a REAL, Let's-Encrypt-backed HTTPS response. Hits the LB IP
# directly with the right SNI (--resolve), so a home-router/DDNS/hairpin quirk can't wedge it — this proves
# the CLUSTER serves. CA trust is ignored (-k): LE *staging* is untrusted-but-fine; every OTHER failure
# (self-signed temp cert, wrong-SNI cert, TLS/connection failure -> code 000, or 5xx) keeps the caller
# waiting. NB we do NOT require HTTP/2: Envoy Gateway negotiates HTTP/1.1 by default (ALPN http/1.1), which
# serves fine — asserting h2 made every host hang here forever. --http2 is kept so h2 is still used if the
# gateway enables it later, but the negotiated version is not checked (only the cert + response code).
_ingress_serves_ok() {
  local host="$1" ip="$2" issuer code
  issuer="$(printf '' | openssl s_client -connect "${ip}:443" -servername "$host" 2>/dev/null \
            | openssl x509 -noout -issuer 2>/dev/null)"
  printf '%s' "$issuer" | grep -qiE "Let.?s Encrypt" || return 1   # temp/self-signed/wrong cert -> wait
  code="$(curl -k --http2 -sS -o /dev/null -w '%{http_code}' \
    --resolve "${host}:443:${ip}" --max-time 10 "https://${host}/" 2>/dev/null)"
  case "${code:-000}" in [234][0-9][0-9]) return 0;; *) return 1;; esac   # 000 (conn/TLS fail) / 5xx -> wait
}

# verify_ingress <gateway-ns> <wait-secs> [host...]
# Best-effort poll until every HTTPS host on the Gateways in <ns> serves via _ingress_serves_ok. With no
# hosts given, derives them from the Gateways' HTTPS listeners (under mergeGateways every `eg` Gateway
# shares one LB Service, so any Gateway's status carries the LB IP). ArgoCD brings the ingress up async and
# HTTP-01 issuance takes minutes, so callers run this best-effort: prints ok/warn, returns 0 iff all serve.
verify_ingress() {
  local ns="$1" wait_secs="$2"; shift 2
  local want_hosts="$*"
  use_kubeconfig
  if ! command -v curl >/dev/null || ! command -v openssl >/dev/null; then
    warn "curl/openssl not both present, skipping ingress verification"; return 0
  fi
  local deadline=$(( $(date +%s) + wait_secs )) remaining="" lbip="" hosts h
  while :; do
    lbip="$(kubectl get gateway -n "$ns" \
            -o jsonpath='{range .items[*]}{.status.addresses[0].value}{"\n"}{end}' 2>/dev/null | grep -m1 .)"
    if [ -n "$want_hosts" ]; then hosts="$want_hosts"; else
      hosts="$(kubectl get gateway -n "$ns" \
               -o jsonpath='{range .items[*].spec.listeners[?(@.protocol=="HTTPS")]}{.hostname}{"\n"}{end}' 2>/dev/null \
               | sort -u | tr '\n' ' ')"
    fi
    if [ -n "$lbip" ] && [ -n "${hosts// }" ]; then
      remaining=""
      for h in $hosts; do _ingress_serves_ok "$h" "$lbip" || remaining="${remaining} ${h}"; done
      [ -z "${remaining// }" ] && { echo; ok "all ingress hosts serve an LE cert over clean HTTP/2 (via ${lbip})"; return 0; }
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo
      warn "ingress not fully serving within ${wait_secs}s${lbip:+ (LB ${lbip})}, still pending:${remaining:-  <gateway/hosts not found yet>}"
      warn "inspect: kubectl get gateway,certificate -A ; kubectl -n argocd get applications"
      return 1
    fi
    printf '.'; sleep 10
  done
}

# converge_argocd_apps <max-secs> — bootstrap/rebuild backstop for the DANGEROUS_* orchestrators.
# Real self-healing (per-app syncPolicy.retry limit:-1 + refresh + selfHeal) converges every app on its own;
# with an unbounded retry budget an app never permanently gives up, so this is NOT here to rescue exhausted
# retries. Its job on a bootstrap/rebuild: hard-refresh EVERY app so it re-compares against the just-pushed
# commit (the webhook isn't configured yet and the poll is 300s) and force a prompt health recompute (e.g.
# after the STEP-7 key restore, where a Synced app's health otherwise lags the poll). Each pass, for every app
# NOT Synced+Healthy: hard-refresh it, and if it has NO sync op in flight, force a sync. Never touches a
# Running op (leaves genuine progress alone). Best-effort: warns + returns 1 on timeout (non-fatal).
converge_argocd_apps() {
  local deadline pending name sync health opphase a
  deadline=$(( $(date +%s) + ${1:-720} ))
  use_kubeconfig
  # one hard-refresh of EVERY app first, so ArgoCD re-compares against the latest pushed commit even on apps
  # still reporting Synced against an older revision (e.g. after a bootstrap pushes re-sealed secrets).
  kubectl -n argocd get applications -o name 2>/dev/null | while read -r a; do
    kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  done
  while :; do
    pending=""
    while read -r name sync health opphase; do
      [ -z "$name" ] && continue
      { [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; } && continue
      pending="${pending} ${name}"
      kubectl -n argocd annotate app "$name" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
      if [ "$opphase" != "Running" ]; then          # don't interrupt an in-flight sync; only push idle stragglers
        kubectl -n argocd patch app "$name" --type merge \
          -p '{"operation":{"initiatedBy":{"username":"converge-backstop"},"sync":{}}}' >/dev/null 2>&1 || true
      fi
    done < <(kubectl -n argocd get applications \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.sync.status}{" "}{.status.health.status}{" "}{.status.operationState.phase}{"\n"}{end}' 2>/dev/null)
    [ -z "${pending// }" ] && { echo; ok "all ArgoCD apps Synced + Healthy"; return 0; }
    [ "$(date +%s)" -ge "$deadline" ] && { echo; warn "apps not Synced+Healthy within ${1:-720}s:${pending}"; warn "inspect: kubectl -n argocd get applications"; return 1; }
    printf '.'; sleep 20
  done
}
