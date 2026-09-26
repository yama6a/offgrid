#!/usr/bin/env bash
#
# Shared helpers for every script here. It finds the repo root, loads .env, and derives paths and host tiers.
# It sets no shell options. Each script keeps its own `set` line.

[[ -n "${_COMMON_SH:-}" ]] && return
_COMMON_SH=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# die() is not defined yet, so print the error directly.
ENV_FILE="${REPO_ROOT}/.env"
if [ ! -f "$ENV_FILE" ]; then
  printf '\033[1;31mERROR: missing %s\n       copy the template and edit it: cp .env.example .env\033[0m\n' \
    "$ENV_FILE" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

# Scripts run under `set -u`, so every key gets a default here. An older .env that lacks a key still works.
# Empty skips the feature that the key enables. See each key's comment in .env.example.
: "${KUBE_API_HOST:=localhost}"              # Cilium reaches the API here before pod networking exists. Talos KubePrism.
: "${KUBE_API_PORT:=7445}"                   # port of KUBE_API_HOST
: "${KUBELET_TLS_INSECURE:=true}"            # metrics-server skips kubelet cert checks: self-signed certs, no CSR approver
: "${ETCD_METRICS_PORT:=2381}"               # etcd metrics port, scraped for the control-plane dashboards
: "${LONGHORN_DATA_PATH:=/var/mnt/storage}"  # where Longhorn stores replica data on each node
: "${KUBE_CONTEXT:=}"                        # the one kubectl context these scripts may touch. Empty: ask once, save to .env.
: "${GITHUB_GHCR_PULL_TOKEN_SECRET:=}"       # docker login token only. Configure node-level pull auth on the nodes.
: "${GHCR_SERVER:=ghcr.io}"                  # registry that check_multiarch.sh logs in to when the token is set
: "${ARGOCD_GITHUB_PAT_SECRET:=}"            # 02a puts it into the Argo CD repo-creds Secret
: "${NTFY_PHONE_PASSWORD_SECRET:=}"          # 06 creates the ntfy 'phone' user with it. The phone subscribes to alerts.
: "${GOOGLE_SSO_CLIENT_ID:=}"                # 04_google_sso writes it into the google-sso values
: "${GOOGLE_SSO_CLIENT_SECRET:=}"            # 04_google_sso seals it for Envoy Gateway OIDC
: "${CLOUDFLARE_API_TOKEN_SECRET:=}"         # 04_cloudflare_token seals it for cert-manager DNS-01. Empty: HTTP-01 only.
: "${AWS_DEPLOY_ACCESS_KEY_ID:=}"            # 10a runs Terraform with it. Empty: no S3 backups, and 10a to 10e do nothing.
: "${AWS_DEPLOY_SECRET_ACCESS_KEY_SECRET:=}" # 10a Terraform deployer secret. Never sealed into the cluster.
# Not secrets. They get a default for the same `set -u` reason.
: "${BASE_DOMAIN:=}"                 # 04_values writes it into the SSO and ingress values. Every public host sits under it.
: "${SSO_ALLOWLIST:=}"               # 04_values writes it into the google-sso allowlist. Space-separated accounts.
: "${INGRESS_LB_IP:=}"               # 04_values writes it into the envoy-gateway values. Every ingress answers on it.
: "${POLL_SYNC_ENABLED:=false}"      # 02b sets timeout.reconciliation from it: false is 300s, true is 60s
: "${CLOUDFLARE_WILDCARD_DOMAINS:=}" # 04_values writes it into the gateway and ingress values. Empty: no wildcards.
: "${AWS_REGION:=}"                  # 10a Terraform region and 10b CNPG S3 endpoint region
: "${S3_BACKUP_BUCKET:=}"            # 10a Terraform bucket name. 10b writes it into the pg-cluster values.
: "${S3_BACKUP_TRANSITION_DAYS:=30}" # 10a lifecycle: days until objects move to Glacier Instant Retrieval
: "${S3_BACKUP_RETENTION_DAYS:=180}" # 10a lifecycle: days until objects expire. This is the recovery window.
: "${CNPG_BACKUP_RPO:=15min}"        # 10b writes it as archive_timeout into the pg-cluster values

