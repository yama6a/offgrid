#!/usr/bin/env bash
# Installs ArgoCD from its wrapper chart, then applies argo_apps/root.yaml. ArgoCD then adopts its own release
# and manages every later app from argo_apps/. No versions or values live here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
CHART_DIR="${PLATFORM_CHARTS}/01_argocd"    # the wrapper chart, which Argo CD also syncs
ROOT_APP="${REPO_ROOT}/argo_apps/root.yaml" # the root app, which syncs argo_apps/roots/
RELEASE="argocd"
NS="argocd"
REPO_ARGO="https://argoproj.github.io/argo-helm"
HELM_TIMEOUT="8m" # image pulls on three Pi 5 nodes can be slow

# ---- functions ----

check_prerequisites() {
  say "prerequisites"
  require kubectl helm yq
  [ -f "${CHART_DIR}/Chart.yaml" ] || die "no chart at ${CHART_DIR} (expected argo_apps/platform/charts/01_argocd)"
  [ -f "${ROOT_APP}" ] || die "no root app at ${ROOT_APP}"
  use_kubeconfig
  assert_api
  kubectl -n kube-system get ds/cilium > /dev/null 2>&1 || die "Cilium not found. Run 01_cilium.sh first."
  ok "kubectl and helm present, API reachable, chart and root app found, Cilium up"
}

vendor_argocd_subchart() {
  local lock_before=0
  say "helm dependency build (${CHART_DIR})"
  [ -f "${CHART_DIR}/Chart.lock" ] && lock_before=1
  helm repo add argo "$REPO_ARGO" > /dev/null 2>&1 || true
  helm repo update argo > /dev/null 2>&1 || helm repo update > /dev/null
  # build needs an existing Chart.lock. update generates one.
  if helm dependency build "$CHART_DIR" > /dev/null 2>&1 || helm dependency update "$CHART_DIR" > /dev/null 2>&1; then
    pin_chart_lock_timestamp "$CHART_DIR"
    ok "argo-cd subchart vendored under charts/"
  else
    bad "helm dependency build and update failed. Run: helm dependency build ${CHART_DIR}"
  fi
  if [ "$lock_before" -eq 0 ] && [ -f "${CHART_DIR}/Chart.lock" ]; then
    say "Chart.lock was generated. Commit it."
    echo "   The ArgoCD repo-server runs 'helm dependency build', which needs a committed Chart.lock."
    echo "   git add ${CHART_DIR#"${REPO_ROOT}"/}/Chart.lock"
  fi
}

# argocd-server exits at startup without argocd-secret, and the chart sets createSecret: false. Create it only
# if absent, so a re-run keeps the server.secretkey that argocd-server generated.
# The sealed-secrets controller checks the patch annotation on the live Secret before it merges the webhook key.
seed_argocd_secret() {
  say "seeding argocd-secret, which argocd-server needs at startup"
  # helm --create-namespace runs too late for this Secret.
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1 \
    && ok "namespace ${NS} present" || bad "could not ensure namespace ${NS}"
  if kubectl -n "$NS" get secret argocd-secret > /dev/null 2>&1; then
    ok "argocd-secret already exists. Left as is, so server.secretkey stays."
  else
    kubectl -n "$NS" create secret generic argocd-secret > /dev/null 2>&1 \
      && ok "argocd-secret seeded empty. argocd-server fills server.secretkey on boot." \
      || bad "could not seed argocd-secret. argocd-server crashloops without it."
  fi
  # Argo CD watches only Secrets labelled part-of=argocd.
  kubectl -n "$NS" label secret argocd-secret app.kubernetes.io/part-of=argocd --overwrite > /dev/null 2>&1 || true
  kubectl -n "$NS" annotate secret argocd-secret sealedsecrets.bitnami.com/patch=true --overwrite > /dev/null 2>&1 \
    && ok "argocd-secret labelled part-of=argocd and annotated for patch merge" \
    || warn "could not label or annotate argocd-secret. Annotate it by hand, or the webhook merge is refused."
}

# Release name and namespace must match argo_apps/platform/apps/templates/01_argocd.yaml.
# Then the ArgoCD Application adopts this release with no churn.
install_argocd() {
  say "helm upgrade --install ${RELEASE} (namespace ${NS})"
  # die, not bad: without the namespace every later check fails, and those failures bury the helm error.
  if helm upgrade --install "$RELEASE" "$CHART_DIR" --namespace "$NS" \
    --create-namespace --reset-values --wait --timeout "$HELM_TIMEOUT"; then
    ok "ArgoCD release applied"
  else
    die "helm install failed. See the output above. A re-run is safe."
  fi
}

wait_for_argocd_workloads() {
  say "waiting for ArgoCD workloads"
  kubectl -n "$NS" rollout status statefulset/argocd-application-controller --timeout=180s > /dev/null 2>&1 \
    && ok "application-controller ready" || bad "application-controller not ready"
  kubectl -n "$NS" rollout status deploy/argocd-repo-server --timeout=180s > /dev/null 2>&1 \
    && ok "repo-server ready" || bad "repo-server not ready"
  kubectl -n "$NS" rollout status deploy/argocd-server --timeout=180s > /dev/null 2>&1 \
    && ok "server ready" || bad "server not ready"
}

