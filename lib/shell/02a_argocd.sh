#!/usr/bin/env bash
# Installs ArgoCD, the LAST component installed imperatively: it then manages itself and every later app from
# argo_apps/. Installs the wrapper chart by hand, then applies argo_apps/root.yaml so ArgoCD adopts the same
# release and self-manages from git. No versions or values live here. Idempotent: re-run safely.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---- knobs ----
CHART_DIR="${PLATFORM_CHARTS}/01_argocd"     # the wrapper chart (Argo consumes it too)
ROOT_APP="${REPO_ROOT}/argo_apps/root.yaml"  # the root-of-roots (recurses argo_apps/roots/)
RELEASE="argocd"
NS="argocd"
REPO_ARGO="https://argoproj.github.io/argo-helm"
HELM_TIMEOUT="8m"                            # 3x Pi 5 image pulls can be slow

# ---- functions ----

check_prerequisites() {
  say "prerequisites"
  require kubectl helm yq
  [ -f "${CHART_DIR}/Chart.yaml" ] || die "no chart at ${CHART_DIR} (expected argo_apps/platform/charts/01_argocd)"
  [ -f "${ROOT_APP}" ] || die "no root app at ${ROOT_APP}"
  use_kubeconfig
  assert_api
  kubectl -n kube-system get ds/cilium >/dev/null 2>&1 || die "Cilium not found, run step 04 (01_cilium.sh) first"
  ok "kubectl + helm present, API reachable, chart + root app found, Cilium up"
}

vendor_argocd_subchart() {
  local lock_before=0
  say "helm dependency build (${CHART_DIR})"
  [ -f "${CHART_DIR}/Chart.lock" ] && lock_before=1
  helm repo add argo "$REPO_ARGO" >/dev/null 2>&1 || true
  helm repo update argo >/dev/null 2>&1 || helm repo update >/dev/null
  # build wants an existing Chart.lock; update generates one. Try build, fall back to update.
  if helm dependency build "$CHART_DIR" >/dev/null 2>&1 || helm dependency update "$CHART_DIR" >/dev/null 2>&1; then
    ok "argo-cd subchart vendored under charts/"
  else
    bad "helm dependency build/update failed (see: helm dependency build ${CHART_DIR})"
  fi
  if [ "$lock_before" -eq 0 ] && [ -f "${CHART_DIR}/Chart.lock" ]; then
    say "NOTE: Chart.lock was just generated, COMMIT it"
    echo "   ArgoCD's repo-server runs 'helm dependency build', which REQUIRES a committed Chart.lock."
    echo "   git add ${CHART_DIR#${REPO_ROOT}/}/Chart.lock"
  fi
}

# argocd-server READS argocd-secret at startup and fatals if it is absent; it only POPULATES server.secretkey
# into a Secret that already exists. The chart runs createSecret:false so self-heal cannot fight the webhook
# key merged in later, and on a COLD cluster nothing else creates it in time (the sealed webhook secret is
# merge-only and its controller is a later wave). So seed an EMPTY one, create-if-absent: a re-run must NEVER
# overwrite the server.secretkey argocd-server generated.
# The label makes ArgoCD's secret informer watch it; the annotation is what lets the merge happen later, and
# the controller checks it on the LIVE Secret, not on the SealedSecret.
seed_argocd_secret() {
  say "seeding argocd-secret (argocd-server needs it at startup; chart is createSecret:false)"
  # The namespace must exist first: helm's --create-namespace fires too late for this.
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
}

# Release name and namespace MUST match argo_apps/platform/apps/01_argocd.yaml so the self-managed Application
# adopts THIS release with no churn. --reset-values recomputes from the chart each run.
install_argocd() {
  say "helm upgrade --install ${RELEASE} (namespace ${NS})"
  # die, not bad: a failure here means the namespace was never created, so every later step would cascade into
  # FAILs that bury the real cause. Abort so the helm error is the last thing on screen.
  if helm upgrade --install "$RELEASE" "$CHART_DIR" --namespace "$NS" \
       --create-namespace --reset-values --wait --timeout "$HELM_TIMEOUT"; then
    ok "argocd release applied"
  else
    die "helm install failed (see output above; re-run is safe/idempotent)"
  fi
}

wait_for_argocd_workloads() {
  say "waiting for ArgoCD workloads"
  kubectl -n "$NS" rollout status statefulset/argocd-application-controller --timeout=180s >/dev/null 2>&1 \
    && ok "application-controller ready" || bad "application-controller not ready"
  kubectl -n "$NS" rollout status deploy/argocd-repo-server --timeout=180s >/dev/null 2>&1 \
    && ok "repo-server ready" || bad "repo-server not ready"
  kubectl -n "$NS" rollout status deploy/argocd-server --timeout=180s >/dev/null 2>&1 \
    && ok "server ready" || bad "server ready"
}

