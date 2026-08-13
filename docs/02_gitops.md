# GitOps: ArgoCD

ArgoCD is the last component installed imperatively. From here on everything is GitOps. It manages itself from a
wrapper chart in this repo, adopts the already-running Cilium, and becomes the delivery path for every later app.
`02a_argocd.sh` does the one-time bootstrap.

Source of truth is `argo_apps/platform/charts/01_argocd/`. The script installs that chart by hand, then hands off
to git: ArgoCD adopts the same release (same chart, namespace, release name, values) so Argo sees it in-sync
rather than fighting it. No version and no value lives in the script.

| Path                 | Holds                                                                                      |
|----------------------|--------------------------------------------------------------------------------------------|
| `Chart.yaml`         | the argo-cd chart, declared as a dependency on argo-helm                                    |
| `values.yaml`        | the HA-lite values under the `argo-cd:` key, see below                                      |
| `Chart.lock`         | the resolved dependency; must be committed, ArgoCD's repo-server needs it                   |

## The `argo_apps/` app-of-apps model: two trees

```
argo_apps/
  root.yaml              # the ROOT-OF-ROOTS (applied once by 02a_argocd.sh); recurses roots/
  roots/
    0_platform.yaml      #   Application "platform"  (sync-wave 0), renders platform/apps
    1_workloads.yaml     #   Application "workloads" (sync-wave 1), renders workloads/apps
  platform/
    apps/                #   a chart: repoURL in values.yaml, one Application per app in templates/
      values.yaml        #     the ONE repoURL for this tree, written by 04_values.sh
      templates/
        00_cilium.yaml   #     adopts Cilium      (auto-sync, selfHeal+prune), wave 0
        01_argocd.yaml   #     ArgoCD self-manage (automated),                 wave 1
    charts/              #   the wrapper charts those Applications point at
  workloads/
    apps/                #   same shape: values.yaml + templates/ (un-numbered, wave-less)
      templates/
        sample_user_manager.yaml
    charts/
      sample_user_manager/   #  the sample app + its Postgres + Redis + messaging + ingress
```

`root.yaml` recurses `argo_apps/roots/` and manages the two child root Applications it finds. Their sync-waves
order CREATION only, 5s apart via `ARGOCD_SYNC_WAVE_DELAY` set in `01_argocd` values: `platform` at wave 0, then
`workloads` at wave 1. It does NOT wait for platform health.

- Each child Application points at a wrapper chart under its own tree's `charts/`.
- Adding a platform app means a wrapper chart under `argo_apps/platform/charts/NN_name/` plus an Application
  manifest under `argo_apps/platform/apps/templates/NN_name.yaml`, then commit and push. The `NN` prefix is the app's
  `sync-wave` number; keep the filename, chart dir and annotation in agreement.
- Adding a workload means a wrapper chart under `argo_apps/workloads/charts/name/` plus an Application under
  `argo_apps/workloads/apps/templates/name.yaml`, with no number and no `sync-wave`. Workloads all reconcile in parallel. If
  a workload depends on another workload, it belongs in platform instead.

### No Application health gate, deliberately

ArgoCD ships no built-in health assessment for `argoproj.io/Application`, so a parent app-of-apps sees its child
Applications as health-less and a wave never waits on child health.

Do not restore it with `resource.customizations.health.argoproj.io_Application` to make the wave-0 to wave-1
gate wait. That gate is fragile: a child that transiently reports Degraded or Progressing LATCHES a stale
health status, because a quiescent Synced app only recomputes health on the `timeout.reconciliation` poll and
there is no separate health-refresh. Measured, it froze the whole tree about 9 min per wave and stretched a
cold boot to about 51 min.

Ordering is now eventual. `workloads` is created while the platform may still be coming up, and a workload whose
platform CRD is not registered yet fails its sync and converges via UNBOUNDED `syncPolicy.retry` (`limit: -1`,
`refresh: true`), typically within 1 to 2 min. Only within-operation retry re-drives a failed sync; selfHeal and
the poll do NOT, verified against ArgoCD. Which is why every app's `retry.limit` is `-1`.