SS_CONTROLLER_NS="sealed-secrets"                           # kubeseal --controller-namespace, same as 02_sealed_secrets
SS_CONTROLLER_NAME="sealed-secrets"                         # kubeseal --controller-name
SS_POD_SELECTOR="app.kubernetes.io/name=sealed-secrets"     # selects the controller pods for the readiness check
SS_KEY_LABEL="sealedsecrets.bitnami.com/sealed-secrets-key" # label on the key Secrets that step 03 backs up and restores
MONITORING_NS="monitoring"                                  # the monitoring namespace, for the ntfy seal and KRR
WORKLOAD_CHARTS="${REPO_ROOT}/argo_apps/workloads/charts"   # the workloads tree that the recover_* scripts edit
PLATFORM_CHARTS="${REPO_ROOT}/argo_apps/platform/charts"    # the platform tree that the step scripts write values into
TF_DIR="${REPO_ROOT}/terraform"                             # the Terraform root. 10a applies it, 10b to 10e read its outputs.

# The two host tiers. They interpolate, so they cannot live in .env. They are fixed, not knobs.
# The SSO cookie covers BASE_DOMAIN and its subdomains only, so a tier outside it could never log in.
OPS_DOMAIN="ops.${BASE_DOMAIN}" # platform UIs:  <sub>.ops.<base>
APP_DOMAIN="app.${BASE_DOMAIN}" # workloads:     <sub>.app.<base>

say() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
die() {
  printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2
  exit 1
}
warn() { printf '  \033[33m[warn]\033[0m %s\n' "$*"; }

PASS=0
FAIL=0
ok() {
  printf '  \033[32m[PASS]\033[0m %s\n' "$1"
  PASS=$((PASS + 1))
}
bad() {
  printf '  \033[31m[FAIL]\033[0m %s\n' "$1"
  FAIL=$((FAIL + 1))
}
# Returns non-zero if anything failed, so a caller can `summary || exit 1`.
summary() {
  printf '\n=============== summary: %d passed, %d failed ===============\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

require() {
  local t
  for t in "$@"; do
    command -v "$t" > /dev/null && continue
    case "$t" in
      kubectl) die "kubectl not found on PATH. Install it: https://kubernetes.io/docs/tasks/tools/" ;;
      helm) die "helm not found on PATH. Install it: https://helm.sh/docs/intro/install/" ;;
      yq) die "yq not found on PATH. Install it with brew install yq, or see https://github.com/mikefarah/yq" ;;
      kubeseal) die "kubeseal not found on PATH. Install it with brew install kubeseal." ;;
      docker) die "docker not found on PATH. It also needs host networking enabled." ;;
      *) die "$t not found on PATH" ;;
    esac
  done
}

# Helm writes the wall clock into Chart.lock `generated:`, so a fork that regenerates the lock conflicts on it.
# Helm checks staleness by `digest` only, so a constant is safe and keeps two runs byte-identical.
pin_chart_lock_timestamp() {
  local lock="${1}/Chart.lock"
  [ -f "$lock" ] || return 0
  local tmp
  tmp="$(mktemp)"
  sed 's/^generated:.*/generated: "1970-01-01T00:00:00Z"/' "$lock" > "$tmp" && cat "$tmp" > "$lock"
  rm -f "$tmp"
}

# These helpers edit single lines. `yq -i` rewrites the whole file, so even a no-op write leaves it modified.
# That trips the uncommitted-changes check in 02a_argocd. They write back with `cat`, because `mv` keeps 0600.

