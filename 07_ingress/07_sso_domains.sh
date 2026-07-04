#!/usr/bin/env bash
#
# 07_sso_domains.sh  (macOS)
#
# Propagates the SSO callback-domain list from .env (SSO_CALLBACK_DOMAINS) into the ingress-edge LIBRARY
# values (argo_apps/_lib/ingress-edge/values.yaml -> ingressEdge.callbackDomains). That list is THE single
# source of which registrable domains have a Google-SSO callback host (google-sso.<domain>): 04_google_sso
# renders one callback host per entry, and every app ingress's domain is guarded against it. This step
# has NO cluster bootstrap; the callbacks are delivered by ArgoCD (04_google_sso, wave 4). See 07_ingress.md.
#
# INTERACTIVE choice (WIPE or ADD):
#   - replace : callbackDomains becomes EXACTLY the .env list (domains not in .env are dropped).
#   - add     : the .env domains are merged INTO the committed list (nothing is removed).
# In BOTH modes a domain that already exists KEEPS its current ClusterIssuer (so a manual flip to
# letsencrypt-prod is never clobbered); a brand-new domain starts on letsencrypt-staging (flip it to prod
# in the chart once its callback cert issues). Non-interactive (e.g. bootstrap piping </dev/null) defaults
# to REPLACE — .env is treated as the authoritative list.
#
# Empty SSO_CALLBACK_DOMAINS => leave the committed list UNCHANGED (skip), so bootstrapping without SSO is
# safe and never wipes the domains.
#
# SINGLE SOURCE OF TRUTH:
#   - .env (here)                                    -> SSO_CALLBACK_DOMAINS (the domain list)
#   - argo_apps/_lib/ingress-edge/values.yaml        -> ingressEdge.callbackDomains (what ArgoCD renders)
# This script writes the former into the latter (yq). No values are hardcoded here.
#
# Idempotent / re-run-safe. Non-secret (domains aren't sensitive), read from .env, not prompted.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# ---- knobs ------------------------------------------------------------------
LIB_VALUES="${REPO_ROOT}/argo_apps/_lib/ingress-edge/values.yaml"   # the library values ArgoCD renders
DEFAULT_ISSUER="letsencrypt-staging"                                # ClusterIssuer for a brand-new domain
# SSO_CALLBACK_DOMAINS comes from .env via the lib.
# -----------------------------------------------------------------------------

# === 0. prereqs ==============================================================
say "prerequisites"
require yq
[ -f "$LIB_VALUES" ] || die "missing ${LIB_VALUES} (the ingress-edge library should ship it)"
ok "yq present, library values found"

# === 1. parse SSO_CALLBACK_DOMAINS from .env =================================
# Empty => leave the committed list untouched (skip). This keeps a no-SSO bootstrap from wiping domains.
if [ -z "${SSO_CALLBACK_DOMAINS//[[:space:]]/}" ]; then
  warn "SSO_CALLBACK_DOMAINS is empty in .env, leaving ingressEdge.callbackDomains unchanged"
  summary; exit 0
fi

say "parsing SSO_CALLBACK_DOMAINS from .env"
ENV_DOMAINS=()
# comma -> newline, lowercase, strip blanks, drop empties + dupes (order-preserving via awk).
while IFS= read -r d; do
  case "$d" in
    *.*) ENV_DOMAINS+=("$d") ;;                          # must look like a registrable domain (has a dot)
    "")  ;;                                              # skip blanks
    *)   bad "'$d' doesn't look like a domain (no dot), skipping" ;;
  esac
done < <(printf '%s' "$SSO_CALLBACK_DOMAINS" | tr ',' '\n' | tr 'A-Z' 'a-z' | tr -d '[:blank:]' | awk 'NF && !seen[$0]++')
[ "${#ENV_DOMAINS[@]}" -ge 1 ] || die "no valid domains parsed from SSO_CALLBACK_DOMAINS='${SSO_CALLBACK_DOMAINS}'"
ok "from .env: ${ENV_DOMAINS[*]}"

# === 2. snapshot the committed list (domain + its current issuer) ============
# Read BEFORE we rewrite, so a surviving domain keeps its issuer (prod flips aren't clobbered).
EXIST_DOMAINS=(); EXIST_ISSUERS=()
while IFS="$(printf '\t')" read -r d i; do
  [ -n "$d" ] || continue
  EXIST_DOMAINS+=("$d"); EXIST_ISSUERS+=("${i:-$DEFAULT_ISSUER}")
done < <(yq -r '.ingressEdge.callbackDomains[]? | [.domain, .issuer] | @tsv' "$LIB_VALUES" 2>/dev/null)
say "committed list: ${EXIST_DOMAINS[*]:-<empty>}"