### Removing or renaming an app

Every Application manifest in this repo, the root-of-roots, both roots, and every `platform/apps/**` and
`workloads/apps/**` leaf, carries:

```yaml
metadata:
  finalizers:
    - resources-finalizer.argocd.argoproj.io
```

This exists because deleting or renaming an app touches two different mechanisms and only one of them cleans up:

- `syncPolicy.automated.prune` prunes resources WITHIN a live app when they leave that app's rendered manifests.
  It says nothing about an app's resources when the Application object itself is deleted, and a deleted
  Application has no sync loop left to prune anything.
- Whether deleting an Application also deletes what it deployed is governed ONLY by the finalizer. With it,
  deletion cascades: ArgoCD deletes the managed resources first, then removes the finalizer, then the object goes.
  Without it, deletion is non-cascading: ArgoCD removes the Application and leaves its resources running,
  unmanaged.

When you rename a wrapper chart or drop an app from a tree, the parent prunes the child Application object, and
that part works. But without the finalizer on that child, its Kubernetes resources are orphaned rather than
deleted.

This bit us when merging the two RabbitMQ apps into one. Renaming the operator's Helm release changed every
operator-subchart resource name, so the old app's Deployments and `ValidatingWebhookConfiguration` were not
re-adopted by the new app. They were left running by a now-deleted Application, and the duplicate `failurePolicy:
Fail` webhook blocked all topology-CR admissions cluster-wide. Resources whose name does NOT change get re-adopted
by the renamed app and survive fine; it is the release-named ones that orphan.

The finalizer makes removal and rename self-cleaning, and it propagates: deleting the root-of-roots cascades to
the two roots, which cascade to every leaf. Two things to know:

- Teardown needs the controller alive. The finalizer is processed by the application-controller, so deleting an app
  while the controller is gone, mid-teardown or the `argocd` app itself, leaves it stuck `Terminating`. Clear it
  with `kubectl -n argocd patch app <name> --type=merge -p '{"metadata":{"finalizers":[]}}'`. A full cluster wipe
  removes the OS underneath anyway, so this only matters for a targeted delete on a live cluster.
- It changes nothing during normal sync. The finalizer is inert until the Application is actually deleted.

### sync-wave convention

Ordering across platform apps is `argocd.argoproj.io/sync-wave`, lower being earlier. Since there is no
Application health gate, a wave does NOT wait for the prior wave to be Healthy. Waves only order the CREATION of
the child Application objects, 5s apart.

That head-start still helps, since CRD and operator apps get applied before their consumers, but it is advisory:
an app that races ahead of a CRD it needs fails and retries until the CRD lands. The `NN` prefix on each
`platform/apps/templates/NN_*.yaml` equals its wave number, so one glance at the dir listing tells you the order.

The gap is `ARGOCD_SYNC_WAVE_DELAY`, set to 5 seconds via the `controller.sync.wave.delay.seconds` param in
`01_argocd/values.yaml`. A head-start buffer, not a readiness gate: it is a fixed timer, and retry is what
actually guarantees CRD-before-consumer. Controller-wide, so it also spaces resource-level waves inside every
chart.

- Cilium is wave 0. The CNI underpins everything, so it is created first.
- ArgoCD is wave 1, adopting the already-running, self-managed ArgoCD.
- Later platform apps go at wave 2 and up, created after the CNI and engine.
- Keep every app auto-syncing with `retry: -1` and `refresh: true` so it converges. Without the health gate an
  OutOfSync or Degraded app no longer stalls later waves or the roots, but auto-sync plus unbounded retry is still
  the only thing that recovers it, so a manual-sync app would never converge on its own.
- Caveat: if you break-glass-fix Cilium out of band and do not commit the fix, `selfHeal` reverts it on the next
  reconcile. Always commit the fix back to git.

## HA-lite: sized for 3x 8 GB Pis

ArgoCD is not in the data path of running apps. Once an app is synced it runs regardless of Argo, so a few seconds
without reconciliation is fine. We spend the RAM only where an outage would hurt.

