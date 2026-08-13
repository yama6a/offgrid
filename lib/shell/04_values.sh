#!/usr/bin/env bash
# Propagates every per-deployment value from .env into the chart values ArgoCD renders, so the shell side and
# ArgoCD agree. Writes values only: it never applies anything to the cluster, and must stay that way, because
# ArgoCD reads the REMOTE and these values have to be committed and pushed before the bootstrap reaches 05.
# It does READ the cluster, for the control-plane node IPs below. That is safe here: this repo always runs
# against a cluster the OS repo already built, and 01_cilium has run by the time the orchestrator gets here.
# The Cloudflare token is NOT sealed here (04_cloudflare_token.sh does that once the controller is up). Here
# it only GATES the zones: an empty token forces zones to [], because a dns01 solver with no token would
# reference a missing Secret and fail every challenge.
# After changing lib/helm/ingress you must re-vendor its consumers once (`helm dependency update` per
# consumer) before a local render picks up the new templates and defaults.
# Idempotent and non-interactive: every list is rebuilt from the knobs below, never edited in place, so an
# interrupted run leaves nothing half-substituted.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
GW_CHART="${PLATFORM_CHARTS}/03_gateway"                       # the gateway wrapper chart (Argo consumes it too)
GW_VALUES="${GW_CHART}/values.yaml"
LIB_VALUES="${REPO_ROOT}/lib/helm/ingress/values.yaml"         # shared ingress-lib default (all consumers inherit)
SSO_VALUES="${PLATFORM_CHARTS}/04_google_sso/values.yaml"
EG_VALUES="${PLATFORM_CHARTS}/01_envoy_gateway/values.yaml"
VM_VALUES="${PLATFORM_CHARTS}/05_victoria_metrics_k8s_stack/values.yaml"
GRAFANA_VALUES="${PLATFORM_CHARTS}/05_grafana/values.yaml"
NTFY_VALUES="${PLATFORM_CHARTS}/05_ntfy/values.yaml"
BB_VALUES="${PLATFORM_CHARTS}/05_blackbox_exporter/values.yaml"
PI_VALUES="${PLATFORM_CHARTS}/06_platform_ingress/values.yaml"
WL_VALUES="${WORKLOAD_CHARTS}/sample_user_manager/values.yaml"
ROOT_APP="${REPO_ROOT}/argo_apps/root.yaml"
# Every file carrying a literal repoURL. The two apps charts hold it once for the 33 Applications they render.
REPO_URL_FILES=(
  "$ROOT_APP"
  "${REPO_ROOT}/argo_apps/roots/0_platform.yaml"
  "${REPO_ROOT}/argo_apps/roots/1_workloads.yaml"
  "${REPO_ROOT}/argo_apps/platform/apps/values.yaml"
  "${REPO_ROOT}/argo_apps/workloads/apps/values.yaml"
)
# Probe targets, by what an anonymous GET should get back. Subdomains only: the tier suffix is composed below,
# so this list never carries a domain and cannot go stale when BASE_DOMAIN changes.
BB_SSO_OPS="argocd grafana vmui vlogs hubble longhorn rabbitmq"   # -> https://<sub>.<ops>/
BB_SSO_APP="sample-user-manager-sso"                              # -> https://<sub>.<app>/
BB_OPEN="ntfy.OPS:/v1/health sample-user-manager.APP:/users"      # -> https://<sub>.<tier><path>

say "prerequisites"
require yq kubectl
use_kubeconfig
assert_api
[ -f "${GW_CHART}/Chart.yaml" ] || die "no chart at ${GW_CHART} (expected argo_apps/platform/charts/03_gateway)"
for f in "$GW_VALUES" "$LIB_VALUES" "$SSO_VALUES" "$EG_VALUES" "$VM_VALUES" "$GRAFANA_VALUES" "$NTFY_VALUES" \
         "$BB_VALUES" "$PI_VALUES" "$WL_VALUES" "${REPO_URL_FILES[@]}"; do
  [ -f "$f" ] || die "missing ${f}"
