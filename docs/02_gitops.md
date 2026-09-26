# GitOps: Argo CD

Argo CD is the last component installed imperatively. After it, everything is GitOps. Procedures are in
[runbooks/02_gitops.md](runbooks/02_gitops.md).

`02a_argocd.sh` installs the wrapper chart `argo_apps/platform/charts/01_argocd/` by hand, then applies the root
app. Argo CD adopts its own release and the running Cilium release, then delivers every later app. The repo
conventions for adding an app are in [CONTRIBUTING.md](../CONTRIBUTING.md#argo-cd-apps).

## Two trees of apps

An **app of apps** is an Argo CD Application that renders other Applications. A **leaf** renders a chart of real
resources.

```
argo_apps/
  root.yaml            # the root of roots, applied once by 02a_argocd.sh
  roots/
    0_platform.yaml    #   Application "platform",  sync-wave 0, renders platform/apps
    1_workloads.yaml   #   Application "workloads", sync-wave 1, renders workloads/apps
  platform/
    apps/              #   one Application per app, numbered by wave
    charts/            #   the wrapper charts those Applications point at
  workloads/
    apps/              #   same shape, with no number and no wave
    charts/
```

Platform apps carry a sync wave: Cilium at 0, Argo CD at 1, everything else at 2 or later. Workloads carry none and
reconcile in parallel.

## No Application health gate

Argo CD has no health check for `argoproj.io/Application`, so a wave never waits for its children to be healthy.
Waves only order creation, 5s apart.

This repo does not add the custom health check. That gate keeps stale health: a quiet, Synced app recomputes
health only on the poll. Measured on this cluster, it froze the tree for about 9 min per wave, and a cold boot
took about 51 min.

So ordering is eventual:

- An app that races ahead of a CRD it needs fails its sync.
- Unbounded `syncPolicy.retry` (`limit: -1`, `refresh: true`) re-drives it. It typically converges in 1 to 2 min.
- Only that retry re-drives a failed sync. `selfHeal` and the poll do not. So every app sets `retry.limit: -1`.

## The resources finalizer on every Application

`prune` deletes resources that leave a live app. It does nothing when the Application itself is deleted. Only the
`resources-finalizer.argocd.argoproj.io` finalizer makes that deletion cascade.

Without it, renaming or dropping an app leaves its resources running with no owner. Example: a renamed RabbitMQ
operator leaves its old `failurePolicy: Fail` webhook behind, which blocks every topology CR in the cluster.

So every Application carries the finalizer, from the root of roots down to every leaf.

## HA-lite: sized for 3x 8 GB Pis

**HA-lite** means high availability only where an outage hurts. Argo CD is not in the data path of running apps,
so a few seconds without reconciliation is fine.

| Component | Setting | Why |
|---|---|---|
| application-controller | 1 replica | a singleton that heals itself on restart |
| redis | single, no `redis-ha` | only a cache. `redis-ha` would add about 5 pods |
| repo-server, server | 2 replicas and a PDB | stay up during a node drain |
| applicationSet-controller | 2 replicas | leader-elected. 2 for fast failover. Drop to 1 if RAM gets tight |
| dex, notifications | disabled | this repo uses neither |

## Roll-forward only: `revisionHistoryLimit: 0` everywhere

Recovery is always a git revert that Argo CD syncs, never `argocd app rollback` or `kubectl rollout undo`. So
revision history is dead weight: 10 `status.history` entries per app and 10 old ReplicaSets per workload.

Every Application, every first-party workload and every upstream chart with a knob sets it to 0. These keep the
default of 10:

| Exception | Why |
|---|---|
| cilium, envoy-gateway, victoria-metrics-operator, cloudnative-pg, longhorn, redis-operator, victoria-logs-collector | the chart has no `revisionHistoryLimit` value |
| sealed-secrets | the template guards the knob with `{{- if }}`, and `0` is falsy in Helm |
| the `03_barman_cloud_plugin` Deployment | a vendored upstream manifest. A hand edit is lost on the next re-vendor |

A kustomize or postRenderer layer could force the value, but it would break the plain wrapper chart pattern.

## Git auth

The repo is public, so Argo CD clones it anonymously. Anonymous `git ls-remote` uses smart HTTP, not the REST
API, so the poll stays well under GitHub's limits.

For a private repo, `02a_argocd.sh` seeds a read-only PAT as a `repo-creds` Secret, scoped to this one repo URL.
It is seeded imperatively, not through Sealed Secrets. A clone credential cannot live in the repo it unlocks, and
bare metal has no cloud identity to fall back on. A GitHub App is the upgrade if a PAT is no longer enough.

## Webhook-driven sync (and the poll fallback)

GitHub sends `POST /api/webhook` on every push, and Argo CD refreshes in seconds. The poll every
`timeout.reconciliation` is only a safety net for a lost webhook.

| `POLL_SYNC_ENABLED` in `.env` | `timeout.reconciliation` | Use |
|---|---|---|
| `false` (default) | `300s` | a 5-minute net for a dropped webhook |
| `true` | `60s` | fast poll |

Why `300s`:

- A faster poll does not speed up convergence. It does not re-drive a failed sync. `syncPolicy.retry` does.
- The poll costs controller CPU, and the cost grows with the object count.
- `0s` turns the poll off, so a lost webhook would never recover.

`02b_argocd_webhook.sh` generates the webhook secret and seals it into `argocd-secret` through the wave-3
`argocd-webhook-secret` app. The comments in `02a_argocd.sh` and `01_argocd/values.yaml` explain how that Secret
is built.

## Exposure: the Argo CD UI behind Google SSO

Google SSO at the edge is the only login. Argo CD's own login is off: the anonymous user is admin, the local admin
is disabled, and there is no Dex. So there is one login, not two.

That makes the SSO gate the only auth boundary, so it must be the only path in.

- **`/api/webhook` bypasses SSO by design.** A separate route matches only that exact path. Argo CD checks the
  GitHub HMAC signature on it, so it cannot reach the UI or API.
- **Break-glass is port-forward.** It bypasses the Gateway and SSO, so a broken route never locks you out. It also
  lands you in as admin with no login.
- **The Argo CD edge uses the production cert.** GitHub's webhook SSL verification needs a publicly trusted cert.
- **`logoutPath` is `/oauth2/sign_out`, not Envoy's default `/logout`,** because Argo CD uses `/logout` itself.

The platform-ingress app delivers the edge, and `04_google_sso` lists its host. See [04_ingress.md](04_ingress.md).