| Component                  | Setting                           | Why                                                                     |
|----------------------------|-----------------------------------|-------------------------------------------------------------------------|
| application-controller     | 1 replica                         | the reconciler; a singleton that self-heals on restart                  |
| redis                      | single (`redis-ha.enabled: false`)| only a cache, rebuilds in seconds. redis-ha would add about 5 pods      |
| repo-server                | 2 replicas + PDB                  | manifest generation; kept up across a node drain                        |
| server (API/UI)            | 2 replicas + PDB                  | the UI and API; kept up across a node drain                             |
| applicationSet-controller  | 2 replicas                        | leader-elected; 2 for fast failover, drop to 1 if RAM gets tight        |
| dex, notifications         | disabled                          | no SSO and no notifications here, so 2 fewer pods                       |

The 2-replica components carry `global.topologySpreadConstraints` (`maxSkew 1`, `kubernetes.io/hostname`,
`DoNotSchedule`), which over 3 nodes forces each pair onto two distinct nodes. Singletons satisfy it trivially.

## Decision notes

- Git auth is anonymous by default, with a single-repo PAT for private repos. The repo is public, so ArgoCD clones
  it anonymously over HTTPS with no secret. To run this against a private repo, or to lift the anonymous git rate
  limit, `02a_argocd.sh` seeds a read-only PAT before hand-off. See [Git auth](#git-auth).
- Cilium auto-syncs with full `selfHeal` and `prune`, the same as every leaf, chosen for convenience even though
  it is the one app that can cut Argo and the cluster off its own network. That circular dependency is called out
  in [01_networking.md](01_networking.md). Auto-sync gives hands-off upgrades; the knowingly-accepted danger is
  that `selfHeal: true` reverts an out-of-band break-glass fix unless you commit it fast, and `prune: true`
  cascade-deletes any resource or CRD dropped from the chart. A bad Cilium change pushed to git applies unattended
  AND is self-healed in place, so mind your pushes. First sync auto-adopts the running release with no pod churn,
  because the chart's `values.yaml` already commits `loadBalancer.enabled: true`, so Argo's rendered desired state
  matches live.
- `Chart.lock` must be committed for any wrapper chart with a REMOTE dependency, because ArgoCD's repo-server
  renders with `helm dependency build`, which requires it. `01_argocd`'s is generated on the first run of
  `02a_argocd.sh`; commit it before the `argocd` app reconciles, and the script reminds you.
- `global.networkPolicy.create` is pinned `false`. The chart defaults it true, which renders standard k8s
  NetworkPolicy objects, and the server's is `ingress: - {}`, allow-all. Cilium enforces those too and UNIONs them
  with our own default-deny policy for the argocd namespace, so an allow-all NP would blow the default-deny open
  on this cluster-admin and git-creds namespace. Cilium is the sole policy engine here, so we opt back out.
- UI over port-forward during bootstrap. `server.insecure: true` serves plain HTTP, so there is no TLS to fumble
  through a port-forward. Flip it to `false` and front it with TLS only if you ever terminate TLS at ArgoCD
  instead of the Gateway. See [Exposure](#exposure-the-argocd-ui-behind-google-sso).

## Roll-forward only: `revisionHistoryLimit: 0` everywhere

Recovery here is always roll-forward, a git revert re-synced by Argo, never `argocd app rollback` or `kubectl
rollout undo`. So the retained revision history every resource keeps by default (10 Argo `status.history` entries,
10 old ReplicaSets or ControllerRevisions per workload) is pure dead weight: orphaned ReplicaSets pile up and Argo
carries rollback state nobody uses.

Disabled in three layers:

1. Every `Application` (`root.yaml`, `roots/*.yaml`, `platform/apps/**`, `workloads/apps/**`) sets
   `spec.revisionHistoryLimit: 0`, so no Argo rollback history.
2. Every first-party workload we template sets it on the workload `spec`: the 3 sample-app Deployments,
   `05_ntfy`, `05_orphan_exporter`, `02_dead_node_watcher`, the `04_google_sso` callbacks, and
   `02_nic_keeper` (a DaemonSet, so `ControllerRevision` history).
3. Upstream charts set it via their values knob where one exists: `01_argocd` (both `global.` AND `controller.`,
   because the controller StatefulSet ignores global's `0` since Helm's `default` treats `0` as empty),
   `02_cert_manager` (`global.`, applied to all 3 Deployments), `02_metrics_server`, `03_rabbitmq` (both
   operators), `05_grafana`, and `05_victoria_metrics_k8s_stack` (VMSingle and VMAgent CRs via
   `spec.revisionHistoryLimitCount`, note the different field name, plus the `kube-state-metrics` and
   `prometheus-node-exporter` subcharts).

Documented exceptions, so there are no silent caps. The repo is pure Helm with no kustomize or postRenderer, and
adding one just to force this would break the clean wrapper pattern, so these stay at the k8s default of 10:

- No `revisionHistoryLimit` value at all: cilium, envoy-gateway, victoria-metrics-operator, cloudnative-pg,
  longhorn, redis-operator, victoria-logs-collector.
- The knob exists but `0` is silently dropped, because the template guards with `{{- if ... }}` and `0` is falsy in
  Helm: sealed-secrets. Any non-zero value works; `0` does not.
- Vendored verbatim: the `03_barman_cloud_plugin` plugin Deployment lives in a re-curled upstream manifest marked
  DO NOT EDIT BY HAND, so a hand-edit would be erased on the next re-vendor.

## Git auth

This repo is public, so ArgoCD clones it anonymously over HTTPS with no credential. Anonymous `git ls-remote` is
git smart-HTTP rather than the REST API, so even the fast-poll setting stays well under GitHub's limits. Sync is
webhook-driven anyway, with the poll only a slow fallback.

For a private repo, or to lift the anonymous rate limit, `02a_argocd.sh` seeds a credential: at hand-off it reads
`ARGOCD_GITHUB_PAT_SECRET`, a fine-grained read-only single-repo PAT, from the gitignored `.env`. Leave it empty
for a public repo. It then creates an ArgoCD `repository` Secret, labelled `argocd.argoproj.io/secret-type:
repository` with `url` equal to the polled `repoURL`, before applying the root app.

```text
# Create the PAT first: GitHub -> Settings -> Developer settings -> Fine-grained tokens
#   Repository access: Only select repositories -> this repo
#   Permissions: Repository -> Contents -> Read-only   (nothing else)
# Put it in .env:  ARGOCD_GITHUB_PAT_SECRET="github_pat_..."   (gitignored; empty = anonymous clone)
# Then run the script (no prompt):
lib/shell/02a_argocd.sh
```

Why the credential is seeded imperatively rather than via sealed-secrets: a private repo's clone credential cannot
live in that repo, and ArgoCD needs it for the first clone. On bare metal there is no cloud identity to fall back
on, so exactly one secret must be seeded out of band at bootstrap, and the script's `kubectl apply` of the
`repository` Secret is that seed. Same role as the kubeconfig.

Sealed-secrets does not remove this step. Its controller decrypts `SealedSecret`s, but getting the repo
`SealedSecret` into the cluster still needs either an ArgoCD clone, which deadlocks, or a manual apply, which is
the same out-of-band seed with extra indirection.

Least privilege: single-repo, `Contents: Read-only`. Rotate by re-running with a new token. A GitHub App is the
upgrade path if you outgrow a PAT.

## Webhook-driven sync (and the poll fallback)

ArgoCD detects new commits two ways: it polls git on `timeout.reconciliation`, or a git webhook pushes it a `POST
/api/webhook` on every push, refreshing in seconds instead of waiting out the poll. We run webhook-driven, with
the poll demoted to a slow safety net.

Poll is the slow fallback, toggled from `.env`. `POLL_SYNC_ENABLED` drives `timeout.reconciliation`: `false`, the
default, gives `300s` as a 5-minute net for a dropped webhook, and `true` gives a `60s` fast poll.
`02b_argocd_webhook.sh` writes it into `01_argocd/values.yaml`, which is the single source ArgoCD reads, so do not
hand-edit `timeout.reconciliation`; flip the `.env` knob and re-run the script.

We keep the `300s` default rather than `60s`: the poll re-drives OutOfSync apps and recomputes stale health, but it
does NOT re-drive a FAILED sync, which is `syncPolicy.retry`'s job. So a faster poll would not speed cold-boot
convergence, and it costs controller CPU that scales with object count. We also do not use `0s`, fully off,
because a lost webhook would then never recover and `0s` also needs `ARGOCD_DEFAULT_CACHE_EXPIRATION` tuned.

The webhook secret is generated, not configured. `02b_argocd_webhook.sh` mints a random shared secret, writes the
plaintext to `secrets/argocd-github-webhook-secret.txt` (the gitignored off-repo store, for pasting into GitHub)
and seals it into `argocd-secret`'s `webhook.github.secret` key. Re-running reuses the stored value, so the secret
you configured in GitHub keeps working. Delete the file to rotate.

`createSecret: false`, plus a SEEDED then MERGED `argocd-secret`. ArgoCD reads `webhook.github.secret` only from
the Secret named `argocd-secret`. We set `configs.secret.createSecret: false` so the chart does not own that
Secret, since ArgoCD self-heal would otherwise fight the key we merge in.

The catch: `argocd-server` reads `argocd-secret` at startup and FATALS if it is absent. It only populates
`server.secretkey` and TLS into a secret that already exists, and does not reliably create it on a cold cluster.
With `createSecret: false` nothing else creates it before boot, so `02a_argocd.sh` seeds an empty `argocd-secret`
BEFORE the Helm install, and `argocd-server` then writes its own `server.secretkey` into it.

The webhook key arrives separately: the wave-3 `argocd-webhook-secret` app seals in PATCH mode
(`sealedsecrets.bitnami.com/patch: "true"`), which merges `webhook.github.secret` in and leaves `server.secretkey`
intact. Patch mode only works if the LIVE Secret already carries that annotation, because the controller checks
the existing object rather than the SealedSecret template, so `02a_argocd.sh` sets it on the seeded secret up front
in both bootstrap and rebuild.

The sealed secret lives in a SEPARATE wave-3 app, not the wave-1 argocd chart. The `SealedSecret` is delivered by
`argo_apps/platform/charts/03_argocd_webhook_secret/`. If it lived in the argocd chart, the imperative `helm
upgrade --install` and the wave-1 self-heal would try to render it on a COLD cluster before the sealed-secrets
controller installs its CRD at wave 2, so helm aborts with `no matches for kind "SealedSecret"` and the whole
bootstrap wedges. This bit a from-scratch rebuild once. Wave 3 is the first slot strictly after sealed-secrets;
`argocd-secret` already exists by then and has been annotated patch-managed, so the merge just works.

Bootstrap nudge: with the poll relaxed to 300s and no GitHub webhook yet, since it needs public DNS plus the prod
cert, `DANGEROUS_bootstrap_cluster.sh` hard-refreshes every Application after its final push so the re-sealed
secrets apply immediately. On a live cluster, refresh the `argocd` app or wait out the fallback after pushing.

Set up the GitHub webhook once, after the cluster is reachable on its prod cert:

```text
# 1) Seal the secret + set the poll cadence (writes secrets/argocd-github-webhook-secret.txt):
make configure-argocd-webhook          # == lib/shell/02b_argocd_webhook.sh
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

The `/api/webhook` path reaches ArgoCD WITHOUT passing Google SSO. That bypass, and why it is safe, is in
[04_ingress.md](04_ingress.md#bypassing-sso-for-a-path-the-argocd-webhook) and the Exposure note below.

## Exposure: the ArgoCD UI behind Google SSO

The bootstrap reaches the UI over port-forward. For day-to-day access the UI is exposed through its own Gateway,
folded onto the one Envoy via `mergeGateways`, fronted by the same Google SSO built in
[04_ingress.md](04_ingress.md#google-sso).

The Google gate decides who can reach the UI. ArgoCD's OWN login is turned off: the anonymous user is admin, the
local admin account is disabled, and there is no Dex or OIDC, so whoever clears Google lands straight in as admin.
One login, not two.

The SSO gate is therefore the only auth boundary in front of the UI, which is why it must be the sole path. The
port-forward break-glass below also lands in as admin with no login. The ONE deliberate exception is `POST
/api/webhook`, served by a separate ungated route. It carries no session and is authenticated instead by the
GitHub HMAC signature ArgoCD checks against `webhook.github.secret`, so it cannot reach the UI or API.

Delivered purely by ArgoCD as one host of the platform-ingress app (wave 6): its own `:443` `Gateway` named from
the hostname, a cross-namespace `HTTPRoute` to `argocd-server`, a `ReferenceGrant`, and a SAN entry on the
platform ingress's shared cert. All rendered by the shared `ingress` chart. ArgoCD itself is untouched: it keeps
`server.insecure: true` and serves plain HTTP on `argocd-server:80`, and the Gateway terminates TLS.

Gating is central: the argocd subdomain is listed in `04_google_sso` `hosts`, so the one `SecurityPolicy`
targetRefs its route and gates it. It shares the `google-sso.<domain>` callback and
`cookieDomain` with the other platform UIs, so no new Google redirect URI and no new policy. To expose a new
platform UI: add its edge to the platform ingress `hosts:` list AND list its host in `04_google_sso`.

Decisions worth keeping:

- `logoutPath` moved off `/logout`. Envoy Gateway's OIDC filter defaults its logout to `/logout`, which ArgoCD
  itself uses, so the SSO policy sets `logoutPath: /oauth2/sign_out` and the gate does not swallow ArgoCD's own.
  One field on the shared policy, harmless for other apps under it.
- Break-glass is port-forward. The Google gate blocks the `argocd` CLI, which speaks gRPC and cannot run the
  browser OIDC flow. Keep using `kubectl -n argocd port-forward svc/argocd-server 8080:80`, which also bypasses
  the Gateway and the SSO gate entirely, so a broken route or policy never locks you out.
- `/api/webhook` bypasses SSO by design. A second `HTTPRoute` matches only the Exact path `/api/webhook` on the
  same host and Gateway and, because the `SecurityPolicy` targets routes by exact NAME, is never gated. Safe
  because ArgoCD verifies the GitHub HMAC on that path, and the Exact match means nothing else escapes SSO, which
  is critical since anonymous is admin.
- On the prod cert. The whole platform ingress issues `letsencrypt-prod`, not staging, because GitHub's webhook
  SSL verification against the argocd host needs a publicly-trusted cert. Mind the prod ACME rate limits when
  re-issuing.

Self-management caveat: ArgoCD manages the app that exposes ArgoCD, so a bad push is reverted by selfHeal and
port-forward is the escape hatch if you ever wedge it.

## What `02a_argocd.sh` does

Native `helm` and `kubectl`, erroring out if either is missing, like `01_cilium.sh` and unlike the dockerized
03b-03d scripts. Talks to the cluster via `secrets/kubeconfig`. Idempotent.

1. Prereqs: `kubectl` and `helm` present, kubeconfig reachable, the chart and root app exist, and Cilium is up,
   since the GitOps layer needs a working pod network.
2. Vendors the argo-cd subchart with `helm dependency build`, falling back to `helm dependency update`, which
   generates `Chart.lock` on a first run. Commit it.
3. `helm upgrade --install argocd argo_apps/platform/charts/01_argocd -n argocd --create-namespace --reset-values
   --wait`, with release `argocd` in namespace `argocd` so the self-managed Application adopts THIS release.
4. Waits for the controller, repo-server and server to roll out.
5. Hands off: resolves the repo to poll (`$REPO_URL`, else the git `origin` remote as a prompt default) and pins
   it into `root.yaml`; optionally seeds an `ARGOCD_GITHUB_PAT_SECRET` repository credential from `.env`; then,
   after a "did you push?" check, applies the root app. The root creates `cilium` at wave 0, which auto-adopts,
   then `argocd` at wave 1, which self-adopts. Both Synced, no clicks.
6. Waits for `root` and `argocd` to be Synced and Healthy, then prints the port-forward command.

```bash
# 1) generate the argo-cd Chart.lock (first time only), commit, and PUSH:
helm dependency update argo_apps/platform/charts/01_argocd
git add -A && git commit -m "step 02a: ArgoCD" && git push

# 2) bootstrap:
lib/shell/02a_argocd.sh

# 3) reach the UI (no login: anonymous is admin, local admin disabled):
kubectl -n argocd port-forward svc/argocd-server 8080:80
#    then open http://localhost:8080. All apps auto-adopt, nothing to click.
```

## Caveats

- Run order: 04 before 05. ArgoCD, CoreDNS and every workload need Cilium's pod network, and the script refuses to
  run if `ds/cilium` is absent.
- Push before you hand off. ArgoCD clones the repo, so anything not committed and pushed is invisible to the root
  app, which then shows `ComparisonError: path does not exist`. Step 5 hard-fails on a dirty `argo_apps/` or
  `lib/helm/`, or on unpushed commits; commit, push, re-run (idempotent).
  - `argo_apps/root.yaml` is exempt from that gate. `kubectl` applies it from the working tree and the root's
    path is `argo_apps/roots`, so nothing ever reads `root.yaml` from the remote. Without the exemption the
    script's own `REPO_URL` rewrite would fail a check no amount of committing could satisfy mid-run.
  - Any earlier step that writes into `argo_apps/` must be followed by a commit+push before step 5. Both
    orchestrators do this: bootstrap after 04+07, rebuild after 04. A missing sync step aborts the run at the
    gate with the cluster half-built.
- Scripts that write chart values use `ys_set`/`ys_set_list` from `common.sh`, never `yq -i`. `yq` rewrites the
  whole document and drops the blank line before a comment block, so a write that changes NOTHING still leaves
  the file modified. That is enough to trip the gate above: one rebuild died at step 5 over a single deleted
  blank line in `00_cilium/values.yaml`. `ys_set` substitutes one line, keeps its trailing comment, and is a
  byte-level no-op when the value already matches. `yq` stays fine for reads, and every caller asserts the
  write with a `yq -r` read-back. Writing a kubeseal-generated file with `yq` is also fine, since it is
  regenerated wholesale each run.
- Self-management is real. Once the `argocd` app is Synced, changes to `01_argocd/values.yaml` are applied by
  ArgoCD to itself on push. A bad value can disrupt ArgoCD briefly; it self-heals, and `02a_argocd.sh` remains
  break-glass, since re-running forces the release back to the chart.
- The leftover Helm release secret (`sh.helm.release.v1.argocd.*` in `argocd`) from the by-hand install is
  harmless. Once the app is adopted you may delete it.

## Troubleshooting

- `argocd` app stuck on `ComparisonError` or "app path does not exist": the files are not on the remote. Commit
  and push `argo_apps/**` including any `Chart.lock`, then re-sync.
- `argocd` app `OutOfSync` with a `helm dependency build` error: `Chart.lock` is not committed, or is stale. Run
  `helm dependency update argo_apps/platform/charts/01_argocd`, commit the lock, re-sync.
- `cilium` app `OutOfSync`: it auto-syncs with `selfHeal`, so a transient OutOfSync is normally dragged straight
  back to the git state. A break-glass `01_cilium.sh` fix not yet in git gets reverted, so commit it fast. A
  persistent OutOfSync means Argo cannot sync at all, from a `Chart.lock`, CRD or path issue; fix those and it
  reconciles.
- `server` or `repo-server` pods pending: the `DoNotSchedule` topology spread needs 2 schedulable nodes free.
  Check `kubectl -n argocd get pods -o wide` and node pressure.
- No login prompt, which is expected: the anonymous user is admin and the local admin account is disabled. To
  restore password login, set `admin.enabled: "true"` and push, or break-glass with `kubectl -n argocd edit cm
  argocd-cm`.

## Reading the script output

`[PASS]` or `[FAIL]` per check, then `summary: N passed, M failed`, with a non-zero exit on any fail. A clean run
ends with `root`, `argocd` and `cilium` all Synced and Healthy, everything auto-adopted.