# ys_set <file> <value> <key...>: replace the value of one nested key and keep its trailing comment.
# The value goes in as given, so quote it if it must be a string. A missing path fails silently, so read back.
ys_set() {
  local f="$1" v="$2"
  shift 2
  local tmp
  tmp="$(mktemp)" || return 1
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

# ys_set_list <file> <space-separated items> <key...>: replace a block sequence of scalars.
# No items writes an inline `[]`.
ys_set_list() {
  local f="$1" items="$2"
  shift 2
  local tmp
  tmp="$(mktemp)" || return 1
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

# ys_set_each <file> <value> <key...> <leaf>: set <leaf> on every item of the block sequence at <key...>.
ys_set_each() {
  local f="$1" v="$2"
  shift 2
  local tmp
  tmp="$(mktemp)" || return 1
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

# Callers pass both `true` and `1`. A prompt in an unattended run gets no stdin and aborts.
assume_yes() { case "${ASSUME_YES:-}" in true | 1 | yes | YES) return 0 ;; *) return 1 ;; esac }

confirm() {
  assume_yes && return 0
  local a
  read -rp "$1 [y/N]: " a
  [[ "$a" =~ ^[Yy]$ ]]
}

# Gates for destructive actions. The operator types a word, because y is easy to press by reflex.
#   confirm_word        <WORD> <prompt>  obeys ASSUME_YES, for steps that an orchestrator runs unattended
#   confirm_word_always <WORD> <prompt>  ignores ASSUME_YES, for the gates that wipe the cluster
_ask_word() {
  local a
  read -r -p ">> ${2:+$2 }type $1 to proceed: " a
  [ "$a" = "$1" ]
}
confirm_word() {
  assume_yes && return 0
  _ask_word "$@"
}
confirm_word_always() { _ask_word "$@"; }

# Prints "<values-file>\t<alias>" and returns 0, or prints nothing and returns 1.
# <vkey> tells the chart kinds apart: postgresVersion for pg-cluster, redisVersion for redis-instance.
# A match on `name` alone could hand a Redis alias to the CNPG restore writer, which would ignore it.
wl_find_alias() {
  local src="$1" vkey="$2" f a
  for f in "${WORKLOAD_CHARTS}"/*/values.yaml; do
    [ -f "$f" ] || continue
    a="$(SRC="$src" VKEY="$vkey" yq -r \
      '[to_entries[] | select(.value | type == "!!map")
        | select(.value.name == strenv(SRC)) | select(.value[strenv(VKEY)] != null) | .key] | .[0] // ""' \
      "$f" 2> /dev/null)"
    if [ -n "$a" ] && [ "$a" != "null" ]; then
      printf '%s\t%s\n' "$f" "$a"
      return 0
    fi
  done
  return 1
}

# An absent key and an empty key both read as "".
vy_read() { ALIAS="$2" K="$3" yq -r '.[strenv(ALIAS)][strenv(K)] // ""' "$1" 2> /dev/null; }

# These replace the existing deletionProtection line. Both charts require the key, so the line exists.
# Each writes the whole line with its comment, so the pair round-trips. Callers read back with vy_read.
vy_protect_on() {
  local f="$1" alias="$2" tmp
  tmp="$(mktemp)"
  awk -v alias="$alias" '
    $0 ~ "^"alias":" { inb=1; print; next }
    inb && /^[^[:space:]#]/ { inb=0 }
    inb && /^  deletionProtection:/ {
      print "  deletionProtection: true    # true in steady state. Set to false only to delete it."; next
    }
    { print }
  ' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
}

vy_protect_off() {
  local f="$1" alias="$2" tmp
  tmp="$(mktemp)"
  awk -v alias="$alias" '
    $0 ~ "^"alias":" { inb=1; print; next }
    inb && /^[^[:space:]#]/ { inb=0 }
    inb && /^  deletionProtection:/ {
      print "  deletionProtection: false   # off during a restore. Set back to true once the restore is verified."; next
    }
    { print }
  ' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
}

CLUSTER_DIR="${REPO_ROOT}/secrets" # sealed-secrets key and webhook secret. A symlink to a store outside the repo.

# Creates the directory so a fresh checkout can bootstrap. It warns, because a plain directory dies with the
# checkout and takes the sealed-secrets master key with it.
ensure_cluster_dir() {
  [ -d "$CLUSTER_DIR" ] && return 0
  # mkdir -p on a dangling symlink fails with "File exists", which looks like a bug.
  if [ -L "$CLUSTER_DIR" ]; then
    die "${CLUSTER_DIR} is a symlink to $(readlink "$CLUSTER_DIR"), which does not exist.
       Mount or restore that store, or replace the link."
  fi
  [ -e "$CLUSTER_DIR" ] && die "${CLUSTER_DIR} exists but is not a directory"
  mkdir -p "$CLUSTER_DIR" || die "could not create ${CLUSTER_DIR}"
  chmod 700 "$CLUSTER_DIR"
  warn "created ${CLUSTER_DIR} for the sealed-secrets master key. Git ignores it."
  warn "  It is a plain directory, so the key dies with this checkout. The key cannot be regenerated."
  warn "  Without it, no committed SealedSecret can be decrypted again."
  warn "  Point it at storage that outlives the checkout before you rely on this cluster:"
  warn "    rmdir ${CLUSTER_DIR} && ln -s /path/to/your/synced/store ${CLUSTER_DIR}"
}
PINNED_KUBECONFIG="${REPO_ROOT}/.cache/kubeconfig" # gitignored. Every use_kubeconfig call writes it again.

# Asks once per checkout and saves the pick to .env. It needs a terminal, so an unattended run never picks a cluster.
_pick_kube_context() {
  local src="$1" names n choice
  mapfile -t names < <(KUBECONFIG="$src" kubectl config get-contexts -o name | sort)
  [ "${#names[@]}" -gt 0 ] || die "no contexts in ${src}. Point kubectl at a cluster first.
       This repo needs an existing cluster. See the README, \"What this expects of your cluster\"."
  [ -t 0 ] || die "KUBE_CONTEXT is not set in .env and there is no terminal to ask on.
       Set it by hand to the cluster this repo may touch. The contexts are:
$(printf '         %s\n' "${names[@]}")"
  say "KUBE_CONTEXT is not set in .env. Which cluster may this repo touch?"
  warn "every script here applies to it. The DANGEROUS_ scripts redeliver the whole platform. Choose carefully."
  for n in "${!names[@]}"; do printf '   %2d) %s\n' "$((n + 1))" "${names[$n]}"; done
  read -r -p ">> number: " choice || die "aborted"
  [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#names[@]}" ] || die "not a listed number: ${choice}"
  KUBE_CONTEXT="${names[$((choice - 1))]}"
  if grep -q '^KUBE_CONTEXT=' "$ENV_FILE"; then
    local tmp
    tmp="$(mktemp)"
    sed "s|^KUBE_CONTEXT=.*|KUBE_CONTEXT=\"${KUBE_CONTEXT}\"|" "$ENV_FILE" > "$tmp" && cat "$tmp" > "$ENV_FILE"
    rm -f "$tmp"
  else
    printf '\nKUBE_CONTEXT="%s"\n' "$KUBE_CONTEXT" >> "$ENV_FILE"
  fi
  ok "wrote KUBE_CONTEXT=\"${KUBE_CONTEXT}\" to .env. Edit it there to change clusters."
}

# Writes a kubeconfig that holds only KUBE_CONTEXT and points KUBECONFIG at it. Then kubectl, helm and
# kubeseal reach no other cluster, and `kubectl config use-context` elsewhere cannot change the target.
use_kubeconfig() {
  # KUBECONFIG_SOURCE is exported, so a second call never derives the pinned file from itself.
  local amb="${KUBECONFIG_SOURCE:-${KUBECONFIG:-$HOME/.kube/config}}"
  [ "$amb" = "$PINNED_KUBECONFIG" ] && amb="$HOME/.kube/config" # never our own output
  export KUBECONFIG_SOURCE="$amb"
  local src="$amb"
  [ -f "$src" ] || die "no kubeconfig at ${src}. This repo needs an existing cluster.
       Point kubectl at one, then set KUBE_CONTEXT in .env. See the README, 'What this expects of your cluster'."
  [ -s "$src" ] || die "the kubeconfig at ${src} is empty. Point kubectl at a cluster first."
  [ -n "$KUBE_CONTEXT" ] || _pick_kube_context "$src"
  mkdir -p "$(dirname "$PINNED_KUBECONFIG")"
  # A direct redirect truncates the file before kubectl runs, so a failure would leave it empty.
  # mktemp is 0600 and mv keeps that. --flatten inlines the certs, so the file stands alone.
  local tmp err
  tmp="$(mktemp "${PINNED_KUBECONFIG}.XXXXXX")" || die "could not write next to ${PINNED_KUBECONFIG}"
  if ! err="$(KUBECONFIG="$src" kubectl config view --flatten --minify --context="$KUBE_CONTEXT" 2>&1 > "$tmp")"; then
    rm -f "$tmp"
    die "context \"${KUBE_CONTEXT}\" (from .env) is not usable in ${src}: ${err}
       available contexts: $(KUBECONFIG="$src" kubectl config get-contexts -o name 2> /dev/null | tr '\n' ' ')"
  fi
  [ -s "$tmp" ] || {
    rm -f "$tmp"
    die "rendering context \"${KUBE_CONTEXT}\" from ${src} produced nothing"
  }
  mv "$tmp" "$PINNED_KUBECONFIG"
  export KUBECONFIG="$PINNED_KUBECONFIG"
}
assert_api() { kubectl get nodes > /dev/null 2>&1 || die "kubectl can't reach the API via ${KUBECONFIG}. Context: $(kubectl config current-context 2> /dev/null || echo none)"; }

# `kubectl get pods -l` exits 0 when nothing matches, so this checks for a Ready pod instead.
assert_sealed_secrets_ready() {
  kubectl get pods -n "$SS_CONTROLLER_NS" -l "$SS_POD_SELECTOR" \
    -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2> /dev/null | grep -q True \
    || die "no Ready sealed-secrets controller in ns/${SS_CONTROLLER_NS}. Is the platform app 02_sealed_secrets synced?
       kubectl -n ${SS_CONTROLLER_NS} get pods"
}

# The recover_* scripts read the bucket with the deploy user from .env, not with the backup writer.
export_deploy_aws_creds() {
  export AWS_ACCESS_KEY_ID="$AWS_DEPLOY_ACCESS_KEY_ID"
  export AWS_SECRET_ACCESS_KEY="$AWS_DEPLOY_SECRET_ACCESS_KEY_SECRET"
  export AWS_DEFAULT_REGION="$AWS_REGION"
}

# Sets AKID and SAK to the S3 backup writer creds. 10a creates them in Terraform state, never in .env.
read_backup_creds() {
  say "reading the backup writer creds from terraform output"
  AKID="$(terraform -chdir="$TF_DIR" output -raw backup_access_key_id 2> /dev/null)" || true
  SAK="$(terraform -chdir="$TF_DIR" output -raw backup_secret_access_key 2> /dev/null)" || true
  [ -n "$AKID" ] && [ -n "$SAK" ] \
    || die "no Terraform outputs. Run 10a_s3_backup_bucket.sh first and let it apply."
  ok "got the writer access key id and secret from terraform"
}

# kubeseal_to <outfile> [kubeseal args]: seal stdin. The default output is a strict-scope SealedSecret.
# Feed it with `<<<` or `< <(...)`. In a pipe it runs in a subshell, so its die would not stop the caller.
# It retries, because a bootstrap often reaches it while the controller still starts up.
# It dies on failure, because <outfile> then still holds the old ciphertext, which a caller could commit.
SEAL_BACKOFF="4 8 16 32 64" # seconds between tries: 6 tries, about 2 minutes in total
kubeseal_to() {
  local out="$1"
  shift
  local inf err attempt=1 delay
  [ "$#" -gt 0 ] || set -- --format yaml --scope strict
  inf="$(mktemp)"
  cat > "$inf" # a file, not a variable: --raw input must keep its exact bytes
  mkdir -p "$(dirname "$out")"
  for delay in $SEAL_BACKOFF ""; do
    if err="$(kubeseal --controller-namespace "$SS_CONTROLLER_NS" --controller-name "$SS_CONTROLLER_NAME" \
      "$@" < "$inf" 2>&1 > "${out}.tmp")" && [ -s "${out}.tmp" ]; then
      mv "${out}.tmp" "$out"
      rm -f "$inf"
      [ "$attempt" -gt 1 ] && ok "kubeseal succeeded on attempt ${attempt}" >&2
      return 0
    fi
    rm -f "${out}.tmp"
    [ -n "$delay" ] || break
    # stderr, because seal_raw captures stdout as the ciphertext
    warn "kubeseal attempt ${attempt} failed: ${err##*$'\n'}. Retrying in ${delay}s." >&2
    sleep "$delay"
    attempt=$((attempt + 1))
  done
  rm -f "$inf"
  die "kubeseal failed ${attempt} times, last error: ${err##*$'\n'}
       Is the controller up? kubectl -n ${SS_CONTROLLER_NS} get pods
       ${out} was not written, so it still holds the previous seal if it existed. Do not commit it.
       A rebuilt cluster cannot decrypt the old ciphertext, and its app starts with no Secret."
}

# seal_secret <name> <ns> <outfile> <key=value>...: build a Secret on the client, seal it strict-scope, and
# check the result.
seal_secret() {
  local name="$1" ns="$2" out="$3"
  shift 3
  local pair key value manifest
  local args=()
  [ "$#" -gt 0 ] || die "seal_secret ${name}: no key=value pairs given"
  for pair in "$@"; do
    case "$pair" in *=*) ;; *) die "seal_secret ${name}: '${pair}' is not key=value" ;; esac
    # An empty value would match everything in the plaintext check below.
    [ -n "${pair#*=}" ] || die "seal_secret ${name}: key '${pair%%=*}' has an empty value"
    args+=(--from-literal="$pair")
  done
  manifest="$(kubectl create secret generic "$name" -n "$ns" --dry-run=client -o yaml "${args[@]}")" \
    || die "kubectl could not build the ${name} Secret"
  kubeseal_to "$out" <<< "$manifest"
  ok "sealed ${name} into ${out}, namespace ${ns}. Any old file was overwritten."
  grep -q 'kind: SealedSecret' "$out" && ok "output is a SealedSecret" || bad "not a SealedSecret manifest"
  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    grep -q "$key" "$out" && ok "encryptedData has ${key}" || bad "encryptedData missing ${key}"
    grep -qF "$value" "$out" && bad "plaintext ${key} in output. Do not commit it." || ok "no plaintext ${key} in output"
  done
}

# The caller sets STEP=0 and STEP_TOTAL=<n> once. step() and run_step() count from there.
step() {
  STEP=$((STEP + 1))
  say "STEP ${STEP}/${STEP_TOTAL}, $*"
}

# run_step <label> <dir> <script> [best-effort] [hint]: run <dir>/<script> with no stdin.
# On failure it dies. With best-effort it warns and returns 1. <hint> replaces the default recovery hint.
run_step() {
  local label="$1" dir="$2" script="$3" mode="${4:-fatal}" hint="${5:-}"
  step "${script} (${label})"
  if (cd "$dir" && bash "./$script" < /dev/null); then
    ok "${script} done"
    return 0
  fi
  if [ "$mode" = best-effort ]; then
    warn "${hint:-${script} did not complete. Run it again by hand, then commit and push if needed.}"
    return 1
  fi
  die "${hint:-${script} failed. Fix it, then resume from ${script%.sh} by hand.}"
}

# _ingress_serves_ok <host> <lbip>: return 0 for an HTTPS response with a Let's Encrypt cert.
# It connects to the LB IP directly, so DNS and router hairpinning are not in the path.
# It skips CA trust, because Let's Encrypt staging certs are untrusted.
# It does not require HTTP/2. Envoy Gateway negotiates HTTP/1.1 by default.
_ingress_serves_ok() {
  local host="$1" ip="$2" issuer code
  issuer="$(printf '' | openssl s_client -connect "${ip}:443" -servername "$host" 2> /dev/null \
    | openssl x509 -noout -issuer 2> /dev/null)"
  printf '%s' "$issuer" | grep -qiE "Let.?s Encrypt" || return 1 # temporary, self-signed or wrong cert: wait
  code="$(curl -k --http2 -sS -o /dev/null -w '%{http_code}' \
    --resolve "${host}:443:${ip}" --max-time 10 "https://${host}/" 2> /dev/null)"
  case "${code:-000}" in [234][0-9][0-9]) return 0 ;; *) return 1 ;; esac # 000 is a connect or TLS failure: wait
}

# verify_ingress <gateway-ns> <wait-secs> [host...]: poll until every HTTPS host on the Gateways in <ns> serves.
# With no hosts given, it reads them from the HTTPS listeners. Returns 0 only when all hosts serve.
verify_ingress() {
  local ns="$1" wait_secs="$2"
  shift 2
  local want_hosts="$*"
  use_kubeconfig
  if ! command -v curl > /dev/null || ! command -v openssl > /dev/null; then
    warn "curl or openssl missing, skipping the ingress check"
    return 0
  fi
  local deadline=$(($(date +%s) + wait_secs)) remaining="" lbip="" hosts h
  while :; do
    lbip="$(kubectl get gateway -n "$ns" \
      -o jsonpath='{range .items[*]}{.status.addresses[0].value}{"\n"}{end}' 2> /dev/null | grep -m1 .)"
    if [ -n "$want_hosts" ]; then hosts="$want_hosts"; else
      hosts="$(kubectl get gateway -n "$ns" \
        -o jsonpath='{range .items[*].spec.listeners[?(@.protocol=="HTTPS")]}{.hostname}{"\n"}{end}' 2> /dev/null \
        | sort -u | tr '\n' ' ')"
    fi
    if [ -n "$lbip" ] && [ -n "${hosts// /}" ]; then
      remaining=""
      for h in $hosts; do _ingress_serves_ok "$h" "$lbip" || remaining="${remaining} ${h}"; done
      [ -z "${remaining// /}" ] && {
        echo
        ok "all ingress hosts serve a Let's Encrypt cert over HTTPS via ${lbip}"
        return 0
      }
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo
      warn "ingress not fully serving after ${wait_secs}s${lbip:+ on LB ${lbip}}. Still pending:${remaining:- <no gateway or hosts found yet>}"
      warn "inspect: kubectl get gateway,certificate -A && kubectl -n argocd get applications"
      return 1
    fi
    printf '.'
    sleep 10
  done
}

# converge_argocd_apps <max-secs>: hard-refresh every app so it compares against the commit just pushed.
# During bootstrap there is no webhook yet, and the poll interval is 300s. Returns 1 on timeout.
converge_argocd_apps() {
  local deadline pending name sync health opphase a
  deadline=$(($(date +%s) + ${1:-720}))
  use_kubeconfig
  # An app can report Synced against an older revision, so refresh all of them first.
  kubectl -n argocd get applications -o name 2> /dev/null | while read -r a; do
    kubectl -n argocd annotate "$a" argocd.argoproj.io/refresh=hard --overwrite > /dev/null 2>&1 || true
  done
  while :; do
    pending=""
    while read -r name sync health opphase; do
      [ -z "$name" ] && continue
      { [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; } && continue
      pending="${pending} ${name}"
      kubectl -n argocd annotate app "$name" argocd.argoproj.io/refresh=hard --overwrite > /dev/null 2>&1 || true
      if [ "$opphase" != "Running" ]; then # never interrupt a running sync
        kubectl -n argocd patch app "$name" --type merge \
          -p '{"operation":{"initiatedBy":{"username":"converge-backstop"},"sync":{}}}' > /dev/null 2>&1 || true
      fi
    done < <(kubectl -n argocd get applications \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.sync.status}{" "}{.status.health.status}{" "}{.status.operationState.phase}{"\n"}{end}' 2> /dev/null)
    [ -z "${pending// /}" ] && {
      echo
      ok "all Argo CD apps Synced and Healthy"
      return 0
    }
    [ "$(date +%s)" -ge "$deadline" ] && {
      echo
      warn "apps not Synced and Healthy after ${1:-720}s:${pending}"
      warn "inspect: kubectl -n argocd get applications"
      return 1
    }
    printf '.'
    sleep 20
  done
}