done
[ -n "${LE_EMAIL}" ]      || die "LE_EMAIL is empty (set it in .env)"
[ -n "${BASE_DOMAIN}" ]   || die "BASE_DOMAIN is empty (set it in .env), every public host is built from it"
[ -n "${SSO_ALLOWLIST}" ] || die "SSO_ALLOWLIST is empty (set it in .env), an empty allowlist locks you out of every gated host"
[ -n "${REPO_URL}" ]      || die "REPO_URL is empty (set it in .env), ArgoCD reconciles that remote"
[ -n "${INGRESS_LB_IP}" ] || die "INGRESS_LB_IP is empty (set it in .env)"
ok "yq present, charts + values found, knobs set"

# An IP outside the Cilium pool never gets assigned, so the Gateway sits <pending> forever with no error
# anywhere. Compare as zero-padded octets so a plain string compare orders them numerically.
_ipkey() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  printf '%03d%03d%03d%03d' "$a" "$b" "$c" "$d"
}
for v in INGRESS_LB_IP:"$INGRESS_LB_IP" LB_RANGE_START:"$LB_RANGE_START" LB_RANGE_STOP:"$LB_RANGE_STOP"; do
  case "${v#*:}" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
    *) die "${v%%:*} is '${v#*:}', which is not a dotted-quad IPv4 address" ;;
  esac
done
if [ "$(_ipkey "$INGRESS_LB_IP")" \< "$(_ipkey "$LB_RANGE_START")" ] ||
   [ "$(_ipkey "$LB_RANGE_STOP")" \< "$(_ipkey "$INGRESS_LB_IP")" ]; then
  die "INGRESS_LB_IP ${INGRESS_LB_IP} is outside the Cilium pool [${LB_RANGE_START}, ${LB_RANGE_STOP}], so the Gateway would never get an address"
fi
ok "INGRESS_LB_IP ${INGRESS_LB_IP} sits inside [${LB_RANGE_START}, ${LB_RANGE_STOP}]"

# Committing the rewritten values is what keeps ArgoCD's render in sync with .env. Values are passed WITH
# their quotes so they stay strings.
say ".env REPO_URL -> the 5 files carrying it  (${REPO_URL})"
for f in "${REPO_URL_FILES[@]}"; do
  case "$f" in
    */values.yaml) ys_set "$f" "\"${REPO_URL}\"" repoURL ;;
    *)             ys_set "$f" "$REPO_URL" spec source repoURL ;;
  esac
done

say ".env -> 03_gateway values  (email=${LE_EMAIL})"
ys_set "$GW_VALUES" "\"${LE_EMAIL}\"" acme email

# DNS-01 needs the token; without it a rendered dns01 solver would reference a missing Secret and every
# challenge would fail. So the token gates the zones: no token => force zones to [] (HTTP-01 for all).
EFFECTIVE_ZONES="$CLOUDFLARE_WILDCARD_DOMAINS"
if [ -z "${CLOUDFLARE_API_TOKEN_SECRET}" ] && [ -n "${CLOUDFLARE_WILDCARD_DOMAINS}" ]; then
  warn "CLOUDFLARE_WILDCARD_DOMAINS set but CLOUDFLARE_API_TOKEN_SECRET empty -> DNS-01 stays OFF (need the token); zones ignored"
  EFFECTIVE_ZONES=""
fi
say ".env CLOUDFLARE_WILDCARD_DOMAINS -> gateway + ingress-lib values  (${EFFECTIVE_ZONES:-<none, HTTP-01 for all>})"
# ys_set_list turns the space-separated scalar into a block sequence, and "" into an inline [] (not [""]).
ys_set_list "$GW_VALUES"  "$EFFECTIVE_ZONES" acme cloudflare zones
ys_set_list "$LIB_VALUES" "$EFFECTIVE_ZONES" cloudflareZones

