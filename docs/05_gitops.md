# GitOps: ArgoCD

The cluster from [step 03](03_operating_system.md) is networked by [step 04](04_networking.md) (Cilium). ArgoCD
is the next and last component installed imperatively, from here on, everything is GitOps. ArgoCD manages
itself from a wrapper chart in this repo, adopts the already-running Cilium, and becomes the delivery path for
every later app (the [`nic-keeper` recovery DaemonSet](03_operating_system.md), etcd snapshots, monitoring, Longhorn,
workloads). `05_argocd.sh` does the one-time bootstrap.

The single source of truth is the wrapper Helm chart at `argo_apps/platform/charts/01_argocd/`. `05_argocd.sh` just
installs that chart by hand, then hands off to git: ArgoCD adopts the same release (same chart, namespace, release name,
values, so Argo sees it in-sync rather than fighting it) and self-manages from then on. Nothing (no version, no values)
is defined in the script. The chart:

| Path                 | Holds                                                                                          |
|----------------------|------------------------------------------------------------------------------------------------|
| `Chart.yaml`         | the argo-cd chart version (`9.6.0`, ArgoCD `v3.4.4`), declared as a dependency on argo-helm.    |
| `values.yaml`        | the HA-lite values (under the `argo-cd:` key), see below.                                       |
| `Chart.lock`         | pins the resolved dependency; must be committed (ArgoCD's repo-server needs it, see below).     |

## The `argo_apps/` app-of-apps model: two trees, gated

```
argo_apps/
  root.yaml              # the ROOT-OF-ROOTS (applied once by 05_argocd.sh); recurses roots/
  roots/
    0_platform.yaml      #   Application "platform"  (sync-wave 0), recurses platform/apps
    1_workloads.yaml     #   Application "workloads" (sync-wave 1), recurses workloads/apps
  platform/
    apps/                #   one Application per platform app (numbered = wave)
      00_cilium.yaml     #     adopts Cilium      (auto-sync, selfHeal+prune), wave 0
      01_argocd.yaml     #     ArgoCD self-manage (automated),               wave 1
    charts/              #   the wrapper charts those Applications point at
      00_cilium/         #     step 04's chart
      01_argocd/         #     this step's chart
  workloads/
    apps/                #   one Application per workload (un-numbered, wave-less)
      sample_workload.yaml
    charts/
      sample_workload/   #     the sample app + its CNPG Postgres + open/SSO ingress
```

- `root.yaml` is the root-of-roots: it recurses `argo_apps/roots/` and manages the two child root Applications it
  finds. Their sync-waves gate the bootstrap: it creates `platform` (wave 0), waits for it to be Healthy (which
  aggregates the health of every platform app), then creates `workloads` (wave 1). So workloads never reconcile
  against missing CRDs/namespaces on a cold boot.
- Each child Application points at a wrapper chart under its own tree's `charts/`.
- Add a platform app = drop a wrapper chart under `argo_apps/platform/charts/NN_name/` + an Application manifest under
  `argo_apps/platform/apps/NN_name.yaml`, then commit & push. (The `NN` prefix is the app's `sync-wave` number, keep
  the filename, the chart dir, and the annotation in agreement. See the convention below.)
- Add a workload = drop a wrapper chart under `argo_apps/workloads/charts/name/` + an Application manifest under
  `argo_apps/workloads/apps/name.yaml`, no number, no `sync-wave`. Workloads all reconcile in parallel once platform
  is Healthy. (If a workload depends on another workload, it belongs in platform instead.)

### sync-wave convention (within the platform tree)

Ordering across platform apps is `argocd.argoproj.io/sync-wave` (lower = earlier; the platform root waits for a wave to be
Synced + Healthy before creating the next). The `NN` prefix on each `platform/apps/NN_*.yaml` file equals its wave
number, one glance at the dir listing tells you the order. The single platform -> workloads boundary is enforced once, by
the wave on the two roots, not by per-app waves.

- Cilium = wave `0`. The CNI underpins everything, so it goes first. This is only safe because the Cilium app
  auto-syncs: it reaches Healthy on its own, the wave clears, and the root proceeds. A manual app at wave 0 would
  start OutOfSync and stall forever, blocking the root from ever creating the later-wave apps (including
  `argocd`). That's the trap to avoid: never put a manual-sync app at an earlier wave than apps that depend on it. The
  same rule scales up to the roots: a perpetually-OutOfSync platform app keeps the `platform` root from going Healthy,
  which stalls the `workloads` root forever, so keep every platform app auto-syncing.
- ArgoCD = wave `1`. Adopts the already-running, self-managed ArgoCD once the CNI is in.
- Later platform apps go at wave `2`+, so they reconcile after the platform (CNI + engine) is in place.
- Caveat: if you break-glass-fix Cilium out of band and don't commit the fix, its app sits OutOfSync at wave 0 and
  can block later waves on the next root sync. Always commit the fix back to git.

## HA-lite: sized for 3x 8 GB Pis

ArgoCD is not in the data path of running apps: once an app is synced it runs regardless of Argo, so a few seconds of
no reconciliation is fine. We spend the RAM only where an outage would actually hurt:

| Component                  | Setting                          | Why                                                                       |
|----------------------------|----------------------------------|---------------------------------------------------------------------------|
| application-controller     | 1 replica                        | the reconciler; a singleton that self-heals on restart.                   |
| redis                      | single (`redis-ha.enabled:false`)| only a cache, rebuilds in seconds on restart. (redis-ha = ~5 extra pods.) |
| repo-server                | 2 replicas + PDB                 | manifest generation; kept up across a node drain.                         |
| server (API/UI)            | 2 replicas + PDB                 | the UI/API; kept up across a node drain.                                  |
| applicationSet-controller  | 2 replicas                       | leader-elected; 2 for fast failover (drop to 1 if RAM gets tight).        |
| dex, notifications         | disabled                         | no SSO, no notifications yet, 2 fewer pods.                               |

The 2-replica components carry `global.topologySpreadConstraints` (`maxSkew 1`, `kubernetes.io/hostname`,
`DoNotSchedule`), over 3 nodes that forces each pair onto two distinct nodes. Singletons satisfy it trivially.

## Decision notes

- Git auth = anonymous by default; single-repo PAT for private repos. The repo (`yama6a/offgrid`) is
  public, so ArgoCD clones it anonymously over HTTPS, no secret needed. To run this project against a private
  repo (or to lift the anonymous git rate limit), `05_argocd.sh` seeds a read-only PAT before hand-off. See
  [Git auth](#git-auth) below for the how + why-imperative.
- Cilium auto-syncs with full `selfHeal` + `prune` (the same posture as every leaf), chosen for convenience even
  though it's the one app that can cut Argo (and the cluster) off its own network, the circular dependency called out
  in [04_networking.md](04_networking.md). Auto-sync gives hands-off upgrades; the knowingly-accepted danger is that
  `selfHeal: true` reverts an out-of-band break-glass fix (`04_cilium.sh`) unless you commit it to git fast, and
  `prune: true` cascade-deletes any resource/CRD dropped from the chart. The price: a bad Cilium change pushed to git
  applies unattended AND is self-healed in place, mind your pushes, and after any break-glass commit the fix back to
  git before `selfHeal` drags it back. First sync auto-adopts the running release with no pod churn, because the
  chart's `values.yaml` already commits `loadBalancer.enabled: true`, so Argo's rendered desired state matches live.
- `Chart.lock` must be committed for any wrapper chart with dependencies. ArgoCD's repo-server renders charts with
  `helm dependency build`, which requires the lock. `00_cilium` already has one; `01_argocd`'s is generated on the
  first run of `05_argocd.sh` (`helm dependency update`), commit it before the `argocd` app reconciles (the script
  reminds you).
- UI over port-forward for now. `server.insecure: true` serves plain HTTP, so no TLS to fumble through a port-forward.
  Cilium's LB-IPAM is live (step 04) and the Envoy Gateway ingress lands later, so a `LoadBalancer` Service or Gateway
  is an option later (see [Exposure](#exposure-the-argocd-ui-behind-google-sso) below); flip `server.insecure` to
  `false` and front it with TLS if you ever terminate TLS at ArgoCD instead of the Gateway.

## Git auth

This repo is public, so ArgoCD clones it anonymously over HTTPS, no credential needed by default. Anonymous
`git ls-remote` is git smart-HTTP, not the REST API, so even the fast-poll setting stays well under GitHub's
limits — but sync is webhook-driven now and the poll is only a slow fallback (see
[Webhook-driven sync](#webhook-driven-sync-and-the-poll-fallback) below).

For a private repo (or to lift the anonymous rate limit), `05_argocd.sh` seeds a credential: at hand-off it reads
`ARGOCD_GITHUB_PAT_SECRET` (a fine-grained, read-only, single-repo PAT) from the gitignored `.env` — leave it empty for a
public repo — then creates an ArgoCD `repository` Secret (labelled `argocd.argoproj.io/secret-type: repository`, with
`url` == the polled `repoURL`) before it applies the root app.

```text
# Create the PAT first: GitHub -> Settings -> Developer settings -> Fine-grained tokens
#   Repository access: Only select repositories -> this repo
#   Permissions: Repository -> Contents -> Read-only   (nothing else)
# Put it in .env:  ARGOCD_GITHUB_PAT_SECRET="github_pat_..."   (gitignored; empty = anonymous clone)
# Then run the script (no prompt):
lib/shell/05_argocd.sh
```

Why the credential is seeded imperatively (and not via sealed-secrets). A private repo's clone credential cannot
live in that repo, ArgoCD needs it for the first clone (chicken-and-egg). On bare metal there's no cloud identity to
fall back on, so exactly one secret must be seeded out-of-band at bootstrap; the script's `kubectl apply` of the
`repository` Secret is that seed (same role as the kubeconfig). Sealed-secrets does not remove this step: its
controller decrypts `SealedSecret`s, but getting the repo `SealedSecret` into the cluster still needs either an ArgoCD
clone (deadlock) or a manual apply (the same out-of-band seed, with extra indirection). So the repo credential is seeded
directly, and sealed-secrets is reserved for app/cluster secrets later (GitOps-managed, wave 1+), optionally
mirroring the repo credential for rebuild DR. Least privilege: single-repo, `Contents: Read-only`; rotate by
re-running with a new token. A GitHub App is the upgrade path if you outgrow a PAT.

## Webhook-driven sync (and the poll fallback)

ArgoCD detects new commits one of two ways: it **polls** git on `timeout.reconciliation`, or a git **webhook**
pushes it a `POST /api/webhook` on every push (refreshes in seconds instead of waiting out the poll). We run
webhook-driven, with the poll demoted to a slow safety net.

- **Poll = slow fallback, toggled from `.env`.** `POLL_SYNC_ENABLED` in `.env` drives
  `timeout.reconciliation`: `false` (default) → `3600s` (a 1 h net for a dropped webhook), `true` → `60s` (fast
  poll). `08_argocd_webhook.sh` writes it into `01_argocd/values.yaml` — that file is the single source ArgoCD
  reads, so don't hand-edit `timeout.reconciliation`, flip the `.env` knob and re-run the script. We deliberately
  don't use `0s` (fully off): a lost webhook would then never recover, and `0s` also needs
  `ARGOCD_DEFAULT_CACHE_EXPIRATION` tuned.
- **The webhook secret is generated, not configured.** `08_argocd_webhook.sh` mints a random shared secret,
  writes the plaintext to `secrets/argocd-github-webhook-secret.txt` (the gitignored off-repo store — paste it
  into GitHub) and seals it into `argocd-secret`'s `webhook.github.secret` key. Re-running reuses the stored value
  (idempotent), so the secret you configured in GitHub keeps working; delete the file to rotate.
- **`createSecret: false` + a *merged* sealed `argocd-secret`.** ArgoCD reads `webhook.github.secret` only from
  the Secret named `argocd-secret`. We set `configs.secret.createSecret: false` so the chart doesn't own that
  Secret (otherwise ArgoCD self-heal would fight the key we merge in). But `argocd-server` auto-creates
  `argocd-secret` (with its own `server.secretkey`) during the wave-1 bootstrap, *before* the wave-2
  sealed-secrets controller exists — and the controller refuses to overwrite a Secret it didn't create. So we seal
  in **patch mode** (`sealedsecrets.bitnami.com/patch: "true"`): it *merges* `webhook.github.secret` in and leaves
  `server.secretkey` intact. Patch mode only works if the **live** Secret already carries that annotation (the
  controller checks the existing object, not the SealedSecret template), so `05_argocd.sh` annotates the live
  `argocd-secret` right after ArgoCD rolls out — in both bootstrap and rebuild.
- **Bootstrap nudge.** With the poll demoted to 3600s and no GitHub webhook yet (it needs public DNS + the prod
  cert), `DANGEROUS_bootstrap_cluster.sh` hard-refreshes every Application after its final push so the re-sealed
  secrets apply immediately instead of after the fallback. On a live cluster, refresh the `argocd` app (or wait
  out the fallback) after pushing.

Set up the GitHub webhook (once, after the cluster is reachable on its prod cert):

```text
# 1) Seal the secret + set the poll cadence (writes secrets/argocd-github-webhook-secret.txt):
make configure-argocd-webhook          # == lib/shell/08_argocd_webhook.sh
git add -A && git commit -m "argocd: github webhook sync" && git push

# 2) GitHub repo -> Settings -> Webhooks -> Add webhook:
#      Payload URL      : https://argocd.<domain>/api/webhook
#      Content type     : application/json
#      Secret           : the contents of secrets/argocd-github-webhook-secret.txt
#      SSL verification : ENABLED   (needs the letsencrypt-PROD cert on argocd.<domain>)
#      Events           : Just the push event
# 3) Push a trivial commit and watch it refresh in seconds:
kubectl -n argocd get applications -w
```

The `/api/webhook` path reaches ArgoCD **without** passing Google SSO — that bypass, and why it's safe, is in
[07_ingress.md](07_ingress.md#bypassing-sso-for-a-path-the-argocd-webhook) and the Exposure note below.

## Exposure: the ArgoCD UI behind Google SSO

The bootstrap reaches the UI over port-forward (above). For day-to-day access the UI is exposed through
its own Gateway (folded onto the one Envoy via `mergeGateways`), fronted by the same Google SSO built in
[07_ingress.md](07_ingress.md#google-sso). The Google gate decides who can reach the UI; ArgoCD's OWN
login is turned off — the anonymous user is admin and the local admin account is disabled
(`argo_apps/platform/charts/01_argocd/values.yaml`, `configs.cm`/`rbac`), no Dex/OIDC — so whoever clears
Google lands straight in as admin (one login, not two). The SSO gate is the only auth boundary in front of
the UI, which is why it must be the sole path: the port-forward break-glass below now also lands in as
admin with no login. The **one** deliberate exception is `POST /api/webhook` (the git webhook), which is
served by a separate ungated route (see below) — it carries no session and is authenticated instead by the
GitHub HMAC signature ArgoCD checks against `webhook.github.secret`, so it can't reach the UI/API.

Delivered purely by ArgoCD as one host of the consolidated platform-ingress app (sync-wave 8, app
`argo_apps/platform/apps/08_platform_ingress.yaml`, chart `argo_apps/platform/charts/08_platform_ingress/`):
its own `:443` `Gateway` (named `argocd-example-com`, from the hostname) + a cross-namespace `HTTPRoute` to
`argocd-server` + a `ReferenceGrant`, plus a SAN entry on the platform ingress's shared `platform-tls` cert,
all rendered by the shared `ingress-edge` library. ArgoCD is untouched — it keeps `server.insecure: true` and
serves plain HTTP on `argocd-server:80`; the Gateway terminates TLS.

Gating is central: `argocd.example.com` is listed in `04_google_sso` `domains[].hosts` with its allowlist, so
the domain's one `SecurityPolicy` targetRefs its route and gates it — sharing the `google-sso.<domain>`
callback + `cookieDomain` with the other platform UIs, no new Google redirect URI, no new policy. To expose a
new platform UI: add its edge to the platform ingress `hosts:` list AND list its host in `04_google_sso`.

Decisions worth keeping:

- **`logoutPath` moved off `/logout`.** Envoy Gateway's OIDC filter defaults its logout to `/logout`,
  which ArgoCD itself uses. The SSO policy sets `logoutPath: /oauth2/sign_out` so the gate doesn't swallow
  ArgoCD's `/logout`. (One field on the shared policy; harmless for other apps under it.)
- **Break-glass = port-forward.** The Google gate blocks the `argocd` CLI, which speaks gRPC and can't run
  the browser OIDC flow. Keep using `kubectl -n argocd port-forward svc/argocd-server 8080:80` for the CLI
  — it also bypasses the Gateway and the SSO gate entirely, so a broken route/policy never locks you out.
- **`/api/webhook` bypasses SSO by design.** A second `HTTPRoute` (`argocd-example-com-webhook`, in
  `08_platform_ingress/templates/argocd-webhook-route.yaml`) matches only the Exact path `/api/webhook` on the
  same host/Gateway and — because the `04_google_sso` `SecurityPolicy` targets routes by exact *name* — is never
  gated. Safe because ArgoCD verifies the GitHub HMAC on that path; the Exact match means nothing else escapes SSO
  (critical, since anonymous is admin). Details in [07_ingress.md](07_ingress.md#bypassing-sso-for-a-path-the-argocd-webhook).
- **On the prod cert.** The whole platform ingress now issues `letsencrypt-prod` (not staging): GitHub's webhook
  SSL verification against `argocd.<domain>` needs a publicly-trusted cert. Mind the prod ACME rate limits when
  re-issuing.

Self-management caveat: ArgoCD manages the app that exposes ArgoCD, so a bad push is reverted by selfHeal
and port-forward is the escape hatch if you ever wedge it.

## What `05_argocd.sh` does

Uses native `helm` + `kubectl` (errors out if either is missing), like `04_cilium.sh`, unlike the dockerized
talos-phase scripts (03a-03e). Talks to the cluster via `secrets/kubeconfig`. Idempotent.

1. Prereqs: `kubectl`/`helm` present, kubeconfig reachable, the chart + root app exist, and Cilium is up (the
   GitOps layer needs a working pod network).
2. Vendors the argo-cd subchart: `helm dependency build` (falls back to `helm dependency update`, which generates
   `Chart.lock` on first run, commit it).
3. `helm upgrade --install argocd argo_apps/platform/charts/01_argocd -n argocd --create-namespace --reset-values --wait`,
   release `argocd` / namespace `argocd` so the self-managed Application adopts THIS release.
4. Waits for the controller / repo-server / server to roll out.
5. Hands off: resolves the repo to poll (`$REPO_URL`, else the git `origin` remote as a prompt default) and pins it
   into `root.yaml`; optionally seeds an `ARGOCD_GITHUB_PAT_SECRET` repository credential from `.env` (see [Git auth](#git-auth)); then,
   after a "did you push?" check (ArgoCD reads git, not local disk), `kubectl apply` the root app. The root creates
   `cilium` (wave 0) which auto-adopts, then `argocd` (wave 1) which self-adopts, both Synced, no clicks.
6. Waits for `root` + `argocd` to be Synced/Healthy, then prints the port-forward command (no login —
   anonymous is admin, local admin disabled).

```bash
# 1) generate + commit the argo-cd Chart.lock (first time only), commit the new files, and PUSH:
helm dependency update argo_apps/platform/charts/01_argocd
git add argo_apps 05_gitops 03_operating_system.md && git commit -m "step 05: ArgoCD" && git push

# 2) bootstrap:
lib/shell/05_argocd.sh

# 3) reach the UI (no login — anonymous is admin, local admin disabled):
kubectl -n argocd port-forward svc/argocd-server 8080:80
#    then open http://localhost:8080, all apps auto-adopt, nothing to click.
```

## Caveats

- Run order: 04 before 05. ArgoCD (and CoreDNS, and every workload) needs Cilium's pod network; the script refuses to
  run if `ds/cilium` is absent.
- Push before you hand off. ArgoCD clones the public repo, anything not committed and pushed is invisible to the
  root app, which then shows `ComparisonError: path does not exist`. The script prompts; re-running after pushing is
  safe (`ASSUME_PUSHED=1` skips the prompt).
- Self-management is real. Once the `argocd` app is Synced, changes to `argo_apps/platform/charts/01_argocd/values.yaml`
  are applied by ArgoCD to itself on push. A bad value can disrupt ArgoCD briefly; it self-heals, and `05_argocd.sh`
  remains break-glass (re-run to force the release back to the chart).
- The leftover Helm release secret (`sh.helm.release.v1.argocd.*` in `argocd`) from the by-hand install is harmless;
  once the app is adopted you may delete it.

## Troubleshooting

- `argocd` app stuck `ComparisonError` / "app path does not exist" -> the files aren't on the remote. Commit & push
  `argo_apps/**` (incl. `Chart.lock`), then re-sync.
- `argocd` app `OutOfSync` with a `helm dependency build` error -> `Chart.lock` isn't committed (or is stale). Run
  `helm dependency update argo_apps/platform/charts/01_argocd`, commit the lock, re-sync.
- `cilium` app `OutOfSync` -> it auto-syncs with `selfHeal`, so a transient OutOfSync is normally dragged straight
  back to the git state (a break-glass `04_cilium.sh` fix NOT yet in git gets reverted — commit it fast). A persistent
  OutOfSync means Argo can't sync at all (`Chart.lock`/CRD/path issues); fix those and it reconciles.
- `server`/`repo-server` pods pending -> the `DoNotSchedule` topology spread needs 2 schedulable nodes free; check
  `kubectl -n argocd get pods -o wide` and node pressure (Longhorn/monitoring not yet installed, so this is rare now).
- No login prompt (expected) -> the anonymous user is admin and the local admin account is disabled
  (`01_argocd` `configs.cm`: `users.anonymous.enabled` + `admin.enabled: "false"`, `rbac.policy.default:
  role:admin`). To restore password login, set `admin.enabled: "true"` and push, or break-glass
  `kubectl -n argocd edit cm argocd-cm`.

## Reading the script output

`[PASS]`/`[FAIL]` per check, then `summary: N passed, M failed` (exit non-zero on any fail). A clean run ends with `root`
`argocd`, and `cilium` all Synced/Healthy (everything auto-adopts).
