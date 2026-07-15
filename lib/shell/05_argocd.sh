#!/usr/bin/env bash
#
# 05_argocd.sh  (macOS)
#
# Installs ArgoCD, the GitOps engine, on the cluster from step 03, networked by step 04
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
# Uses NATIVE helm + kubectl (errors out if either is missing), like 04_cilium.sh, unlike the
# dockerized talos-phase scripts (03a-03e). Talks to the cluster via the step-03 kubeconfig.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ------------------------------------------------------------------
CHART_DIR="${REPO_ROOT}/argo_apps/platform/charts/01_argocd"    # the wrapper chart (Argo consumes it too)
ROOT_APP="${REPO_ROOT}/argo_apps/root.yaml"        # the root-of-roots (recurses argo_apps/roots/)
RELEASE="argocd"
NS="argocd"
REPO_ARGO="https://argoproj.github.io/argo-helm"
HELM_TIMEOUT="8m"                                  # 3x Pi 5 image pulls can be slow
# REPO_URL (the repo ArgoCD polls) + ARGOCD_GITHUB_PAT_SECRET (the repo-creds PAT) are config/secret in .env.
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
# ArgoCD (and everything else) needs Cilium's pod network, step 04 must have run.
kubectl -n kube-system get ds/cilium >/dev/null 2>&1 || die "Cilium not found, run step 04 (04_cilium.sh) first"
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
  say "NOTE: Chart.lock was just generated, COMMIT it"
  echo "   ArgoCD's repo-server runs 'helm dependency build', which REQUIRES a committed Chart.lock."
  echo "   git add ${CHART_DIR#${REPO_ROOT}/}/Chart.lock"
fi

# === 1b. seed argocd-secret so argocd-server can start =======================
# argocd-server READS argocd-secret at startup (account init + settings) and fatals "secret argocd-secret
# not found" if it's absent — it only *populates* server.secretkey/TLS into a secret that already exists.
# The chart is createSecret:false (values.yaml, so ArgoCD self-heal can't fight the webhook key we merge in),
# and on a COLD cluster nothing else creates argocd-secret before argocd-server boots: the sealed webhook
# secret is patch-mode (merge-only, never creates) and its controller is a later wave. So argocd-server
# crashloops and `helm --wait` times out. Seed an EMPTY argocd-secret here, up front: argocd-server fills in
# server.secretkey on boot, and the wave-3 sealed secret MERGES webhook.github.secret in later. Needs the ns
# first (helm's --create-namespace only fires during the install, too late for this). create-if-absent: a
# re-run must NEVER overwrite the server.secretkey argocd-server generated. Label so ArgoCD's secret informer
# watches it; annotate patch-managed so the sealed webhook secret is allowed to merge (the controller checks
# the annotation on the LIVE secret, not the SealedSecret template). See 05_gitops.md (Webhook-driven sync).
say "seeding argocd-secret (argocd-server needs it at startup; chart is createSecret:false)"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 \
  && ok "namespace ${NS} present" || bad "could not ensure namespace ${NS}"
if kubectl -n "$NS" get secret argocd-secret >/dev/null 2>&1; then
  ok "argocd-secret already exists (left as-is; server.secretkey preserved)"
else
  kubectl -n "$NS" create secret generic argocd-secret >/dev/null 2>&1 \
    && ok "argocd-secret seeded (empty; argocd-server fills server.secretkey on boot)" \
    || bad "could not seed argocd-secret (argocd-server will crashloop without it)"
fi
kubectl -n "$NS" label secret argocd-secret app.kubernetes.io/part-of=argocd --overwrite >/dev/null 2>&1 || true
kubectl -n "$NS" annotate secret argocd-secret sealedsecrets.bitnami.com/patch=true --overwrite >/dev/null 2>&1 \
  && ok "argocd-secret labelled part-of=argocd + annotated patch-managed" \
  || warn "could not annotate/label argocd-secret; annotate it by hand or the webhook merge is refused"

# === 2. install / upgrade ArgoCD =============================================
# Release name + namespace MUST match argo_apps/platform/apps/01_argocd.yaml so the self-managed
# Application adopts THIS release (no churn). --reset-values recomputes from the chart's
# values.yaml each run (same reasoning as 04_cilium.sh).
say "helm upgrade --install ${RELEASE} (namespace ${NS})"
# die (not bad): this install is a hard prerequisite for everything below. If it fails, the namespace was
# never created and steps 3/4 would each cascade into confusing FAILs that bury the real cause. Abort
# here so the helm error is the last thing on screen. Re-run is safe/idempotent. (A SealedSecret in this
# chart used to fail the render on a cold cluster before the wave-2 CRD existed; that secret now lives in
# its own wave-3 app, argo_apps/platform/charts/03_argocd_webhook_secret/. See 05_gitops.md.)
if helm upgrade --install "$RELEASE" "$CHART_DIR" --namespace "$NS" \
     --create-namespace --reset-values --wait --timeout "$HELM_TIMEOUT"; then
  ok "argocd release applied"
else
  die "helm install failed (see output above; re-run is safe/idempotent)"
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
# under argo_apps/ in the PUBLIC repo, they must be committed AND pushed first, or the apps show
# a ComparisonError ("path does not exist"). Re-running this script after pushing is safe.
say "handing off to GitOps (kubectl apply root)"