# 04_values.sh writes repoURL before the bootstrap commits and pushes. A mismatch here means 04 was skipped.
assert_root_repo_url() {
  local got
  [ -n "$REPO_URL" ] || die "REPO_URL is empty, set it in .env"
  got="$(yq -r '.spec.source.repoURL' "$ROOT_APP" 2> /dev/null)"
  [ "$got" = "$REPO_URL" ] \
    && ok "root repoURL is ${REPO_URL}" \
    || bad "root repoURL is '${got}', expected '${REPO_URL}'. Run \`make configure-values\`, then commit and push."
}

# ArgoCD clones the pushed repo, so it cannot see local changes.
assert_tree_pushed() {
  local ahead
  [ -n "$REPO_ROOT" ] || return 0
  [ -n "$(git -C "$REPO_ROOT" status --porcelain -- argo_apps lib/helm 2> /dev/null)" ] \
    && bad "uncommitted changes under argo_apps/ or lib/helm/. Commit and push them, then run this again."
  ahead="$(git -C "$REPO_ROOT" rev-list --count '@{u}..HEAD' 2> /dev/null || echo 0)"
  [ "${ahead:-0}" -gt 0 ] \
    && bad "${ahead} unpushed commit(s) on the current branch. ArgoCD sees only pushed commits. Push, then run this again."
  return 0
}

# A repo-creds url is a prefix match. The full repo URL scopes the PAT to this one repo.
# forceHttpBasicAuth sends the PAT on a public repo too, so git ls-remote polls get the authenticated rate limit.
seed_git_credential() {
  say "git credential for this repo"
  if [ -z "$ARGOCD_GITHUB_PAT_SECRET" ]; then
    echo "   ARGOCD_GITHUB_PAT_SECRET is empty in .env. ArgoCD clones ${REPO_URL} anonymously, which works for a public repo."
    return 0
  fi
  # GitHub ignores the username, but Basic Auth needs a non-empty one. Change it for a remote that uses it.
  if kubectl -n "$NS" apply -f - > /dev/null 2>&1 << EOF; then
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
    ok "repository credential applied for ${REPO_URL}"
  else
    bad "could not seed repository credential"
  fi
}

apply_root_app() {
  say "handing off to GitOps: kubectl apply root"
  kubectl apply -f "$ROOT_APP" > /dev/null 2>&1 && ok "root applied" || bad "kubectl apply root failed"
}

# No health wait: apps that use sealed secrets stay Degraded until a later step restores the master key.
confirm_gitops_handoff() {
  local csync _
  say "confirming that the root app created the platform tree"
  for _ in $(seq 1 60); do
    kubectl -n "$NS" get application platform > /dev/null 2>&1 && break
    sleep 2
  done
  if kubectl -n "$NS" get application platform > /dev/null 2>&1; then
    ok "handoff confirmed. The platform tree converges in the background. The key restore comes next."
  else
    bad "root did not create the platform app in 120s. Check: kubectl -n ${NS} get applications"
  fi
  csync="$(kubectl -n "$NS" get application cilium -o jsonpath='{.status.sync.status}' 2> /dev/null)"
  echo "   app/cilium sync status: ${csync:-<not created yet>}. Expected: Synced, adopted with no pod churn."
}

# 01_argocd/values.yaml disables the local admin and makes the anonymous user admin, so a port-forward needs no login.
print_access() {
  say "ArgoCD access"
  cat << EOF
   Break-glass UI via port-forward. Plain HTTP, no login, and the anonymous user is admin:
     kubectl -n ${NS} port-forward svc/argocd-server 8080:80
     open http://localhost:8080
   Day to day: https://argocd.<domain> behind Google SSO.
EOF
}

print_result() {
  if [ "$FAIL" -ne 0 ]; then
    echo "Some checks failed. If helm timed out, run this script again."
    echo "If apps show ComparisonError, commit and push argo_apps/ with its Chart.lock files, then run this again."
    return 0
  fi
  cat << EOF
ArgoCD is up and manages itself from argo_apps/platform/charts/01_argocd/.
argo_apps/root.yaml creates the platform root, then the workloads root about 5s later. Both converge by retry.
Add a platform app under argo_apps/platform/{charts,apps}/. Its NN_ prefix is its sync wave.
Add a workload under argo_apps/workloads/{charts,apps}/, with no number and no wave. See docs/02_gitops.md.
EOF
}

# ---- main ----

check_prerequisites
vendor_argocd_subchart
seed_argocd_secret
install_argocd
wait_for_argocd_workloads
assert_root_repo_url
assert_tree_pushed
seed_git_credential
apply_root_app
confirm_gitops_handoff
print_access

summary
print_result
[ "$FAIL" -eq 0 ]
