#!/usr/bin/env bash
#
# Shared helpers for every script here. Source it near the top: it self-locates the repo root, loads the
# gitignored .env, and derives what a flat file cannot hold (paths, the ops./app. host tiers).
# It sets no shell options; each script keeps its own `set` line.

[[ -n "${_COMMON_SH:-}" ]] && return
_COMMON_SH=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# die() is not defined yet, so error raw.
ENV_FILE="${REPO_ROOT}/.env"
if [ ! -f "$ENV_FILE" ]; then
  printf '\033[1;31mERROR: missing %s\n       copy the template and edit it:  cp .env.example .env\033[0m\n' \
    "$ENV_FILE" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

# Scripts run under `set -u`, so default every key here: an older .env missing one must not trip it.
# Empty means "skip the feature it enables", see each key's comment in .env.example.
: "${KUBE_CONTEXT:=}"                     # the ONE kubectl context every script here may touch; empty = ask once and write it back to .env
: "${GITHUB_GHCR_PULL_TOKEN_SECRET:=}"    # the OS repo bakes this into the node machine config (kubelet pulls private ghcr.io); here it is only a docker login
: "${ARGOCD_GITHUB_PAT_SECRET:=}"         # 02a seeds ArgoCD's repo-creds Secret
: "${NTFY_PHONE_PASSWORD_SECRET:=}"       # 06 seeds the ntfy 'phone' user (Grafana pushes alerts to ntfy, phone subscribes)
: "${GOOGLE_SSO_CLIENT_ID:=}"      # 04_google_sso writes it into the google-sso values
: "${GOOGLE_SSO_CLIENT_SECRET:=}"  # 04_google_sso seals it for Envoy Gateway OIDC
: "${CLOUDFLARE_API_TOKEN_SECRET:=}"  # 04_cloudflare_token seals it into cert-manager for DNS-01 (empty = HTTP-01 only)
: "${AWS_DEPLOY_ACCESS_KEY_ID:=}"          # 10a runs Terraform with these; empty = skip S3 backups (10a-10e no-op)
: "${AWS_DEPLOY_SECRET_ACCESS_KEY_SECRET:=}"  # 10a Terraform deployer secret (never sealed into the cluster)
# Not secrets, defaulted for the same set -u reason.
: "${BASE_DOMAIN:=}"               # 04_values writes it into the SSO + ingress chart values; every public host sits under it
: "${SSO_ALLOWLIST:=}"             # 04_values writes it into the google-sso allowlist (space-separated accounts)
: "${INGRESS_LB_IP:=}"             # 04_values writes it into the envoy-gateway values (the one IP every ingress answers on)
: "${POLL_SYNC_ENABLED:=false}"    # 02b patches timeout.reconciliation from this (false=300s fallback / true=60s)
: "${CLOUDFLARE_WILDCARD_DOMAINS:=}"  # 04_values writes into the gateway + ingress-lib values (DNS-01 wildcard host tiers; empty = none, HTTP-01 only)
: "${AWS_REGION:=}"                    # 10a Terraform region + 10b CNPG S3 endpoint region
: "${S3_BACKUP_BUCKET:=}"              # 10a Terraform bucket name + 10b injects it into pg-cluster values
: "${S3_BACKUP_TRANSITION_DAYS:=30}"   # 10a lifecycle: Glacier-IR transition age
: "${S3_BACKUP_RETENTION_DAYS:=180}"   # 10a lifecycle: expiry age (recovery window)
: "${CNPG_BACKUP_RPO:=15min}"          # 10b sets archive_timeout in pg-cluster values

SS_CONTROLLER_NS="sealed-secrets"                            # kubeseal --controller-namespace (== 02_sealed_secrets)
SS_CONTROLLER_NAME="sealed-secrets"                          # kubeseal --controller-name
SS_POD_SELECTOR="app.kubernetes.io/name=sealed-secrets"     # the controller pods (readiness probe)
SS_KEY_LABEL="sealedsecrets.bitnami.com/sealed-secrets-key"  # label on its key Secrets (03 backup/restore)
MONITORING_NS="monitoring"                                   # the monitoring-stack namespace (ntfy seal / krr)
WORKLOAD_CHARTS="${REPO_ROOT}/argo_apps/workloads/charts"    # the workloads tree the recover_* scripts edit
PLATFORM_CHARTS="${REPO_ROOT}/argo_apps/platform/charts"     # the platform tree the step scripts write values into
TF_DIR="${REPO_ROOT}/terraform"                              # the Terraform root (10a applies it; 10b-10e read its outputs)

