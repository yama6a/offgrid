#!/usr/bin/env bash
#
# 05_argocd.sh  (macOS)
#
# Installs ArgoCD — the GitOps engine — on the cluster from step 03, networked by step 04
# (Cilium). This is the LAST component installed imperatively: ArgoCD then manages itself and
# every later app from argo_apps/. One-time bootstrap; re-run safe (helm upgrade --install).
#
# SINGLE SOURCE OF TRUTH is the wrapper chart at argo_apps/platform/charts/01_argocd/:
#   - Chart.yaml  pins the argo-cd chart version (dependency on argoproj/argo-helm)
#   - values.yaml holds the HA-lite values (under the `argo-cd:` key)
# This script just installs THAT chart by hand, then applies argo_apps/root.yaml so ArgoCD
# adopts the same release and self-manages from git. No versions or values live here. See 05_gitops.md.
#
# What it does:
#   1. vendors the argo-cd subchart (helm dependency build; generates Chart.lock on first run)
#   2. helm upgrade --install argocd  (release "argocd", namespace "argocd")
#   3. waits for the ArgoCD pods to roll out
#   4. applies the app-of-apps root  ->  cilium (wave 0) then argocd (wave 1) auto-adopt their releases
#   5. waits for root + argocd to be Synced/Healthy and prints UI access
#
# Uses NATIVE helm + kubectl (errors out if either is missing) — like 04_cilium.sh, unlike the
# dockerized talos-phase scripts (03a–03e). Talks to the cluster via the step-03 kubeconfig.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# ---- knobs ------------------------------------------------------------------
CHART_DIR="${REPO_ROOT}/argo_apps/platform/charts/01_argocd"    # the wrapper chart (Argo consumes it too)
ROOT_APP="${REPO_ROOT}/argo_apps/root.yaml"        # the root-of-roots (recurses argo_apps/roots/)
RELEASE="argocd"
NS="argocd"
REPO_ARGO="https://argoproj.github.io/argo-helm"
HELM_TIMEOUT="8m"                                  # 3x Pi 5 image pulls can be slow
GIT_TOKEN=""                                       # PRIVATE-repo read-only PAT (the ONLY secret) — filled by the prompt below
# REPO_URL (the repo ArgoCD polls) is config — see .env.
# -----------------------------------------------------------------------------

# wait until an ArgoCD Application reports Synced + Healthy (or time out)
wait_app() {  # $1=app name  $2=timeout secs
  local app="$1" deadline; deadline=$(( $(date +%s) + ${2:-300} ))
  local s h
  while :; do
    s=$(kubectl -n "$NS" get application "$app" -o jsonpath='{.status.sync.status}'   2>/dev/null)
    h=$(kubectl -n "$NS" get application "$app" -o jsonpath='{.status.health.status}' 2>/dev/null)
    [ "$s" = "Synced" ] && [ "$h" = "Healthy" ] && { ok "app/${app}: Synced + Healthy"; return 0; }
    [ "$(date +%s)" -lt "$deadline" ] || { bad "app/${app}: not Synced+Healthy in time (last: ${s:-?}/${h:-?})"; return 1; }
    printf '.'; sleep 5
  done
}

# === 0. prereqs ==============================================================
say "prerequisites"
require kubectl helm
[ -f "${CHART_DIR}/Chart.yaml" ] || die "no chart at ${CHART_DIR} (expected argo_apps/platform/charts/01_argocd)"
[ -f "${ROOT_APP}" ] || die "no root app at ${ROOT_APP}"
use_kubeconfig
assert_api
# ArgoCD (and everything else) needs Cilium's pod network — step 04 must have run.
kubectl -n kube-system get ds/cilium >/dev/null 2>&1 || die "Cilium not found — run step 04 (04_cilium.sh) first"
ok "kubectl + helm present, API reachable, chart + root app found, Cilium up"

# === 1. resolve the argo-cd subchart =========================================
say "helm dependency build (${CHART_DIR})"
LOCK_BEFORE=0; [ -f "${CHART_DIR}/Chart.lock" ] && LOCK_BEFORE=1
helm repo add argo "$REPO_ARGO" >/dev/null 2>&1 || true
helm repo update argo >/dev/null 2>&1 || helm repo update >/dev/null
# build wants an existing Chart.lock; update generates one. Try build, fall back to update.
if helm dependency build "$CHART_DIR" >/dev/null 2>&1 || helm dependency update "$CHART_DIR" >/dev/null 2>&1; then
  ok "argo-cd subchart vendored under charts/"