# issuer currently committed for a domain (empty if new). No assoc arrays (bash 3.2 on macOS).
issuer_for() {
  local q="$1" i=0
  for d in ${EXIST_DOMAINS[@]+"${EXIST_DOMAINS[@]}"}; do
    [ "$d" = "$q" ] && { printf '%s' "${EXIST_ISSUERS[$i]}"; return; }
    i=$((i+1))
  done
}
in_existing() { local q="$1" d; for d in ${EXIST_DOMAINS[@]+"${EXIST_DOMAINS[@]}"}; do [ "$d" = "$q" ] && return 0; done; return 1; }

# === 3. WIPE-or-ADD choice ===================================================
# Interactive; EOF/empty (bootstrap </dev/null) -> replace (.env is authoritative).
say "how to apply the .env domains?"
echo "    replace : callbackDomains becomes EXACTLY the .env list (drops domains not in .env)"
echo "    add     : merge the .env domains INTO the committed list (removes nothing)"
read -rp "  [replace/add] (default replace): " MODE || true
case "$(printf '%s' "${MODE:-}" | tr 'A-Z' 'a-z' | tr -d '[:blank:]')" in
  add|a)        MODE=add ;;
  replace|r|"") MODE=replace ;;
  *) warn "unrecognized answer '${MODE}', defaulting to replace"; MODE=replace ;;
esac
ok "mode: ${MODE}"

# === 4. build the final ordered domain list ==================================
FINAL=()
if [ "$MODE" = add ]; then
  FINAL=( ${EXIST_DOMAINS[@]+"${EXIST_DOMAINS[@]}"} )              # keep all existing, in order
  for d in "${ENV_DOMAINS[@]}"; do in_existing "$d" || FINAL+=("$d"); done
else
  FINAL=( "${ENV_DOMAINS[@]}" )                                   # exactly the .env list
fi

# === 5. write callbackDomains (preserve existing issuers; new -> staging) ====
say "writing ${#FINAL[@]} domain(s) into ${LIB_VALUES}"
if yq -i '.ingressEdge.callbackDomains = []' "$LIB_VALUES"; then :; else bad "yq failed to reset callbackDomains"; fi
for d in "${FINAL[@]}"; do
  iss="$(issuer_for "$d")"; [ -n "$iss" ] || iss="$DEFAULT_ISSUER"
  if D="$d" I="$iss" yq -i '.ingressEdge.callbackDomains += [{"domain": strenv(D), "issuer": strenv(I)}]' "$LIB_VALUES"; then
    ok "${d}  (issuer: ${iss})"
  else
    bad "${d}: yq failed to append"
  fi
done

# === 6. verify round-trip ====================================================
say "verify"
GOT="$(yq -r '.ingressEdge.callbackDomains[].domain' "$LIB_VALUES" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
WANT="$(printf '%s ' "${FINAL[@]}" | sed 's/ $//')"
[ "$GOT" = "$WANT" ] && ok "callbackDomains == ${GOT}" || bad "callbackDomains is '${GOT}', expected '${WANT}'"

# === 7. summary ==============================================================
AUTH_SUBDOMAIN="$(yq -r '.ingressEdge.oidc.authSubdomain' "$LIB_VALUES" 2>/dev/null)"; [ -n "$AUTH_SUBDOMAIN" ] && [ "$AUTH_SUBDOMAIN" != null ] || AUTH_SUBDOMAIN="google-sso"
summary
if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
ingressEdge.callbackDomains now: ${GOT}
Single source of truth: .env SSO_CALLBACK_DOMAINS -> argo_apps/_lib/ingress-edge/values.yaml (ArgoCD renders it).

Next:
  - For any NEW domain, register its redirect URI on the ONE Google OAuth client, EXACTLY:
$(for d in "${FINAL[@]}"; do echo "      https://${AUTH_SUBDOMAIN}.${d}/oauth2/callback"; done)
    and add the apex under the consent screen's "Authorized domains". (07_google_sso.sh reprints these.)
  - Run ./07_google_sso.sh (writes the shared clientID + seals the client secret) if you haven't yet.
  - git add -A && git commit && git push   # ArgoCD (wave 4) stands up each google-sso.<domain> callback host.
  - New domains start on ${DEFAULT_ISSUER}; flip that callbackDomains entry (and each app ingress) to
    letsencrypt-prod once its callback cert issues. See 07_ingress.md ("Adding an SSO domain").
EOF
else
  echo "Something failed, see above. Fix and re-run (idempotent)."
fi
[ "$FAIL" -eq 0 ]