say ".env BASE_DOMAIN -> the public hosts  (ops=${OPS_DOMAIN} app=${APP_DOMAIN})"
ys_set "$SSO_VALUES"     "\"${BASE_DOMAIN}\""                        domain
ys_set_list "$SSO_VALUES" "$SSO_ALLOWLIST"                           allowlist
ys_set "$GRAFANA_VALUES" "grafana.${OPS_DOMAIN}"                     grafana grafana.ini server domain
ys_set "$GRAFANA_VALUES" "https://grafana.${OPS_DOMAIN}"             grafana grafana.ini server root_url
ys_set "$NTFY_VALUES"    "\"https://ntfy.${OPS_DOMAIN}\""            baseUrl
ys_set_each "$PI_VALUES" "$OPS_DOMAIN"                               ingress ingresses domain
ys_set_each "$WL_VALUES" "$APP_DOMAIN"                               ingress ingresses domain

# Rebuilt whole from the knobs, so a re-run cannot double-substitute a suffix.
_bb() { local out="" s; for s in $1; do out="${out} https://${s}.${2}/"; done; printf '%s' "${out# }"; }
BB_SSO="$(_bb "$BB_SSO_OPS" "$OPS_DOMAIN") $(_bb "$BB_SSO_APP" "$APP_DOMAIN")"
BB_OPEN_URLS=""
for e in $BB_OPEN; do
  sub="${e%%:*}"; path="${e#*:}"
  case "$sub" in *.OPS) sub="${sub%.OPS}.${OPS_DOMAIN}" ;; *.APP) sub="${sub%.APP}.${APP_DOMAIN}" ;; esac
  BB_OPEN_URLS="${BB_OPEN_URLS} https://${sub}${path}"
done
ys_set_list "$BB_VALUES" "$BB_SSO"            probes sso
ys_set_list "$BB_VALUES" "${BB_OPEN_URLS# }"  probes open

# Talos binds these three to localhost and exposes them per-node, so they are scraped by static node IP, and
# only control-plane nodes run them. Read from the live cluster rather than a config file, so adding a
# control-plane node updates the scrape targets on the next run instead of silently leaving them stale.
CP_IPS="$(kubectl get nodes -l node-role.kubernetes.io/control-plane \
            -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address} {end}' 2>/dev/null)"
CP_IPS="$(printf '%s' "$CP_IPS" | tr -s ' ' | sed 's/ $//')"
[ -n "$CP_IPS" ] || die "no control-plane nodes found. Is your kubectl context pointing at the right cluster?"
say "control-plane node IPs -> vm-k8s-stack scrape endpoints  (${CP_IPS})"
for k in kubeControllerManager kubeScheduler kubeEtcd; do
  ys_set_list "$VM_VALUES" "$CP_IPS" victoria-metrics-k8s-stack "$k" endpoints
done

say ".env INGRESS_LB_IP -> envoy-gateway values  (${INGRESS_LB_IP})"
ys_set "$EG_VALUES" "\"${INGRESS_LB_IP}\"" envoyProxy loadBalancerIP