else
  bad "helm dependency build/update failed (see: helm dependency build ${CHART_DIR})"
fi
if [ "$LOCK_BEFORE" -eq 0 ] && [ -f "${CHART_DIR}/Chart.lock" ]; then
  say "NOTE: Chart.lock was just generated — COMMIT it"
  echo "   ArgoCD's repo-server runs 'helm dependency build', which REQUIRES a committed Chart.lock."
  echo "   git add ${CHART_DIR#${REPO_ROOT}/}/Chart.lock"
fi

# === 2. install / upgrade ArgoCD =============================================
# Release name + namespace MUST match argo_apps/platform/apps/01_argocd.yaml so the self-managed
# Application adopts THIS release (no churn). --reset-values recomputes from the chart's
# values.yaml each run (same reasoning as 04_cilium.sh).
say "helm upgrade --install ${RELEASE} (namespace ${NS})"
if helm upgrade --install "$RELEASE" "$CHART_DIR" --namespace "$NS" \
     --create-namespace --reset-values --wait --timeout "$HELM_TIMEOUT"; then
  ok "argocd release applied"
else
  bad "helm install failed (see output above; re-run is safe/idempotent)"
fi

# === 3. wait for the ArgoCD workloads ========================================
say "waiting for ArgoCD workloads"
kubectl -n "$NS" rollout status statefulset/argocd-application-controller --timeout=180s >/dev/null 2>&1 \
  && ok "application-controller ready" || bad "application-controller not ready"
kubectl -n "$NS" rollout status deploy/argocd-repo-server --timeout=180s >/dev/null 2>&1 \
  && ok "repo-server ready" || bad "repo-server not ready"
kubectl -n "$NS" rollout status deploy/argocd-server --timeout=180s >/dev/null 2>&1 \
  && ok "server ready" || bad "server ready"

# === 4. hand off to GitOps ===================================================
# ArgoCD reads from GIT, not local disk. The root app (and the argocd self-app) point at paths
# under argo_apps/ in the PUBLIC repo — they must be committed AND pushed first, or the apps show
# a ComparisonError ("path does not exist"). Re-running this script after pushing is safe.
say "handing off to GitOps (kubectl apply root)"

# The repo ArgoCD polls comes from .env (REPO_URL); pin it into root.yaml below.
[ -n "$REPO_URL" ] || die "REPO_URL is empty — set it in .env"
# Idempotent: a no-op when the URL already matches. Only the root-of-roots — the child roots under
# argo_apps/roots/ AND every app under argo_apps/{platform,workloads}/apps/ also carry a repoURL; if
# you point at a fork, rewrite those too (see 05_gitops.md).
# Temp-file rewrite (no `sed -i`): portable across BSD sed and GNU sed (Homebrew gnu-sed on PATH).
RA_TMP="$(mktemp)" || die "mktemp failed"
if sed -E "s|^([[:space:]]*repoURL:[[:space:]]*).*|\1${REPO_URL}|" "$ROOT_APP" > "$RA_TMP" && mv "$RA_TMP" "$ROOT_APP"; then
  ok "root repoURL -> ${REPO_URL}"
else
  rm -f "$RA_TMP"
  bad "could not rewrite repoURL in ${ROOT_APP}"
fi

# ArgoCD clones the PUSHED repo, so local-only changes are invisible to the root app. Automatic guards
# (no prompt — re-run after pushing, it's idempotent): flag uncommitted changes under argo_apps/ or
# 05_gitops/, and any committed-but-unpushed commits on the current branch.
if [ -n "$REPO_ROOT" ]; then
  [ -n "$(git -C "$REPO_ROOT" status --porcelain -- argo_apps 05_gitops 2>/dev/null)" ] \
    && bad "uncommitted changes under argo_apps/ or 05_gitops/ — commit & push them, then re-run"
  ahead="$(git -C "$REPO_ROOT" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
  [ "${ahead:-0}" -gt 0 ] \
    && bad "${ahead} unpushed commit(s) on the current branch — push them, then re-run (ArgoCD only sees pushed commits)"
fi