# repoURL is written by 04_values.sh, which runs before the bootstrap's commit+push, so by here it is already
# committed. Asserted rather than rewritten: a mismatch means 04 was skipped and ArgoCD would reconcile the
# wrong remote.
assert_root_repo_url() {
  local got
  [ -n "$REPO_URL" ] || die "REPO_URL is empty, set it in .env"
  got="$(yq -r '.spec.source.repoURL' "$ROOT_APP" 2>/dev/null)"
  [ "$got" = "$REPO_URL" ] \
    && ok "root repoURL == ${REPO_URL}" \
    || bad "root repoURL is '${got}', expected '${REPO_URL}'. Run \`make configure-values\`, commit and push first"
}

# ArgoCD clones the PUSHED repo, so local-only changes are invisible to the root app. No exemption: nothing
# here writes to the tree any more, so a dirty argo_apps/ is always a real problem.
assert_tree_pushed() {
  local ahead
  [ -n "$REPO_ROOT" ] || return 0
  [ -n "$(git -C "$REPO_ROOT" status --porcelain -- argo_apps lib/helm 2>/dev/null)" ] \
    && bad "uncommitted changes under argo_apps/ or lib/helm/, commit & push them, then re-run"
  ahead="$(git -C "$REPO_ROOT" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
  [ "${ahead:-0}" -gt 0 ] \
    && bad "${ahead} unpushed commit(s) on the current branch, push them, then re-run (ArgoCD only sees pushed commits)"
  return 0
}

# A repo-creds credential template, whose url is a PREFIX match. Set to the FULL repo URL rather than the
# github.com/<user> prefix, so it scopes to exactly this repo. Seeded before the root app.
# An empty token means anonymous HTTPS, fine for a public repo. forceHttpBasicAuth sends the PAT preemptively
# even on a public repo, so polling git ls-remote gets the authenticated rate limit instead of the anonymous one.
seed_git_credential() {
  say "git credential (single-repo PAT)"
  if [ -z "$ARGOCD_GITHUB_PAT_SECRET" ]; then
    echo "   ARGOCD_GITHUB_PAT_SECRET empty in .env -> ArgoCD clones ${REPO_URL} anonymously (fine for a PUBLIC repo)"
    return 0
  fi
  # username: GitHub authenticates off the PAT (password) and ignores this, but Basic Auth needs it non-empty,
  # so it is hardcoded. For a non-GitHub remote that DOES use it, set it here.
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
}

apply_root_app() {
  say "handing off to GitOps (kubectl apply root)"
  kubectl apply -f "$ROOT_APP" >/dev/null 2>&1 && ok "root applied" || bad "kubectl apply root failed"
}

# Only confirms the handoff took, i.e. that the root-of-roots created the platform tree. Deliberately NOT a
# health wait: the sealed-secret-backed apps stay Degraded until the master key is restored, which is a LATER
# step, so blocking on health here would deadlock the bootstrap.
confirm_gitops_handoff() {
  local csync _
  say "confirming GitOps handoff (root created the platform tree)"
  for _ in $(seq 1 60); do kubectl -n "$NS" get application platform >/dev/null 2>&1 && break; sleep 2; done
  if kubectl -n "$NS" get application platform >/dev/null 2>&1; then
    ok "handoff confirmed: root created the platform tree (converges async; key restore + converge come next)"
  else
    bad "root did not create the platform app in ~120s (check: kubectl -n ${NS} get applications)"
  fi
  csync="$(kubectl -n "$NS" get application cilium -o jsonpath='{.status.sync.status}' 2>/dev/null)"
  echo "   app/cilium sync status: ${csync:-<not created yet>}  (expected Synced, auto-adopted, no pod churn)"
}

# No login: the local admin account is disabled and the anonymous user is admin (01_argocd/values.yaml
# configs.cm/rbac), so a port-forward drops straight into the UI. Day-to-day access is the SSO edge; this
# port-forward is the break-glass that bypasses the Gateway + SSO.
print_access() {
  say "ArgoCD access"
cat <<EOF
   UI via port-forward (no ingress yet; server runs plain HTTP, no login, anonymous is admin):
     kubectl -n ${NS} port-forward svc/argocd-server 8080:80
     open http://localhost:8080   (lands in as admin, no username/password)
   Day-to-day: https://argocd.<domain> behind Google SSO (platform-ingress).
   All apps auto-adopt their running releases, nothing to click.
EOF
}

print_result() {
  if [ "$FAIL" -ne 0 ]; then
    echo "Some checks failed. If helm timed out, re-run (idempotent). If apps show ComparisonError,"
    echo "confirm argo_apps/** (incl. Chart.lock) is committed AND pushed to origin, then re-run."
    return 0
  fi
cat <<EOF
ArgoCD is up and self-managed from argo_apps/platform/charts/01_argocd/. The root-of-roots
(argo_apps/root.yaml) watches argo_apps/roots/ and creates the platform root, then the workloads root ~5s
later (no health wait; both converge async via retry). Add a PLATFORM app under argo_apps/platform/{charts,apps}/ (NN_ = sync-wave);
add a WORKLOAD under argo_apps/workloads/{charts,apps}/ (no number, no wave). See 02_gitops.md.
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