say "verify"
_eq() { # _eq <label> <expected> <actual>
  [ "$2" = "$3" ] && ok "$1 == ${2}" || bad "$1 is '${3}', expected '${2}'"
}
_eq "acme.email"          "$LE_EMAIL"        "$(yq -r '.acme.email' "$GW_VALUES")"
_eq "gateway zones"       "$EFFECTIVE_ZONES" "$(yq -r '.acme.cloudflare.zones | join(" ")' "$GW_VALUES")"
_eq "ingress-lib zones"   "$EFFECTIVE_ZONES" "$(yq -r '.cloudflareZones | join(" ")' "$LIB_VALUES")"
_eq "sso domain"          "$BASE_DOMAIN"     "$(yq -r '.domain' "$SSO_VALUES")"
_eq "sso allowlist"       "$SSO_ALLOWLIST"   "$(yq -r '.allowlist | join(" ")' "$SSO_VALUES")"
_eq "grafana domain"      "grafana.${OPS_DOMAIN}" "$(yq -r '.grafana."grafana.ini".server.domain' "$GRAFANA_VALUES")"
_eq "grafana root_url"    "https://grafana.${OPS_DOMAIN}" "$(yq -r '.grafana."grafana.ini".server.root_url' "$GRAFANA_VALUES")"
_eq "ntfy baseUrl"        "https://ntfy.${OPS_DOMAIN}" "$(yq -r '.baseUrl' "$NTFY_VALUES")"
_eq "platform-ingress domains" "$OPS_DOMAIN" "$(yq -r '[.ingress.ingresses[].domain] | unique | join(" ")' "$PI_VALUES")"
_eq "workload domains"    "$APP_DOMAIN"      "$(yq -r '[.ingress.ingresses[].domain] | unique | join(" ")' "$WL_VALUES")"
_eq "blackbox sso"        "$BB_SSO"          "$(yq -r '.probes.sso | join(" ")' "$BB_VALUES")"
_eq "blackbox open"       "${BB_OPEN_URLS# }" "$(yq -r '.probes.open | join(" ")' "$BB_VALUES")"
_eq "envoy loadBalancerIP" "$INGRESS_LB_IP"  "$(yq -r '.envoyProxy.loadBalancerIP' "$EG_VALUES")"
for k in kubeControllerManager kubeScheduler kubeEtcd; do
  _eq "vm ${k} endpoints" "$CP_IPS" "$(yq -r ".\"victoria-metrics-k8s-stack\".${k}.endpoints | join(\" \")" "$VM_VALUES")"
done
for f in "${REPO_URL_FILES[@]}"; do
  case "$f" in
    */values.yaml) got="$(yq -r '.repoURL' "$f")" ;;
    *)             got="$(yq -r '.spec.source.repoURL' "$f")" ;;
  esac
  _eq "repoURL ${f#"${REPO_ROOT}/"}" "$REPO_URL" "$got"
done

summary
if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
values written from .env: repoURL=${REPO_URL}, domain=${BASE_DOMAIN} (ops=${OPS_DOMAIN}, app=${APP_DOMAIN}),
allowlist='${SSO_ALLOWLIST}', ingress IP=${INGRESS_LB_IP}, ACME email=${LE_EMAIL}, zones='${EFFECTIVE_ZONES:-<none>}',
control-plane scrape endpoints=${CP_IPS}

Next:
  - re-vendor the ingress-library consumers so they pick up the new templates + zone list:
      for c in argo_apps/platform/charts/06_platform_ingress \\
               argo_apps/platform/charts/04_google_sso \\
               argo_apps/workloads/charts/sample_user_manager; do
        helm dependency update "\$c"; done
  - git add -A && git commit && git push   # ArgoCD reconciles the REMOTE, so nothing applies until you push
  - point public DNS for *.${OPS_DOMAIN} and *.${APP_DOMAIN} at your router, forward :80 to ${INGRESS_LB_IP}
$(if [ -n "${CLOUDFLARE_WILDCARD_DOMAINS}" ]; then cat <<'HINT'
  - once ArgoCD + the sealed-secrets controller are up, seal the Cloudflare token:  make configure-cloudflare-token
    (the bootstrap orchestrator runs this for you). Without it the dns01 solver can't authenticate.
HINT
fi)
  - watch:  kubectl -n gateway get certificate,secret | grep wildcard   # READY=True (DNS-01)
            kubectl -n cert-manager get challenges                       # dns-01 for CF names, http-01 for the rest
  - once wildcard issuance works on staging, flip acme.cloudflare.wildcardIssuer -> letsencrypt-prod, push. See 04_ingress.md.
EOF
else
  echo "Some checks failed, see above. Fix .env and re-run (idempotent)."
fi
[ "$FAIL" -eq 0 ]