# Optional git credential. Seeded out-of-band here — before the root app — as an ArgoCD repo-creds
# credential template (secret-type: repo-creds), whose url is a PREFIX-match. We set it to the FULL
# repo $REPO_URL (not the github.com/<user> prefix) so it scopes to exactly this repo — our PAT is
# fine-grained and only authorizes this one repo. Empty token => anonymous HTTPS (fine for a PUBLIC
# repo). forceHttpBasicAuth makes ArgoCD send the PAT preemptively even though the repo is public,
# so polling git ls-remote is AUTHENTICATED (5000/h rate limit, not the 60/h anonymous one). The
# app's repoURL just has to start with this url — it equals it — so no inline repo Secret is needed.
# See 05_gitops.md.
say "git credential (single-repo PAT)"
# Ask for the PAT interactively (hidden input) — the one secret this script prompts for.
if [ -z "$GIT_TOKEN" ]; then
  cat <<'EOF'
   For a PRIVATE repo, paste a fine-grained, READ-ONLY, single-repo PAT (leave empty for a PUBLIC
   repo -> anonymous clone). Create one at: https://github.com/settings/personal-access-tokens/new
     GitHub -> Settings -> Developer settings -> Fine-grained tokens -> Generate new token
       Repository access : Only select repositories -> this repo
       Permissions       : Contents (Repository) -> Read-only   (nothing else)
EOF
  printf '   GitHub PAT (hidden; empty = anonymous): '
  read -rs GIT_TOKEN </dev/tty 2>/dev/null || GIT_TOKEN=""   # non-interactive => anonymous
  echo
fi
if [ -n "$GIT_TOKEN" ]; then
  # username: GitHub authenticates off the PAT (password) and ignores this, but Basic Auth needs it
  # non-empty, so it's hardcoded. For a non-GitHub remote that DOES use it, set it here.
  if kubectl -n "$NS" apply -f - >/dev/null 2>&1 <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: repo-creds
  namespace: ${NS}
  labels:
    argocd.argoproj.io/secret-type: repo-creds
stringData:
  type: git
  url: ${REPO_URL}
  username: git
  password: ${GIT_TOKEN}
  forceHttpBasicAuth: "true"
EOF
  then ok "repository credential seeded (upsert) for ${REPO_URL}"
  else bad "could not seed repository credential"
  fi
else
  echo "   no PAT entered -> ArgoCD clones ${REPO_URL} anonymously (fine for a PUBLIC repo)"
fi

kubectl apply -f "$ROOT_APP" >/dev/null 2>&1 && ok "root applied" || bad "kubectl apply root failed"

# === 5. wait for self-management to settle ===================================
# Sync-wave order: cilium (wave 0) auto-adopts -> Healthy, then the root creates argocd (wave 1),
# which adopts itself. Both auto-sync, so no manual click is needed.
say "waiting for root + argocd to reconcile"
wait_app root   300
wait_app argocd 300
csync=$(kubectl -n "$NS" get application cilium -o jsonpath='{.status.sync.status}' 2>/dev/null)
echo "   app/cilium sync status: ${csync:-<not created yet>}  (expected Synced — auto-adopted, no pod churn)"

# === 6. access + summary =====================================================
say "ArgoCD access"
ADMIN_PW="$(kubectl -n "$NS" get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)"
cat <<EOF
   UI/CLI via port-forward (no ingress yet; server runs plain HTTP):
     kubectl -n ${NS} port-forward svc/argocd-server 8080:80
     open http://localhost:8080   (user: admin)
   admin password:
     ${ADMIN_PW:-<run: kubectl -n ${NS} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d>}
   All apps auto-adopt their running releases — nothing to click.
EOF

summary
if [ "$FAIL" -eq 0 ]; then
  cat <<EOF
ArgoCD is up and self-managed from argo_apps/platform/charts/01_argocd/. The root-of-roots
(argo_apps/root.yaml) watches argo_apps/roots/ and creates the platform root, then the workloads root
once platform is Healthy. Add a PLATFORM app under argo_apps/platform/{charts,apps}/ (NN_ = sync-wave);
add a WORKLOAD under argo_apps/workloads/{charts,apps}/ (no number, no wave). See 05_gitops.md.
EOF
else
  echo "Some checks failed. If helm timed out, re-run (idempotent). If apps show ComparisonError,"
  echo "confirm argo_apps/** (incl. Chart.lock) is committed AND pushed to origin, then re-run."
fi
[ "$FAIL" -eq 0 ]
