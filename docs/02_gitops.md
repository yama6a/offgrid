# GitOps: Argo CD

Argo CD is the last component installed imperatively. After it, everything is GitOps.

- Argo CD manages itself from a wrapper chart in this repo.
- It adopts the Cilium release that is already running.
- It delivers every later app.
- `02a_argocd.sh` does the one-time bootstrap.

The source of truth is `argo_apps/platform/charts/01_argocd/`. The script installs that chart by hand, then hands
off to git. Argo CD adopts the same release, with the same chart, namespace, release name and values. So Argo CD
sees it as in sync and does not fight it. The script holds no version and no value.

| Path                 | Holds                                                                                      |
|----------------------|--------------------------------------------------------------------------------------------|
| `Chart.yaml`         | the argo-cd chart, declared as a dependency on argo-helm                                    |
| `values.yaml`        | the HA-lite values under the `argo-cd:` key. See [HA-lite](#ha-lite-sized-for-3x-8-gb-pis) |
| `Chart.lock`         | the resolved dependency. Commit it, because Argo CD's repo-server needs it                  |

## The `argo_apps/` app-of-apps model: two trees

An **app of apps** is an Argo CD Application that renders other Applications. A **leaf** is an Application that
renders a chart of real resources.

```
argo_apps/
  root.yaml              # the root of roots, applied once by 02a_argocd.sh. It syncs roots/
  roots/
    0_platform.yaml      #   Application "platform"  (sync-wave 0), renders platform/apps
    1_workloads.yaml     #   Application "workloads" (sync-wave 1), renders workloads/apps
  platform/
    apps/                #   a chart: repoURL in values.yaml, one Application per app in templates/
      values.yaml        #     the one repoURL for this tree, written by 04_values.sh
      templates/
        00_cilium.yaml   #     adopts Cilium          (auto-sync, selfHeal and prune), wave 0
        01_argocd.yaml   #     Argo CD manages itself (automated),                    wave 1
    charts/              #   the wrapper charts those Applications point at
  workloads/
    apps/                #   same shape: values.yaml and templates/, with no number and no wave
      templates/
        sample_user_manager.yaml
    charts/
      sample_user_manager/   #  the sample app with its Postgres, Redis, messaging and ingress
```

`root.yaml` syncs `argo_apps/roots/` and manages the two child root Applications there.

- Their sync waves order creation only. `platform` is wave 0, `workloads` is wave 1.
- The waves are 5s apart. `ARGOCD_SYNC_WAVE_DELAY` in the `01_argocd` values sets the gap.
- `workloads` does not wait for `platform` to be healthy.

To add an app:

- **Platform app.** Add a wrapper chart under `argo_apps/platform/charts/NN_name/`. Add an Application manifest
  under `argo_apps/platform/apps/templates/NN_name.yaml`. Commit and push.
  - The `NN` prefix is the app's `sync-wave` number.
  - Keep the file name, the chart directory and the annotation in agreement.
- **Workload.** Add a wrapper chart under `argo_apps/workloads/charts/name/`. Add an Application under
  `argo_apps/workloads/apps/templates/name.yaml`.
  - No number and no `sync-wave`. All workloads reconcile in parallel.
  - If a workload depends on another workload, it belongs in platform.

### No Application health gate, deliberately

Argo CD has no built-in health check for `argoproj.io/Application`. So a parent app of apps sees its child
Applications as having no health, and a wave never waits for child health.

Do not add one with `resource.customizations.health.argoproj.io_Application`. That gate is fragile.

- A child that briefly reports Degraded or Progressing keeps that stale health status.
- A quiet, Synced app only recomputes health on the `timeout.reconciliation` poll. There is no separate health
  refresh.
- Measured on this cluster, the gate froze the whole tree for about 9 min per wave. A cold boot took about 51
  min.

So ordering is eventual:

- Argo CD creates `workloads` while the platform may still be coming up.
- A workload that needs a platform CRD that is not registered yet fails its sync.
- Unbounded `syncPolicy.retry` (`limit: -1`, `refresh: true`) then re-drives it. It typically converges in 1 to 2
  min.
- Only the retry inside a sync operation re-drives a failed sync. `selfHeal` and the poll do not. This was
  verified against Argo CD.
- So every app sets `retry.limit: -1`.

### Removing or renaming an app

Every Application manifest in this repo carries the resources finalizer. That covers the root of roots, both
roots, and every leaf under `platform/apps/**` and `workloads/apps/**`:

```yaml
metadata:
  finalizers:
    - resources-finalizer.argocd.argoproj.io
```

Deleting or renaming an app touches two mechanisms. Only one of them cleans up.

- **`syncPolicy.automated.prune`** deletes resources inside a live app when they leave that app's rendered
  manifests. It does nothing when the Application object itself is deleted. A deleted Application has no sync
  loop left to prune anything.
- **The finalizer** alone decides whether deleting an Application also deletes what it deployed.
  - With it, deletion cascades. Argo CD deletes the managed resources, then removes the finalizer, then the
    Application goes.
  - Without it, Argo CD removes the Application and leaves its resources running, unmanaged.

When you rename a wrapper chart or drop an app from a tree, the parent prunes the child Application. Without the
finalizer on that child, its Kubernetes resources stay behind as orphans.

Example: renaming an app also renames its Helm release.

- Every resource named after the release gets a new name. The new app does not adopt the old ones.
- The old Deployments and `ValidatingWebhookConfiguration` keep running, with no Application behind them.
- For the RabbitMQ operator, the leftover `failurePolicy: Fail` webhook blocks every topology CR admission in the
  cluster.
- Resources whose name does not change are adopted by the renamed app and survive.

The finalizer makes removal and rename clean up after themselves. It also propagates. Deleting the root of roots
cascades to the two roots, and they cascade to every leaf.

- **Teardown needs the controller alive.** The application-controller processes the finalizer.
  - If the controller is gone, the app stays stuck `Terminating`. This happens mid-teardown, or when you delete
    the `argocd` app itself.
  - Clear it with `kubectl -n argocd patch app <name> --type=merge -p '{"metadata":{"finalizers":[]}}'`.
  - A full cluster wipe removes the OS anyway. So this only matters for a targeted delete on a live cluster.
- **It changes nothing during a normal sync.** The finalizer does nothing until the Application is deleted.

### sync-wave convention

`argocd.argoproj.io/sync-wave` orders platform apps. A lower wave comes earlier.

- There is no Application health gate. So a wave does not wait for the prior wave to be Healthy.
- Waves only order the creation of the child Application objects, 5s apart.
- The head start still helps, because CRD and operator apps get applied before their consumers.
- But it is advisory. An app that races ahead of a CRD it needs fails, then retries until the CRD lands.
- The `NN` prefix on each `platform/apps/templates/NN_*.yaml` equals its wave number. The directory listing shows
  the order.

`ARGOCD_SYNC_WAVE_DELAY` sets the gap. `01_argocd/values.yaml` sets it to 5 seconds with the
`controller.sync.wave.delay.seconds` param.

- It is a fixed timer, not a readiness gate. Retry is what makes a CRD land before its consumer.
- It applies to the whole controller. So it also spaces resource-level waves inside every chart.

Wave assignments:

- **Wave 0: Cilium.** The CNI underpins everything, so Argo CD creates it first.
- **Wave 1: Argo CD.** It adopts the Argo CD that is already running.
- **Wave 2 and up: every later platform app.** Argo CD creates them after the CNI and itself.

Rules:

- Keep every app auto-syncing with `retry: -1` and `refresh: true`, so it converges.
  - With no health gate, an OutOfSync or Degraded app does not stall later waves or the roots.
  - But auto-sync with unbounded retry is still the only thing that recovers it. A manual-sync app would never
    converge on its own.
- If you fix Cilium out of band and do not commit the fix, `selfHeal` reverts it on the next reconcile. Always
  commit the fix to git.

## HA-lite: sized for 3x 8 GB Pis

**HA-lite** means: high availability only for the parts where an outage hurts. The cluster is 3 Pis with 8 GB of
RAM each.

Argo CD is not in the data path of running apps. A synced app runs with or without Argo CD. So a few seconds
without reconciliation is fine.

| Component                  | Setting                              | Why                                                                     |
|----------------------------|--------------------------------------|-------------------------------------------------------------------------|
| application-controller     | 1 replica                            | the reconciler. A singleton that heals itself on restart                |
| redis                      | single (`redis-ha.enabled: false`)   | only a cache. It rebuilds in seconds. redis-ha would add about 5 pods   |
| repo-server                | 2 replicas and a PDB                 | generates manifests. Stays up during a node drain                       |
| server (API and UI)        | 2 replicas and a PDB                 | the UI and API. Stays up during a node drain                            |
| applicationSet-controller  | 2 replicas                           | leader-elected. 2 for fast failover. Drop to 1 if RAM gets tight        |
| dex, notifications         | disabled                             | this repo uses neither, so 2 fewer pods                                 |

The 2-replica components carry `global.topologySpreadConstraints`: `maxSkew 1`, `kubernetes.io/hostname`,
`DoNotSchedule`. With 3 nodes, that forces each pair onto two different nodes. Singletons meet it by default.

## Decision notes

- **Git auth is anonymous by default.** The repo is public, so Argo CD clones it over HTTPS with no secret. For a
  private repo, or to lift the anonymous git rate limit, `02a_argocd.sh` seeds a read-only PAT before hand-off.
  See [Git auth](#git-auth).
- **Cilium auto-syncs with full `selfHeal` and `prune`, like every leaf.** This is for convenience. Cilium is still
  the one app that can cut Argo CD and the cluster off their own network.
  [01_networking.md](01_networking.md) describes that circular dependency.
  - Auto-sync gives hands-off upgrades.
  - `selfHeal: true` reverts an out-of-band fix unless you commit it quickly.
  - `prune: true` deletes any resource or CRD that leaves the chart.
  - A bad Cilium change pushed to git applies unattended, and `selfHeal` keeps it in place. Check every push.
  - The first sync adopts the running release with no pod restarts. The chart's `values.yaml` already commits
    `loadBalancer.enabled: true`, so the state Argo CD renders matches the live one.
- **Commit `Chart.lock` for every wrapper chart with a remote dependency.** Argo CD's repo-server renders with
  `helm dependency build`, which needs it. The first run of `02a_argocd.sh` generates the `01_argocd` lock and
  reminds you. Commit it before the `argocd` app reconciles.
- **`global.networkPolicy.create` is pinned to `false`.**
  - The chart defaults it to true, which renders standard Kubernetes NetworkPolicy objects.
  - The server's policy is `ingress: - {}`, which allows all traffic.
  - Cilium enforces those too, and unions them with this repo's default-deny policy for the `argocd` namespace.
  - That namespace holds cluster-admin and git credentials. An allow-all policy there would open the default-deny.
  - Cilium is the only policy engine here, so the chart's policies stay off.
- **The UI is reached over port-forward during bootstrap.** `server.insecure: true` serves plain HTTP, so there is
  no TLS to deal with through a port-forward. Set it to `false` and add TLS only if Argo CD itself ever terminates
  TLS instead of the Gateway. See [Exposure](#exposure-the-argo-cd-ui-behind-google-sso).

## Roll-forward only: `revisionHistoryLimit: 0` everywhere

Recovery is always roll-forward: a git revert that Argo CD syncs. It is never `argocd app rollback` or
`kubectl rollout undo`.

So the revision history every resource keeps by default is dead weight. That is 10 Argo CD `status.history`
entries, plus 10 old ReplicaSets or ControllerRevisions per workload. Orphaned ReplicaSets pile up, and Argo CD
carries rollback state nobody uses.

Three layers turn it off:

1. Every `Application` sets `spec.revisionHistoryLimit: 0`. That covers `root.yaml`, `roots/*.yaml`,
   `platform/apps/**` and `workloads/apps/**`.
2. Every first-party workload sets it on the workload `spec`:
   - the 3 sample-app Deployments
   - `05_ntfy`, `05_orphan_exporter`, `02_dead_node_watcher`
   - the `04_google_sso` callbacks
3. Upstream charts set it through their values knob, where one exists:
   - `01_argocd`, under both `global.` and `controller.`. The controller StatefulSet ignores the global `0`,
     because Helm's `default` treats `0` as empty.
   - `02_cert_manager`, under `global.`, which applies to all 3 Deployments.
   - `02_metrics_server`, `03_rabbitmq` for both operators, and `05_grafana`.
   - `05_victoria_metrics_k8s_stack`. The VMSingle and VMAgent CRs use a different field name,
     `spec.revisionHistoryLimitCount`. The `kube-state-metrics` and `prometheus-node-exporter` subcharts also set
     it.

The exceptions below keep the Kubernetes default of 10. The repo is pure Helm, with no kustomize and no
postRenderer. Adding one just to force this value would break the wrapper pattern.

| Exception | Why |
|---|---|
| cilium, envoy-gateway, victoria-metrics-operator, cloudnative-pg, longhorn, redis-operator, victoria-logs-collector | the chart has no `revisionHistoryLimit` value |
| sealed-secrets | the template guards the knob with `{{- if ... }}`, and `0` is falsy in Helm. Any non-zero value works, `0` does not |
| the `03_barman_cloud_plugin` Deployment | it lives in a vendored upstream manifest. A hand edit would be lost on the next re-vendor |

## Git auth

This repo is public, so Argo CD clones it anonymously over HTTPS with no credential.

- Anonymous `git ls-remote` uses git smart HTTP, not the REST API. So even the fast poll stays well under
  GitHub's limits.
- A webhook drives sync anyway. The poll is only a slow fallback.

For a private repo, or to lift the anonymous rate limit, `02a_argocd.sh` seeds a credential at hand-off:

- It reads `ARGOCD_GITHUB_PAT_SECRET` from the gitignored `.env`. That is a fine-grained, read-only PAT for this
  one repo. Leave it empty for a public repo.
- It creates the Argo CD Secret `repo-creds`, labelled `argocd.argoproj.io/secret-type: repo-creds`. This is a
  credential template, and Argo CD matches its `url` as a prefix.
- `url` is the full `REPO_URL`, not the `github.com/<user>` prefix. So the credential covers exactly this repo.
- It does this before it applies the root app.

```text
# Create the PAT first: GitHub > Settings > Developer settings > Fine-grained tokens
#   Repository access: Only select repositories, then pick this repo
#   Permissions: Repository > Contents > Read-only. Nothing else.
# Put it in .env, which is gitignored. Empty means an anonymous clone:
#   ARGOCD_GITHUB_PAT_SECRET="github_pat_..."
# Then run the script. It does not prompt:
lib/shell/02a_argocd.sh
```

The script seeds the credential imperatively, not through sealed-secrets:

- A private repo's clone credential cannot live in that repo. Argo CD needs it for the first clone.
- Bare metal has no cloud identity to fall back on. So exactly one secret must be seeded out of band at
  bootstrap. The script's `kubectl apply` of the credential Secret is that seed.
- Sealed-secrets does not remove this step. Its controller decrypts `SealedSecret`s. But the repo `SealedSecret`
  still has to reach the cluster. An Argo CD clone would deadlock. A manual apply is the same out-of-band seed
  with an extra step.

Least privilege: one repo, `Contents: Read-only`. To rotate, re-run the script with a new token. A GitHub App is
the upgrade if a PAT is no longer enough.

## Webhook-driven sync (and the poll fallback)

Argo CD detects new commits in two ways:

- **Poll.** It polls git every `timeout.reconciliation`.
- **Webhook.** GitHub sends `POST /api/webhook` on every push. Argo CD refreshes in seconds instead of waiting for
  the poll.

This repo runs on the webhook. The poll is a slow safety net.

### Poll cadence

`POLL_SYNC_ENABLED` in `.env` sets `timeout.reconciliation`:

| `POLL_SYNC_ENABLED` | `timeout.reconciliation` | Use |
|---|---|---|
| `false` (default) | `300s` | a 5-minute net for a dropped webhook |
| `true` | `60s` | fast poll |

`02b_argocd_webhook.sh` writes the value into `01_argocd/values.yaml`, the one file Argo CD reads. Do not edit
`timeout.reconciliation` by hand. Change the `.env` knob and re-run the script.

Why `300s` and not `60s`:

- The poll re-drives OutOfSync apps and recomputes stale health.
- It does not re-drive a failed sync. That is `syncPolicy.retry`'s job.
- So a faster poll does not speed up cold-boot convergence.
- It costs controller CPU, and that cost grows with the object count.

Why not `0s`, which turns the poll off:

- A lost webhook would then never recover.
- `0s` also needs `ARGOCD_DEFAULT_CACHE_EXPIRATION` tuned.

### Webhook secret

`02b_argocd_webhook.sh` generates the webhook secret. You do not configure it.

- It creates a random shared secret.
- It writes the plaintext to `secrets/argocd-github-webhook-secret.txt`, in the gitignored off-repo store. You
  paste it into GitHub from there.
- It seals it into the `webhook.github.secret` key of `argocd-secret`.
- A re-run reuses the stored value, so the secret in GitHub keeps working. Delete the file to rotate.

### How `argocd-secret` gets built

Argo CD reads `webhook.github.secret` only from the Secret named `argocd-secret`.

- `configs.secret.createSecret: false` keeps the chart from owning that Secret. Otherwise Argo CD `selfHeal`
  would fight the key merged into it.
- `argocd-server` reads `argocd-secret` at startup and exits if it is absent. It writes `server.secretkey` and
  TLS only into a Secret that already exists. It does not reliably create one on a cold cluster.
- With `createSecret: false`, nothing else creates it before boot. So `02a_argocd.sh` seeds an empty
  `argocd-secret` before the Helm install. `argocd-server` then writes its own `server.secretkey` into it.
- The seed carries the label `app.kubernetes.io/part-of=argocd`. Argo CD watches only Secrets with that label.

The webhook key arrives separately, from the wave-3 `argocd-webhook-secret` app.

- It seals in patch mode (`sealedsecrets.bitnami.com/patch: "true"`). Patch mode merges `webhook.github.secret`
  in and keeps `server.secretkey`.
- Patch mode only works if the live Secret already has that annotation. The controller checks the live object,
  not the SealedSecret template.
- So `02a_argocd.sh` sets the annotation on the seeded Secret up front, in both bootstrap and rebuild.

The `SealedSecret` lives in its own wave-3 app, `argo_apps/platform/charts/03_argocd_webhook_secret/`. It cannot
live in the wave-1 argocd chart:

- The imperative `helm upgrade --install` and the wave-1 self-heal would render it on a cold cluster.
- The sealed-secrets controller only installs its CRD at wave 2.
- So Helm aborts with `no matches for kind "SealedSecret"`, and the whole bootstrap stalls.

Wave 3 is the first slot after sealed-secrets. By then `argocd-secret` exists and carries the patch annotation,
so the merge works.

### Bootstrap refresh

During bootstrap the poll is 300s and there is no GitHub webhook yet. The webhook needs public DNS and the
production cert. So `DANGEROUS_bootstrap_cluster.sh` hard-refreshes every Application after its final push. The
re-sealed secrets then apply at once. On a live cluster, refresh the `argocd` app after a push, or wait for the
poll.

### Set up the GitHub webhook

Do this once, after the cluster is reachable on its production cert.

```text
# 1) Seal the secret and set the poll cadence. Writes secrets/argocd-github-webhook-secret.txt.
#    make configure-argocd-webhook runs lib/shell/02b_argocd_webhook.sh.
make configure-argocd-webhook
git add -A && git commit -m "argocd: github webhook sync" && git push

# 2) GitHub repo > Settings > Webhooks > Add webhook:
#      Payload URL      : https://argocd.<domain>/api/webhook
#      Content type     : application/json
#      Secret           : the contents of secrets/argocd-github-webhook-secret.txt
#      SSL verification : Enabled. Needs the letsencrypt-prod cert on argocd.<domain>.
#      Events           : Just the push event
# 3) Push a trivial commit and watch it refresh in seconds:
kubectl -n argocd get applications -w
```

The `/api/webhook` path reaches Argo CD without passing Google SSO. See
[04_ingress.md](04_ingress.md#bypassing-sso-for-a-path-the-argocd-webhook) and the Exposure section below for why
that is safe.

## Exposure: the Argo CD UI behind Google SSO

Bootstrap reaches the UI over port-forward. Day to day, the UI has its own Gateway. `mergeGateways` folds it onto
the one Envoy. The same Google SSO from [04_ingress.md](04_ingress.md#google-sso) fronts it.

Google SSO decides who reaches the UI. Argo CD's own login is off:

- The anonymous user is admin.
- The local admin account is disabled.
- There is no Dex and no OIDC.

So whoever passes Google SSO lands in as admin. There is one login, not two.

That makes the SSO gate the only auth boundary in front of the UI, so it must be the only path in.

- The port-forward break-glass path also lands in as admin with no login. **Break-glass** means the emergency
  path that bypasses normal delivery.
- The one deliberate exception is `POST /api/webhook`, on a separate route with no gate. It carries no session.
  Argo CD authenticates it with the GitHub HMAC signature, checked against `webhook.github.secret`. So it cannot
  reach the UI or the API.

The platform-ingress app (wave 6) delivers the exposure as one of its hosts. The shared `ingress` chart renders:

- a `:443` `Gateway`, named after the hostname
- a cross-namespace `HTTPRoute` to `argocd-server`
- a `ReferenceGrant`
- a SAN entry on the platform ingress's shared cert

Argo CD itself does not change. It keeps `server.insecure: true` and serves plain HTTP on `argocd-server:80`. The
Gateway terminates TLS.

The gate is central. `04_google_sso` lists the argocd subdomain in `hosts`, so its one `SecurityPolicy` targets
the route. It shares the `google-sso.<domain>` callback and `cookieDomain` with the other platform UIs. So there
is no new Google redirect URI and no new policy.

To expose a new platform UI, do both:

- add its edge to the platform ingress `hosts:` list
- list its host in `04_google_sso`

Decisions:

- **`logoutPath` is not `/logout`.** Envoy Gateway's OIDC filter defaults its logout path to `/logout`. Argo CD
  uses that path itself. So the SSO policy sets `logoutPath: /oauth2/sign_out`, and the gate leaves Argo CD's
  logout alone. It is one field on the shared policy and does no harm to the other apps.
- **Break-glass is port-forward.** The Google gate blocks the `argocd` CLI. The CLI speaks gRPC and cannot run the
  browser OIDC flow. Use `kubectl -n argocd port-forward svc/argocd-server 8080:80`. It bypasses the Gateway and
  the SSO gate, so a broken route or policy never locks you out.
- **`/api/webhook` bypasses SSO by design.**
  - A second `HTTPRoute` matches only the Exact path `/api/webhook`, on the same host and Gateway.
  - The `SecurityPolicy` targets routes by exact name, so it never gates this route.
  - Argo CD verifies the GitHub HMAC on that path.
  - The Exact match lets nothing else past SSO. That matters, because the anonymous user is admin.
- **The platform ingress uses the production cert.** It issues from `letsencrypt-prod`, not staging. GitHub's
  webhook SSL verification against the argocd host needs a publicly trusted cert. Mind the production ACME rate
  limits when you re-issue.

Argo CD manages the app that exposes Argo CD. `selfHeal` reverts a bad push. If you ever lock yourself out,
port-forward is the way back in.

## What `02a_argocd.sh` does

The script uses native `helm` and `kubectl` and fails if either is missing. It reaches the cluster through the
pinned kubeconfig that `KUBE_CONTEXT` selects. It is idempotent.

1. **Prerequisites.** Checks for `kubectl`, `helm` and `yq`, a reachable API server, the chart and the root app.
   Checks that Cilium is up, because GitOps needs a working pod network.
2. **Vendor.** Pulls the argo-cd subchart with `helm dependency build`. On a first run it falls back to
   `helm dependency update`, which generates `Chart.lock`. Commit the lock.
3. **Seed `argocd-secret`.** Creates it empty if absent, and adds the patch annotation. See
   [How `argocd-secret` gets built](#how-argocd-secret-gets-built).
4. **Install.** Runs `helm upgrade --install argocd argo_apps/platform/charts/01_argocd -n argocd
   --create-namespace --reset-values --wait`. Release `argocd` in namespace `argocd` lets the Argo CD
   Application adopt this release.
5. **Wait.** Waits for the controller, repo-server and server to roll out.
6. **Check the root app.** Asserts that `root.yaml` already carries `REPO_URL`. `04_values.sh` writes it, and the
   bootstrap commits and pushes it before this step.
7. **Check the push.** Fails on uncommitted changes under `argo_apps/` or `lib/helm/`, or on unpushed commits.
8. **Seed the git credential.** Only if `ARGOCD_GITHUB_PAT_SECRET` is set. See [Git auth](#git-auth).
9. **Hand off.** Applies the root app. The root creates `cilium` at wave 0, which adopts the running release. It
   then creates `argocd` at wave 1, which adopts itself.
10. **Confirm the hand-off.** Waits for the root to create the `platform` app, and prints the `cilium` sync
    status. It does not wait for health. Apps backed by sealed secrets stay Degraded until the master key is
    restored in a later step.

```bash
# 1) generate the argo-cd Chart.lock (first time only), commit, and push:
helm dependency update argo_apps/platform/charts/01_argocd
git add -A && git commit -m "step 02a: ArgoCD" && git push

# 2) bootstrap:
lib/shell/02a_argocd.sh

# 3) reach the UI. No login: anonymous is admin, the local admin is disabled.
kubectl -n argocd port-forward svc/argocd-server 8080:80
#    then open http://localhost:8080. All apps adopt their releases. Nothing to click.
```

## Caveats

- **Run `01_cilium.sh` first.** Argo CD, CoreDNS and every workload need Cilium's pod network. The script refuses
  to run if `ds/cilium` is absent.
- **Push before you hand off.** Argo CD clones the repo. It cannot see anything you have not committed and pushed.
  The root app then shows `ComparisonError: path does not exist`. The script fails on a dirty `argo_apps/` or
  `lib/helm/`, or on unpushed commits. Commit, push and re-run. The re-run is safe.
  - Any earlier step that writes into `argo_apps/` needs a commit and push before the hand-off.
  - Both orchestrators commit and push right before they run `02a_argocd.sh`.
  - Without that commit, the run aborts at the push check with the cluster half built.
- **Never write a chart value with `yq -i`.** Use `ys_set` or `ys_set_list` from `common.sh`.
  - `yq` rewrites the whole document and drops the blank line before a comment block.
  - So a write that changes no value still leaves the file modified. That alone fails the push check.
  - `ys_set` replaces one line and keeps its trailing comment. When the value already matches, the file does not
    change at all.
  - `yq` is fine for reads. Every caller checks the write with a `yq -r` read-back.
  - `yq` is also fine for a file that kubeseal generates, because each run regenerates it whole.
- **Argo CD manages itself.** Once the `argocd` app is Synced, Argo CD applies changes to `01_argocd/values.yaml`
  to itself on push.
  - A bad value can disrupt Argo CD for a short time. It heals itself.
  - `02a_argocd.sh` stays as break-glass. A re-run forces the release back to the chart.
- **The leftover Helm release secret is harmless.** The by-hand install leaves `sh.helm.release.v1.argocd.*` in
  `argocd`. Once Argo CD adopts the app, you may delete it.

## Troubleshooting

- **The `argocd` app shows `ComparisonError` or "app path does not exist".** The files are not on the remote.
  Commit and push `argo_apps/**`, including any `Chart.lock`, then re-sync.
- **The `argocd` app is `OutOfSync` with a `helm dependency build` error.** `Chart.lock` is missing from git, or
  stale. Run `helm dependency update argo_apps/platform/charts/01_argocd`, commit the lock and re-sync.
- **The `cilium` app is `OutOfSync`.**
  - It auto-syncs with `selfHeal`, so a brief OutOfSync normally returns to the git state by itself.
  - `selfHeal` reverts a break-glass `01_cilium.sh` fix that is not in git yet. Commit it quickly.
  - A lasting OutOfSync means Argo CD cannot sync at all. Look for a `Chart.lock`, CRD or path problem. Fix it and
    the app reconciles.
- **`server` or `repo-server` pods stay Pending.** The `DoNotSchedule` topology spread needs 2 schedulable nodes
  with free room. Check `kubectl -n argocd get pods -o wide` and node pressure.
- **There is no login prompt.** That is expected. The anonymous user is admin and the local admin account is
  disabled. To restore password login, set `admin.enabled: "true"` and push. Or, as break-glass, run
  `kubectl -n argocd edit cm argocd-cm`.

## Reading the script output

- Each check prints `[PASS]` or `[FAIL]`.
- The run ends with `summary: N passed, M failed`.
- It exits non-zero on any failure.
- A clean run confirms that the root created the `platform` app. It prints the `cilium` sync status, which should
  be Synced.