# Cannot live in a flat .env: it interpolates.
# The two host tiers. Fixed labels, not knobs: the SSO policy sets one cookieDomain for BASE_DOMAIN, and a
# cookie only ever reaches that domain and its subdomains, so a tier outside it could never be logged into.
OPS_DOMAIN="ops.${BASE_DOMAIN}"                 # platform UIs:  <sub>.ops.<base>
APP_DOMAIN="app.${BASE_DOMAIN}"                 # workloads:     <sub>.app.<base>

say()  { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
warn() { printf '  \033[33m[warn]\033[0m %s\n' "$*"; }

PASS=0; FAIL=0
ok()  { printf '  \033[32m[PASS]\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
# Returns non-zero if anything failed, so a caller can `summary || exit 1`.
summary() {
  printf '\n=============== summary: %d passed, %d failed ===============\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

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

# Line-surgical edits, NOT `yq -i`: yq rewrites the whole document (collapses comment alignment, drops blank
# lines, re-flows inline maps), so even a write that changes NOTHING leaves the file modified, which trips
# 02a_argocd's uncommitted-changes gate. yq stays fine for READS.
# Each helper writes back with `cat tmp > file`, not `mv`: mv would leave the file with mktemp's 0600.

# ys_set <file> <value> <key...>: replace the value of one existing nested key, in place, touching that ONE
# line and keeping its trailing comment. The value is written verbatim, so the caller quotes it when the CRD
# needs a string. Silent when the path isn't found, so every caller asserts with a `yq -r` read-back after.
ys_set() {
  local f="$1" v="$2"; shift 2
  local tmp; tmp="$(mktemp)" || return 1
  VAL="$v" awk -v path="$*" '
    function keyof(s) { sub(/^ */, "", s); sub(/:.*/, "", s); gsub(/^"|"$/, "", s); return s }
    BEGIN { n = split(path, want, " "); lvl = 1; parent = -1; val = ENVIRON["VAL"] }
    lvl > n || /^ *(#|$)/ { print; next }
    {
      match($0, /^ */); ind = RLENGTH
      if (ind <= parent || (lvl == 1 && ind != 0)) { print; next }   # left the parent block, give up
      if ($0 !~ /^ *[^ ]+:/ || keyof($0) != want[lvl]) { print; next }
      if (lvl < n) { parent = ind; lvl++; print; next }
      tail = ""; if (match($0, / +#.*$/)) tail = substr($0, RSTART)
      print substr($0, 1, ind) want[n] ": " val tail
      lvl = n + 1
    }
  ' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
}

# ys_set_list <file> <space-separated items> <key...>: same, for a key whose value is a block sequence of
# plain scalars. Rewrites the whole sequence; no items collapses it to an inline `[]`.
ys_set_list() {
  local f="$1" items="$2"; shift 2
  local tmp; tmp="$(mktemp)" || return 1
  ITEMS="$items" awk -v path="$*" '
    function keyof(s) { sub(/^ */, "", s); sub(/:.*/, "", s); gsub(/^"|"$/, "", s); return s }
    BEGIN { n = split(path, want, " "); lvl = 1; parent = -1; m = split(ENVIRON["ITEMS"], item, " ") }
    lvl > n || /^ *(#|$)/ { print; next }
    eating {
      if ($0 ~ /^ *- /) next                                        # drop the old sequence entries
      eating = 0; lvl = n + 1; print; next
    }
    {
      match($0, /^ */); ind = RLENGTH
      if (ind <= parent || (lvl == 1 && ind != 0)) { print; next }
      if ($0 !~ /^ *[^ ]+:/ || keyof($0) != want[lvl]) { print; next }
      if (lvl < n) { parent = ind; lvl++; print; next }
      tail = ""; if (match($0, / +#.*$/)) tail = substr($0, RSTART)
      pre = substr($0, 1, ind)
      print pre want[n] ":" (m ? "" : " []") tail
      for (i = 1; i <= m; i++) print pre "  - " item[i]
      eating = 1
    }
  ' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
}

# ys_set_each <file> <value> <key...> <leaf>: set <leaf> on EVERY item of the block sequence at <key...>.
# ys_set walks mappings only, so it cannot reach a key under a `- ` item; this is the sequence counterpart.
ys_set_each() {
  local f="$1" v="$2"; shift 2
  local tmp; tmp="$(mktemp)" || return 1
  VAL="$v" awk -v path="$*" '
    function keyof(s) { sub(/^ *(- )?/, "", s); sub(/:.*/, "", s); gsub(/^"|"$/, "", s); return s }
    BEGIN { n = split(path, want, " "); lvl = 1; parent = -1; val = ENVIRON["VAL"] }
    /^ *(#|$)/ { print; next }
    lvl <= n - 1 {                                     # still walking down to the sequence key
      match($0, /^ */); ind = RLENGTH
      if (ind <= parent || (lvl == 1 && ind != 0)) { print; next }
      if ($0 !~ /^ *[^ ]+:/ || keyof($0) != want[lvl]) { print; next }
      parent = ind; lvl++; print; next
    }
    {                                                  # inside the sequence: rewrite the leaf on every item
      match($0, /^ */); ind = RLENGTH
      if (ind <= parent) { lvl = n + 1; print; next }  # dedented out of the sequence block, stop
      if ($0 !~ /^ *(- )?[^ ]+:/ || keyof($0) != want[n]) { print; next }
      tail = ""; if (match($0, / +#.*$/)) tail = substr($0, RSTART)
      match($0, /^ *(- )?/)                            # keep the item marker where the leaf carries one
      print substr($0, 1, RLENGTH) want[n] ": " val tail
    }
  ' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
}

# Accepts both spellings because callers pass `true` and `1` about evenly. A gate that recognised only one
# would prompt in an unattended run, and an orchestrator with no stdin reads that as an abort.
assume_yes() { case "${ASSUME_YES:-}" in true|1|yes|YES) return 0 ;; *) return 1 ;; esac; }

confirm() {
  assume_yes && return 0
  local a; read -rp "$1 [y/N]: " a; [[ "$a" =~ ^[Yy]$ ]]
}

# Destructive-action gate: make the operator type a word, because y is too easy to hit by reflex. Both return
# non-zero on a mismatch so the caller picks its own abort message and exit code.
#   confirm_word        <WORD> <prompt>  honours ASSUME_YES, for steps an orchestrator drives unattended
#   confirm_word_always <WORD> <prompt>  ignores it, for the gates that wipe the cluster. An ASSUME_YES left
#                                        over from an earlier command must never be able to skip those.
_ask_word() { local a; read -r -p ">> ${2:+$2 }type $1 to proceed: " a; [ "$a" = "$1" ]; }
confirm_word()        { assume_yes && return 0; _ask_word "$@"; }
confirm_word_always() { _ask_word "$@"; }

# Prints "<values-file>\t<alias>" and returns 0, or nothing and 1.
# versionKey is the kind discriminator: postgresVersion for pg-cluster, redisVersion for redis-instance, each
# absent from the other. Not cosmetic: matching on `name` alone would let the CNPG script hand a REDIS alias to
# its restore-block writer, which redis-instance has no knob for and would silently ignore.
wl_find_alias() {
  local src="$1" vkey="$2" f a
  for f in "${WORKLOAD_CHARTS}"/*/values.yaml; do
    [ -f "$f" ] || continue
    a="$(SRC="$src" VKEY="$vkey" yq -r \
      '[to_entries[] | select(.value | type == "!!map")
        | select(.value.name == strenv(SRC)) | select(.value[strenv(VKEY)] != null) | .key] | .[0] // ""' \
      "$f" 2>/dev/null)"
    if [ -n "$a" ] && [ "$a" != "null" ]; then printf '%s\t%s\n' "$f" "$a"; return 0; fi
  done
  return 1
}

# Callers test emptiness, so this works for scalars and maps alike: an absent key and an empty one both read "".
vy_read() { ALIAS="$2" K="$3" yq -r '.[strenv(ALIAS)][strenv(K)] // ""' "$1" 2>/dev/null; }

# SUBSTITUTES an existing line rather than inserting one, which is safe because both charts make the knob
# REQUIRED. Callers still assert with vy_read afterwards. Each writes the WHOLE line, comment included, so the
# pair round-trips: whichever ran last leaves no orphan comment from the other.
vy_protect_on() {
  local f="$1" alias="$2" tmp; tmp="$(mktemp)"
  awk -v alias="$alias" '
    $0 ~ "^"alias":" { inb=1; print; next }
    inb && /^[^[:space:]#]/ { inb=0 }
    inb && /^  deletionProtection:/ {
      print "  deletionProtection: true    # always true in steady state; flip to false only to delete it"; next
    }
    { print }
  ' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
}

vy_protect_off() {
  local f="$1" alias="$2" tmp; tmp="$(mktemp)"
  awk -v alias="$alias" '
    $0 ~ "^"alias":" { inb=1; print; next }
    inb && /^[^[:space:]#]/ { inb=0 }
    inb && /^  deletionProtection:/ {
      print "  deletionProtection: false   # TRANSIENT (DR restore): re-protected once the restore is verified"; next
    }
    { print }
  ' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
}

CLUSTER_DIR="${REPO_ROOT}/secrets"   # this repo's sealed-secrets key + webhook secret; a symlink to an off-repo store
PINNED_KUBECONFIG="${REPO_ROOT}/.cache/kubeconfig"   # derived, gitignored; rewritten by every use_kubeconfig call

# Offers the contexts in $1 and writes the pick back to .env, so this is asked once per checkout. Needs a TTY:
# an orchestrator step running unattended must not silently pick a cluster.
_pick_kube_context() {
  local src="$1" names n choice
  mapfile -t names < <(KUBECONFIG="$src" kubectl config get-contexts -o name | sort)
  [ "${#names[@]}" -gt 0 ] || die "no contexts in ${src}. Build the cluster in the OS repo
       (https://github.com/yama6a/talos-raspberry-pi5-cluster), then there:  make bootstrap-cluster && make merge-kubeconfig"
  [ -t 0 ] || die "KUBE_CONTEXT is not set in .env and there is no terminal to ask on.
       Set it by hand to the cluster THIS repo may touch, one of:
$(printf '         %s\n' "${names[@]}")"
  say "KUBE_CONTEXT is not set in .env. Which cluster may this repo touch?"
  warn "every script here applies to it, and the DANGEROUS_ ones redeliver the whole platform. Choose carefully."
  for n in "${!names[@]}"; do printf '   %2d) %s\n' "$((n+1))" "${names[$n]}"; done
  read -r -p ">> number: " choice || die "aborted"
  [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#names[@]}" ] || die "not a listed number: ${choice}"
  KUBE_CONTEXT="${names[$((choice-1))]}"
  if grep -q '^KUBE_CONTEXT=' "$ENV_FILE"; then
    local tmp; tmp="$(mktemp)"
    sed "s|^KUBE_CONTEXT=.*|KUBE_CONTEXT=\"${KUBE_CONTEXT}\"|" "$ENV_FILE" > "$tmp" && cat "$tmp" > "$ENV_FILE"
    rm -f "$tmp"
  else
    printf '\nKUBE_CONTEXT="%s"\n' "$KUBE_CONTEXT" >> "$ENV_FILE"
  fi
  ok "wrote KUBE_CONTEXT=\"${KUBE_CONTEXT}\" to .env (edit it there to change clusters)"
}

# Nothing hands us a kubeconfig path (the OS repo keeps its own in its own store), so we read the ambient
# kubectl config. That holds every cluster you use, and "whatever is currently selected" is not safe to apply
# a whole platform to, so PIN: write a one-context, self-contained copy and point KUBECONFIG at THAT. Every
# kubectl, helm and kubeseal inherits it, and a `kubectl config use-context` elsewhere cannot retarget us.
# Re-derived on every call (cheap) so an edited .env takes effect on the next step.
use_kubeconfig() {
  local src="${KUBECONFIG_SOURCE:-${KUBECONFIG:-$HOME/.kube/config}}"
  [ -f "$src" ] || die "no kubeconfig at ${src}. Build the cluster in the OS repo
       (https://github.com/yama6a/talos-raspberry-pi5-cluster), then there:
       make bootstrap-cluster && make merge-kubeconfig"
  [ -n "$KUBE_CONTEXT" ] || _pick_kube_context "$src"
  mkdir -p "$(dirname "$PINNED_KUBECONFIG")"
  # Subshell so the umask does not leak into the caller. --minify keeps one context, --flatten inlines its
  # certs, so the result stands alone and no other cluster is even reachable from it.
  ( umask 077; KUBECONFIG="$src" kubectl config view --flatten --minify --context="$KUBE_CONTEXT" \
      > "$PINNED_KUBECONFIG" 2>/dev/null ) \
    || die "context \"${KUBE_CONTEXT}\" (from .env) is not in ${src}. Available:
$(KUBECONFIG="$src" kubectl config get-contexts -o name | sed 's/^/         /')"
  export KUBECONFIG="$PINNED_KUBECONFIG"
}
assert_api() { kubectl get nodes >/dev/null 2>&1 || die "kubectl can't reach the API via ${KUBECONFIG} (context: $(kubectl config current-context 2>/dev/null || echo none))"; }

# Every sealing step's preflight. Asserts a controller pod is READY, not merely that the get succeeded:
# `kubectl get pods -l <selector>` exits 0 when NOTHING matches, so a plain get catches an unreachable API but
# waves through a missing controller, which then fails deep inside kubeseal instead.
assert_sealed_secrets_ready() {
  kubectl get pods -n "$SS_CONTROLLER_NS" -l "$SS_POD_SELECTOR" \
      -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True \
    || die "no Ready sealed-secrets controller in ns/${SS_CONTROLLER_NS}. Is the platform app 02_sealed_secrets synced?
       kubectl -n ${SS_CONTROLLER_NS} get pods"
}

# Puts the .env DEPLOY creds where the aws CLI looks. The recover_* scripts read the backup bucket with the
# deploy user, not the backup writer, so this is separate from read_backup_creds.
export_deploy_aws_creds() {
  export AWS_ACCESS_KEY_ID="$AWS_DEPLOY_ACCESS_KEY_ID"
  export AWS_SECRET_ACCESS_KEY="$AWS_DEPLOY_SECRET_ACCESS_KEY_SECRET"
  export AWS_DEFAULT_REGION="$AWS_REGION"
}

# The S3 backup writer creds, created by 13 and living in Terraform state, never in .env. Sets AKID + SAK.
read_backup_creds() {
  say "reading backup-writer creds from terraform output"
  AKID="$(terraform -chdir="$TF_DIR" output -raw backup_access_key_id 2>/dev/null)" || true
  SAK="$(terraform -chdir="$TF_DIR" output -raw backup_secret_access_key 2>/dev/null)" || true
  [ -n "$AKID" ] && [ -n "$SAK" ] \
    || die "no Terraform outputs: run 10a_s3_backup_bucket.sh first (and it must have applied)"
  ok "got writer access key id + secret from terraform"
}

# strict-scope SealedSecret manifest; pass `--raw --scope cluster-wide` for a bare ciphertext value. Every
# sealing script goes through this.
# Feed it with `<<<` or `< <(...)`, never `producer | kubeseal_to`: the right side of a pipe is a subshell, so
# the die below would kill only that subshell and the caller would sail on past a failed seal.
# Retried, because the controller is often still settling when a bootstrap reaches the sealing steps, and it
# DIES rather than returning non-zero: a failed seal leaves <outfile> holding the PREVIOUS cluster's
# ciphertext, which a caller that carried on would commit.
SEAL_BACKOFF="4 8 16 32 64"   # seconds between tries; 5 retries, so 6 tries and ~2 min before giving up
kubeseal_to() {
  local out="$1"; shift
  local inf err attempt=1 delay
  [ "$#" -gt 0 ] || set -- --format yaml --scope strict
  inf="$(mktemp)"; cat > "$inf"   # buffered to a file, not a var: --raw input must keep its bytes exactly
  mkdir -p "$(dirname "$out")"
  for delay in $SEAL_BACKOFF ""; do
    if err="$(kubeseal --controller-namespace "$SS_CONTROLLER_NS" --controller-name "$SS_CONTROLLER_NAME" \
                "$@" < "$inf" 2>&1 > "${out}.tmp")" && [ -s "${out}.tmp" ]; then
      mv "${out}.tmp" "$out"; rm -f "$inf"
      [ "$attempt" -gt 1 ] && ok "kubeseal succeeded on attempt ${attempt}" >&2
      return 0
    fi
    rm -f "${out}.tmp"
    [ -n "$delay" ] || break
    # stderr, not stdout: seal_raw calls this inside a $(...) and progress on stdout would land in the ciphertext
    warn "kubeseal attempt ${attempt} failed (${err##*$'\n'}); retrying in ${delay}s" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
  done
  rm -f "$inf"
  die "kubeseal failed ${attempt} times, last error: ${err##*$'\n'}
       Is the controller up?  kubectl -n ${SS_CONTROLLER_NS} get pods
       ${out} was NOT written, so it still holds the previous seal if it existed. Do NOT commit that: on a
       rebuilt cluster the old ciphertext is undecryptable and its app comes up with no Secret at all."
}

# seal_secret <name> <ns> <outfile> <key=value>...: build a Secret client-side from any number of keys, seal it
# strict-scope, then sanity-check the result. The ONE manifest sealer; only 14's cluster-wide raw ciphertext
# goes elsewhere. Emits ok/bad per check, and dies via kubeseal_to if the seal cannot be made.
seal_secret() {
  local name="$1" ns="$2" out="$3"; shift 3
  local pair key value manifest; local args=()
  [ "$#" -gt 0 ] || die "seal_secret ${name}: no key=value pairs given"
  for pair in "$@"; do
    case "$pair" in *=*) ;; *) die "seal_secret ${name}: '${pair}' is not key=value" ;; esac
    # An empty value would make the plaintext-leak grep below match everything and cry wolf, so reject it here.
    [ -n "${pair#*=}" ] || die "seal_secret ${name}: key '${pair%%=*}' has an empty value"
    args+=(--from-literal="$pair")
  done
  manifest="$(kubectl create secret generic "$name" -n "$ns" --dry-run=client -o yaml "${args[@]}")" \
    || die "kubectl could not build the ${name} Secret"
  kubeseal_to "$out" <<< "$manifest"
  ok "sealed ${name} -> ${out} (ns ${ns}), overwritten if it existed"
  grep -q 'kind: SealedSecret' "$out" && ok "output is a SealedSecret" || bad "not a SealedSecret manifest"
  for pair in "$@"; do
    key="${pair%%=*}"; value="${pair#*=}"
    grep -q "$key"    "$out" && ok "encryptedData has ${key}" || bad "encryptedData missing ${key}"
    grep -qF "$value" "$out" && bad "PLAINTEXT ${key} in output, DO NOT COMMIT" || ok "no plaintext ${key} in output"
  done
}

# The caller sets STEP=0 and STEP_TOTAL=<n> once; every step goes through step()/run_step(), so adding or
# removing a step only changes STEP_TOTAL, never a hand-written number.

step() { STEP=$((STEP+1)); say "STEP ${STEP}/${STEP_TOTAL}, $*"; }

# run_step <label> <dir> <script> [best-effort] [hint]: runs <dir>/<script> in a subshell with stdin detached,
# then dies (default) or warns and returns 1 (best-effort). The 5th arg overrides the recovery hint.
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

# _ingress_serves_ok <host> <lbip>: 0 only for a real, Let's-Encrypt-backed HTTPS response. Connects straight
# to the load-balancer IP while still claiming the hostname, so nothing outside the cluster (your DNS, your
# router hairpinning) is in the path: this proves the CLUSTER serves. CA trust is ignored, since LE staging is
# untrusted-but-fine. --http2 offers HTTP/2 but the negotiated version is NOT asserted: Envoy Gateway
# negotiates HTTP/1.1 by default, and requiring HTTP/2 hangs every host forever.
_ingress_serves_ok() {
  local host="$1" ip="$2" issuer code
  issuer="$(printf '' | openssl s_client -connect "${ip}:443" -servername "$host" 2>/dev/null \
            | openssl x509 -noout -issuer 2>/dev/null)"
  printf '%s' "$issuer" | grep -qiE "Let.?s Encrypt" || return 1   # temp/self-signed/wrong cert -> wait
  code="$(curl -k --http2 -sS -o /dev/null -w '%{http_code}' \
    --resolve "${host}:443:${ip}" --max-time 10 "https://${host}/" 2>/dev/null)"
  case "${code:-000}" in [234][0-9][0-9]) return 0;; *) return 1;; esac   # 000 (conn/TLS fail) / 5xx -> wait
}

# verify_ingress <gateway-ns> <wait-secs> [host...]: poll until every HTTPS host on the Gateways in <ns>
# serves. With no hosts given, derives them from the Gateways' HTTPS listeners. Best-effort: ArgoCD brings the
# ingress up async and HTTP-01 issuance takes minutes, so it prints ok/warn and returns 0 iff all serve.
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
      [ -z "${remaining// }" ] && { echo; ok "all ingress hosts serve an LE cert over HTTPS (via ${lbip})"; return 0; }
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

# converge_argocd_apps <max-secs>: bootstrap/rebuild backstop. NOT here to rescue exhausted retries, per-app
# unbounded retry already converges everything. Its job is to hard-refresh every app so it re-compares against
# the just-pushed commit (no webhook yet, and the poll is 300s) and to force a prompt health recompute.
# Never touches a Running op. Best-effort: warns and returns 1 on timeout.
converge_argocd_apps() {
  local deadline pending name sync health opphase a
  deadline=$(( $(date +%s) + ${1:-720} ))
  use_kubeconfig
  # Hard-refresh every app first, so ArgoCD re-compares against the latest commit even on apps still
  # reporting Synced against an older revision.
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