# The repo ArgoCD polls comes from .env (REPO_URL); pin it into root.yaml below.
[ -n "$REPO_URL" ] || die "REPO_URL is empty, set it in .env"
# Idempotent: a no-op when the URL already matches. Only the root-of-roots, the child roots under
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
# (no prompt, re-run after pushing, it's idempotent): flag uncommitted changes under argo_apps/ or the
# shared lib/helm/ charts it resolves (file:// deps), and any committed-but-unpushed commits on the branch.
if [ -n "$REPO_ROOT" ]; then
  [ -n "$(git -C "$REPO_ROOT" status --porcelain -- argo_apps lib/helm 2>/dev/null)" ] \
    && bad "uncommitted changes under argo_apps/ or lib/helm/, commit & push them, then re-run"
  ahead="$(git -C "$REPO_ROOT" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
  [ "${ahead:-0}" -gt 0 ] \
    && bad "${ahead} unpushed commit(s) on the current branch, push them, then re-run (ArgoCD only sees pushed commits)"
fi

# Optional git credential. Seeded out-of-band here, before the root app, as an ArgoCD repo-creds
# credential template (secret-type: repo-creds), whose url is a PREFIX-match. We set it to the FULL
# repo $REPO_URL (not the github.com/<user> prefix) so it scopes to exactly this repo, our PAT is
# fine-grained and only authorizes this one repo. Empty token => anonymous HTTPS (fine for a PUBLIC
# repo). forceHttpBasicAuth makes ArgoCD send the PAT preemptively even though the repo is public,
# so polling git ls-remote is AUTHENTICATED (5000/h rate limit, not the 60/h anonymous one). The
# app's repoURL just has to start with this url, it equals it, so no inline repo Secret is needed.
# See 05_gitops.md.
say "git credential (single-repo PAT)"
# The PAT comes from the gitignored .env (ARGOCD_GITHUB_PAT_SECRET); nothing is prompted. For a PRIVATE repo
# it should be a fine-grained, READ-ONLY, single-repo PAT (Contents: Read-only, nothing else). Mint one
# at https://github.com/settings/personal-access-tokens/new. Empty => anonymous HTTPS (PUBLIC repo only).
if [ -n "$ARGOCD_GITHUB_PAT_SECRET" ]; then
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
  password: ${ARGOCD_GITHUB_PAT_SECRET}
  forceHttpBasicAuth: "true"
EOF
  then ok "repository credential seeded (upsert) for ${REPO_URL}"
  else bad "could not seed repository credential"
  fi
else
  echo "   ARGOCD_GITHUB_PAT_SECRET empty in .env -> ArgoCD clones ${REPO_URL} anonymously (fine for a PUBLIC repo)"
fi

kubectl apply -f "$ROOT_APP" >/dev/null 2>&1 && ok "root applied" || bad "kubectl apply root failed"

# === 5. confirm the GitOps handoff ===========================================
# argocd itself is already up (the rollout-status checks above). Here we ONLY confirm the handoff took: the
# root-of-roots created the platform tree. We do NOT wait for any app's Synced+Healthy here:
#   - there is no argoproj.io/Application health gate, so the platform now comes up fast (waves are advisory),
#     but full convergence (incl. the workloads that race the platform then retry) is still async;
#   - the sealed-secret-backed apps (argocd-webhook-secret, google-sso, grafana, CNPG backup creds) stay
#     Degraded until the sealed-secrets master key is restored, which happens in the NEXT rebuild step (07),
#     AFTER this one. Blocking on health here would deadlock the bootstrap.
# So full convergence is async: the rebuild orchestrator's converge step drives it after the key restore; on a
# standalone `make install-argocd`, watch `kubectl -n argocd get applications -w`.
say "confirming GitOps handoff (root created the platform tree)"
for _ in $(seq 1 60); do kubectl -n "$NS" get application platform >/dev/null 2>&1 && break; sleep 2; done
if kubectl -n "$NS" get application platform >/dev/null 2>&1; then
  ok "handoff confirmed: root created the platform tree (converges async; key restore + converge come next)"
else
  bad "root did not create the platform app in ~120s (check: kubectl -n ${NS} get applications)"
fi
csync=$(kubectl -n "$NS" get application cilium -o jsonpath='{.status.sync.status}' 2>/dev/null)
echo "   app/cilium sync status: ${csync:-<not created yet>}  (expected Synced, auto-adopted, no pod churn)"

# === 6. access + summary =====================================================
# No login: the local admin account is disabled and the anonymous user is admin (01_argocd/values.yaml
# configs.cm/rbac), so a port-forward drops straight into the UI. Day-to-day access is the SSO edge
# (the consolidated platform-ingress app, wave 6); this port-forward is the break-glass that bypasses the
# Gateway + SSO.
say "ArgoCD access"
cat <<EOF
   UI via port-forward (no ingress yet; server runs plain HTTP, no login — anonymous is admin):
     kubectl -n ${NS} port-forward svc/argocd-server 8080:80
     open http://localhost:8080   (lands in as admin, no username/password)
   Day-to-day: https://argocd.<domain> behind Google SSO (platform-ingress).
   All apps auto-adopt their running releases, nothing to click.
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
