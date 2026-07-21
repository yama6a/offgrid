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
| `Chart.yaml`         | the argo-cd chart version, declared as a dependency on argo-helm.    |
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
  finds. Their sync-waves order CREATION only (a 5s `ARGOCD_SYNC_WAVE_DELAY`, set in `01_argocd` values): it creates `platform` (wave 0),
  then `workloads` (wave 1). It does NOT wait for platform health — see below.
  - **No Application health gate (deliberate).** ArgoCD ships no built-in health assessment for
    `argoproj.io/Application`, so a parent app-of-apps sees its child Applications as health-less and a
    wave never waits on child health. We used to restore it via
    `resource.customizations.health.argoproj.io_Application` to make the wave-0 → wave-1 gate wait — but that gate
    proved fragile: a child that transiently reports Degraded/Progressing **latches a stale health status** (a
    quiescent Synced app only recomputes health on the `timeout.reconciliation` poll — there is no separate
    health-refresh), which froze the whole tree ~9 min per wave and stretched a cold boot to ~51 min. So the gate
    is gone. Ordering is now eventual: `workloads` is created while the platform may still be coming up, and a
    workload whose platform CRD isn't registered yet fails its sync and self-converges via **unbounded**
    `syncPolicy.retry` (`limit: -1`, `refresh: true`), typically within ~1-2 min. Only within-operation retry
    re-drives a failed sync (selfHeal and the poll do NOT — verified against ArgoCD), which is why every
    app's `retry.limit` is `-1`.
- Each child Application points at a wrapper chart under its own tree's `charts/`.
- Add a platform app = drop a wrapper chart under `argo_apps/platform/charts/NN_name/` + an Application manifest under
  `argo_apps/platform/apps/NN_name.yaml`, then commit & push. (The `NN` prefix is the app's `sync-wave` number, keep
  the filename, the chart dir, and the annotation in agreement. See the convention below.)
- Add a workload = drop a wrapper chart under `argo_apps/workloads/charts/name/` + an Application manifest under
  `argo_apps/workloads/apps/name.yaml`, no number, no `sync-wave`. Workloads all reconcile in parallel (they race
  the platform and retry-converge; there is no health gate). (If a workload depends on another workload, it belongs in platform instead.)

### Removing or renaming an app: the `resources-finalizer`

Every Application manifest in this repo — the root-of-roots, both roots, and every `platform/apps/**` +
`workloads/apps/**` leaf — carries:

```yaml
metadata:
  finalizers:
    - resources-finalizer.argocd.argoproj.io
```

This exists because of a subtle two-level trap in the app-of-apps model. Deleting or renaming an app touches
*two* different mechanisms, and only one of them cleans up:

- **`syncPolicy.automated.prune`** prunes resources *within a live app* when they leave that app's rendered
  manifests. It says nothing about what happens to an app's resources when the *Application object itself* is
  deleted — and a deleted Application has no sync loop left to prune anything.
- Whether deleting an Application also deletes everything it deployed is governed **only** by the
  `resources-finalizer.argocd.argoproj.io` finalizer. With it, deletion is *cascading*: ArgoCD deletes the app's
  managed resources first, then removes the finalizer, then the object goes. **Without it, deletion is
  non-cascading** — ArgoCD just removes the Application and leaves its resources running, unmanaged.

When you rename a wrapper chart or drop an app from a tree, the parent (root or a root) prunes the *child
Application object* — that part works. But without the finalizer on that child, its Kubernetes resources are
orphaned, not deleted. This bit us when merging the two RabbitMQ apps into one: renaming the operator's Helm
release (`rabbitmq-operator` → `rabbitmq`) changed every operator-subchart resource name, so the old app's
Deployments + `ValidatingWebhookConfiguration` weren't re-adopted by the new app — they were left running by a
now-deleted Application, and the duplicate `failurePolicy: Fail` webhook blocked all topology-CR admissions
cluster-wide. (Resources whose name *doesn't* change — the `RabbitmqCluster` CR, a workload's `Cluster` — get
re-adopted by the renamed app and survive fine; it's the release-named resources that orphan.)

The finalizer on every app makes removal/rename self-cleaning, and it propagates through the tree: deleting the
root-of-roots cascades to the two roots, which cascade to every leaf. Two things to know:

- **Teardown needs the controller alive.** The finalizer is processed by the argocd application-controller, so
  deleting an app while the controller is gone (mid-teardown, or the `argocd` app itself) leaves it stuck
  `Terminating`. Clear it with `kubectl -n argocd patch app <name> --type=merge -p
  '{"metadata":{"finalizers":[]}}'`. A full cluster wipe (`DANGEROUS_reset_talos_cluster.sh`) removes the OS
  underneath anyway, so this only matters for a targeted app delete on a live cluster.
- It changes nothing during normal sync — the finalizer is inert until the Application is actually deleted.

### sync-wave convention (within the platform tree)

Ordering across platform apps is `argocd.argoproj.io/sync-wave` (lower = earlier). Since there is no Application
health gate (see above), a wave no longer WAITS for the prior wave to be Healthy — waves only order the CREATION
of the child Application objects (5s apart). That head-start still helps (CRD/operator apps get applied before
their consumers), but it is advisory: an app that races ahead of a CRD it needs simply fails and retries until the
CRD lands. The `NN` prefix on each `platform/apps/NN_*.yaml` file equals its wave number, one glance at the dir
listing tells you the order.

The gap is `ARGOCD_SYNC_WAVE_DELAY`, set to `5` (seconds) via the `controller.sync.wave.delay.seconds` param in
`argo_apps/platform/charts/01_argocd/values.yaml` (`configs.params`) — a head-start buffer, not a readiness gate
(it's a fixed timer; retry is what actually guarantees CRD-before-consumer). Controller-wide, so it also spaces
resource-level waves inside every chart.

- Cilium = wave `0`. The CNI underpins everything, so it's created first.
- ArgoCD = wave `1`. Adopts the already-running, self-managed ArgoCD.
- Later platform apps go at wave `2`+, created after the CNI + engine.
- Keep every app auto-syncing with `retry: -1` + `refresh: true` so it self-converges. Without the health gate an
  OutOfSync/Degraded app no longer stalls later waves or the roots — but auto-sync + unbounded retry is still the
  only thing that recovers it, so a manual-sync app would just never converge on its own. (The old "never put a
  manual app at an earlier wave than its dependents" rule is obsolete: waves don't gate on health anymore.)
- Caveat: if you break-glass-fix Cilium out of band and don't commit the fix, `selfHeal` reverts it on the next
  reconcile. Always commit the fix back to git.

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
- `global.networkPolicy.create` pinned `false`. The chart defaults it `true`, which renders standard k8s NetworkPolicy
  objects (the server's is `ingress: - {}`, allow-all). Cilium enforces those too and UNIONs them with our own
  default-deny CiliumNetworkPolicy for the argocd namespace (the chart's `templates/networkpolicy.yaml`), so an
  allow-all NP would blow the default-deny open on this cluster-admin/git-creds namespace. Cilium is the sole policy
  engine here, so we opt back out. See [04_networking.md](04_networking.md).
- UI over port-forward for now. `server.insecure: true` serves plain HTTP, so no TLS to fumble through a port-forward.
  Cilium's LB-IPAM is live (step 04) and the Envoy Gateway ingress lands later, so a `LoadBalancer` Service or Gateway
  is an option later (see [Exposure](#exposure-the-argocd-ui-behind-google-sso) below); flip `server.insecure` to
  `false` and front it with TLS if you ever terminate TLS at ArgoCD instead of the Gateway.

## Roll-forward only: `revisionHistoryLimit: 0` everywhere

Recovery here is always **roll-forward** — a git revert re-synced by Argo — never `argocd app rollback` or
`kubectl rollout undo`. So the retained revision history every resource keeps by default (10 Argo
`status.history` entries; 10 old ReplicaSets/ControllerRevisions per workload) is pure dead weight: orphaned
ReplicaSets pile up and Argo carries rollback state nobody uses. We disable it by setting
`revisionHistoryLimit: 0` in three layers:

1. **Every `Application`** (`argo_apps/root.yaml`, `roots/*.yaml`, `platform/apps/**`, `workloads/apps/**`) sets
   `spec.revisionHistoryLimit: 0` — no Argo rollback history.
2. **Every first-party workload** we template sets it on the workload `spec` — the 3 sample-app Deployments,
   `05_ntfy`, `02_local_path_provisioner`, `04_google_sso` callbacks (Deployments), and `02_nic_keeper`
   (DaemonSet → `ControllerRevision` history).
3. **Upstream charts** set it via their values knob where one exists: `01_argocd` (`global.` **and**
   `controller.` — the controller StatefulSet ignores global's `0` because Helm's `default` treats `0` as
   empty), `02_cert_manager` (`global.` — v1.21.0 applies it to all 3 Deployments), `02_metrics_server`,
   `03_rabbitmq` (both operators), `05_grafana`, and `05_victoria_metrics_k8s_stack` (VMSingle + VMAgent CRs via
   `spec.revisionHistoryLimitCount` — note the different field name — plus the `kube-state-metrics` +
   `prometheus-node-exporter` subcharts).

**Documented exceptions (no silent caps).** The repo is pure-Helm (no kustomize/postRenderer), and adding one
just to force this would break the clean wrapper pattern, so these workloads stay at the k8s default of 10:

- **No `revisionHistoryLimit` value at all:** cilium, envoy-gateway (gateway-helm), victoria-metrics-operator,
  cloudnative-pg, longhorn, redis-operator, victoria-logs-collector.
- **Knob exists but `0` is silently dropped** (template guards with `{{- if … }}`, and `0` is falsy in Helm):
  **sealed-secrets** — any non-zero value works, `0` does not.
- **Vendored verbatim:** the `03_barman_cloud_plugin` plugin Deployment lives in a re-`curl`ed upstream
  manifest marked *DO NOT EDIT BY HAND* — a hand-edit would be erased on the next re-vendor, so it's left alone.

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
  `timeout.reconciliation`: `false` (default) → `300s` (a 5-minute net for a dropped webhook), `true` → `60s` (fast
  poll). `08_argocd_webhook.sh` writes it into `01_argocd/values.yaml` — that file is the single source ArgoCD
  reads, so don't hand-edit `timeout.reconciliation`, flip the `.env` knob and re-run the script. We keep the
  `300s` default (not `60s`): the poll re-drives *OutOfSync* apps and recomputes stale health, but it does NOT
  re-drive a *failed* sync — that's `syncPolicy.retry`'s job (`limit: -1`) — so a faster poll wouldn't speed
  cold-boot convergence, and it costs controller CPU that scales with object count. We also don't use `0s` (fully
  off): a lost webhook would then never recover, and `0s` also needs `ARGOCD_DEFAULT_CACHE_EXPIRATION` tuned.
- **The webhook secret is generated, not configured.** `08_argocd_webhook.sh` mints a random shared secret,
  writes the plaintext to `secrets/argocd-github-webhook-secret.txt` (the gitignored off-repo store — paste it
  into GitHub) and seals it into `argocd-secret`'s `webhook.github.secret` key. Re-running reuses the stored value
  (idempotent), so the secret you configured in GitHub keeps working; delete the file to rotate.
- **`createSecret: false` + a *seeded*, then *merged*, `argocd-secret`.** ArgoCD reads `webhook.github.secret`
  only from the Secret named `argocd-secret`. We set `configs.secret.createSecret: false` so the chart doesn't
  own that Secret (otherwise ArgoCD self-heal would fight the key we merge in). The catch: `argocd-server` reads
  `argocd-secret` at startup and **fatals if it's absent** (it only *populates* `server.secretkey`/TLS into a
  secret that already exists — it does not reliably create it on a cold cluster). With `createSecret: false`
  nothing else creates it before boot, so `05_argocd.sh` **seeds an empty `argocd-secret` before the Helm
  install**; `argocd-server` then writes its own `server.secretkey` into it. The webhook key arrives separately:
  the wave-3 `argocd-webhook-secret` app seals in **patch mode** (`sealedsecrets.bitnami.com/patch: "true"`),
  which *merges* `webhook.github.secret` in and leaves `server.secretkey` intact. Patch mode only works if the
  **live** Secret already carries that annotation (the controller checks the existing object, not the
  SealedSecret template), so `05_argocd.sh` sets it on the seeded secret up front — in both bootstrap and rebuild.
- **The sealed secret lives in a *separate* wave-3 app, not the wave-1 argocd chart.** The `SealedSecret`
  (`bitnami.com/v1alpha1`) is delivered by `argo_apps/platform/charts/03_argocd_webhook_secret/` (app
  `03_argocd_webhook_secret`, wave 3), **not** the `01_argocd` chart. If it lived in the argocd chart,
  `05_argocd.sh`'s imperative `helm upgrade --install` — and the wave-1 self-heal — would try to render it on a
  **cold** cluster *before* the sealed-secrets controller installs its CRD at wave 2, so helm aborts with
  `no matches for kind "SealedSecret"` and the whole bootstrap wedges (this bit a from-scratch rebuild once).
  Wave 3 is the first slot strictly after sealed-secrets (wave 2); `argocd-secret` already exists by then
  (argocd-server, wave 1) and has been annotated patch-managed, so the merge just works. `08_argocd_webhook.sh`
  writes the sealed manifest into that wave-3 chart.
- **Bootstrap nudge.** With the poll relaxed to 300s and no GitHub webhook yet (it needs public DNS + the prod
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

Delivered purely by ArgoCD as one host of the consolidated platform-ingress app (sync-wave 6, app
`argo_apps/platform/apps/06_platform_ingress.yaml`, chart `argo_apps/platform/charts/06_platform_ingress/`):
its own `:443` `Gateway` (named `argocd-ops-example-com`, from the hostname) + a cross-namespace `HTTPRoute` to
`argocd-server` + a `ReferenceGrant`, plus a SAN entry on the platform ingress's shared `platform-tls` cert,
all rendered by the shared `ingress` library. ArgoCD is untouched — it keeps `server.insecure: true` and
serves plain HTTP on `argocd-server:80`; the Gateway terminates TLS.

Gating is central: `argocd.ops.example.com` is listed in `04_google_sso` `domains[].hosts` with its allowlist, so
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
- **`/api/webhook` bypasses SSO by design.** A second `HTTPRoute` (`argocd-ops-example-com-webhook`, in
  `06_platform_ingress/templates/argocd-webhook-route.yaml`) matches only the Exact path `/api/webhook` on the
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
