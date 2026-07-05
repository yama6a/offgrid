# 10: sample-workload, a real app + its Postgres behind the Gateway

The cluster's one end-to-end sample workload, the merge of the `gateway-test` demo and the
`cnpg-cluster` Postgres into a single chart. It proves the whole stack at once: a real app, its own
database, and both ingress modes (open + SSO). One chart ships three slices:

- app: a Deployment + Service running `ghcr.io/yama6a/pi5-k8s-sample-app:1`, with the Postgres
  `app`-role password injected as `PG_PASSWORD` from the CNPG-generated Secret.
- database: a CloudNativePG `Cluster` via the shared `pg-cluster` wrapper (which pins `cnpg/cluster` and
  pre-bakes the boilerplate; this workload sets only `type`/`instances`/`resources`), 2-instance HA on the
  node-local `local-path` class.
- ingress: one ingress, two hosts (plain edges rendered by the shared `ingress-edge` library, see
  [07_ingress.md](07_ingress.md)), each host's Gateway folded onto the one shared Envoy via `mergeGateways`.
  This chart configures **no SSO** — gating is central in [`04_google_sso`](07_ingress.md):
  - `sample-workload.example.com`: OPEN — not listed in `04_google_sso`, the unprotected control.
  - `sample-workload-sso.example.com`: GATED — listed in `04_google_sso` `domains[].hosts` with its own
    allowlist; that chart's per-domain `SecurityPolicy` targetRefs this route and gates it. Auth bounces via
    the shared `google-sso.example.com` callback host.

Both hosts front the same app Service.

Delivered purely by ArgoCD:

- `argo_apps/workloads/apps/sample_workload.yaml`: the Application. A workload (in the workloads
  tree), so no `NN_` number and no `sync-wave`, see "Ordering" below.
- `argo_apps/workloads/charts/sample_workload/`: wraps two `file://` dependencies — the shared `pg-cluster`
  wrapper (which itself pins `cnpg/cluster`) and the shared `ingress-edge` library (both `Chart.lock`-committed,
  vendored `charts/*.tgz` gitignored) — and adds a first-party template for the app plus a one-line
  `{{ include "ingress-edge.render" . }}` for the ingress. The Postgres needs no template: `pg-cluster` renders
  the `Cluster` from the `pg-cluster:` values block. See the shared-charts section in [CLAUDE.md](../CLAUDE.md).

## Namespaces: two, on purpose

| Resource | Namespace | Why |
|----------|-----------|-----|
| app Deployment + Service, CNPG `Cluster`, generated `...-app` Secret, `ReferenceGrant` | `sample-workload` (the Application's `destination.namespace`, `CreateNamespace=true`) | the app must read `PG_PASSWORD` from a Secret in its own namespace, so app + DB + Secret co-locate. |
| per-host `Gateway` + `:443` listener + `HTTPRoute`, one `Certificate` per ingress | `gateway` (the library's `ingressEdge.gatewayNamespace`) | the merged-Envoy model + the central `04_google_sso` SecurityPolicy (which targetRefs these routes) require the routes in `gateway`. |

So this is a deliberately multi-namespace Application. The HTTPRoutes (in `gateway`) reach the app
Service (in `sample-workload`) via a `ReferenceGrant` in `sample-workload`, the same cross-namespace
pattern the platform-ingress app uses for the argocd + monitoring UIs.

## The PG_PASSWORD wiring

The `cnpg/cluster` chart (via the `pg-cluster` wrapper) names the `Cluster` `<release>-cluster` ->
`sample-workload-cluster` — the extra wrapper layer doesn't change the name (it's the grandchild chart's own
name + the release name) — so the CNPG operator generates the `app`-role credentials into the Secret
`sample-workload-cluster-app`. The app
Deployment injects only the password (as specced):

```yaml
env:
  - name: PG_PASSWORD
    valueFrom:
      secretKeyRef:
        name: sample-workload-cluster-app   # derived from the release name in values.yaml
        key: password
```

That same Secret also carries `username` / `dbname` / `host` / `port` / `uri` if the app ever needs the
full DSN, only the password is injected here. On a cold start the app may briefly sit in
`CreateContainerConfigError` until the operator finishes bootstrapping the Cluster and writes the Secret,
then it starts, expected, self-heals.

## Decisions

### Why merge the two workloads
A real sample app needs a database; the split (`gateway-test` echo + standalone `cnpg-cluster`) never
exercised an app -> DB path. Merging gives one workload that proves the full chain (ingress (open + SSO) ->
app -> Postgres) and is the template for any stateful app behind the Gateway. The CNPG operator stays a
platform app ([08_storage.md](08_storage.md)); only the cluster moved here, into the `sample-workload`
namespace.

### One-place edit: the whole ingress is a values list
Per-host HTTP-01 (no wildcard without DNS-01) still means every HTTPS host needs its own `:443` listener,
but that listener lives on the host's own Gateway (rendered by the `ingress-edge` library), folded onto
the shared Envoy via `mergeGateways`, not on a shared Gateway in `03_gateway`. Each ingress declares one
`domain`; adding a host is a single `{ subdomain, targetService, targetPort }` under its `hosts:` (host = `<subdomain>.<domain>`,
or `subdomain: "@"` for the apex). A different-domain group is a new `ingresses[]` entry with its own
`domain`. The library renders Gateway + listener + cert + route together (no SSO — that's central in
`04_google_sso`), nothing to keep in step in `03_gateway`.

### Postgres via the `pg-cluster` wrapper, not the raw `cnpg/cluster` chart
The workload doesn't depend on `cnpg/cluster` directly; it depends on the shared `pg-cluster` wrapper
(`lib/helm/pg-cluster`, see [CLAUDE.md](../CLAUDE.md)), which pins `cnpg/cluster` and pre-bakes every
value a workload shouldn't think about (node-local `local-path` storage + 45Gi, hostname anti-affinity,
monitoring on, an `app`/`app` initdb, backups off). This workload's `pg-cluster:` values block sets only the
three REQUIRED knobs — `type`, `instances` (1 or 2), `resources` — so a new Postgres-backed workload is ~6
lines, not ~40. A validation template in the wrapper fails the render (with a clear message) if any required
knob is missing. Trade-off, inherent to wrapping a subchart (Helm can't transform or lock a child's values):
the pre-baked values are *soft* defaults a consumer could still override, and the values sit one level deeper
(`pg-cluster.cluster.cluster.*`). Because `initdb` is a wrapper default (a subchart default isn't visible at
this chart's scope), the app template hardcodes `PG_USER`/`PG_DATABASE` to the literal `app`.

### Ordering: a workload, gated behind the whole platform
This workload needs the CNPG operator's `Cluster` CRD + the `local-path` class (platform wave 2), the
shared `:80` Gateway (`03_gateway`, platform wave 3), and `04_google_sso` (platform wave 4, whose per-domain
`SecurityPolicy` already lists `sample-workload-sso.example.com` and attaches to this route once it appears)
to already exist, otherwise the `Cluster` CR would hit a missing CRD, or login would fail with no callback.
As a workload it gets all of that for free:
the root-of-roots only creates the workloads tree after the entire platform is Synced + Healthy, so
there's no per-app `sync-wave` to manage. See the two-tree model in [05_gitops.md](05_gitops.md) /
[CLAUDE.md](../CLAUDE.md).

### Storage: node-local, off Longhorn
The `Cluster` runs on the node-local `local-path` class (2 instances on 2 distinct Pi nodes, Postgres
streaming replication as the only replication layer). The full reasoning lives in [08_storage.md](08_storage.md).

## Apply / verify

1. Ensure each host's public DNS -> home router and the old Pi forwards `:80` to the Gateway IP so HTTP-01
   issues its cert (the `:443` listener ships with the host's own Gateway, see [07_ingress.md](07_ingress.md)).
2. `helm dependency build argo_apps/workloads/charts/sample_workload` and commit the `Chart.lock` (ArgoCD's
   repo-server runs `helm dependency build`; a missing/stale lock breaks sync).
3. `git add -A && git commit && git push`, ArgoCD applies the workload via the workloads tree (once the
   platform is Healthy).

Checks (`export KUBECONFIG=secrets/kubeconfig`):

- `kubectl -n sample-workload get cluster,pods` -> `sample-workload-cluster` with 2 instances Running on 2
  distinct nodes; the `sample-workload` app pod Running.
- `kubectl -n sample-workload get secret sample-workload-cluster-app` -> exists (the source of `PG_PASSWORD`).
- `kubectl -n gateway get certificate sample-workload sample-workload-sso` -> `READY=True` once DNS + the
  `:80` forward exist.
- `https://sample-workload.example.com/` -> the app, no login (open control).
- `https://sample-workload-sso.example.com/` -> Google login -> bounce via `google-sso.example.com` -> an
  allowlisted account reaches the app; a non-listed one is denied (see [07_ingress.md](07_ingress.md)).

## Caveats

- One-place edit per host: a single `hosts[]` entry (`subdomain` + `targetService`/`targetPort`) renders that host's
  Gateway + listener + route (+ a SAN entry on the ingress's one shared cert); the resource names derive from
  the full host `<subdomain>.<domain>` (dots -> dashes), so there's nothing else to keep in sync.
- `sample-workload-sso` is gated centrally, not here: it must be listed in `04_google_sso` `domains[].hosts`
  (with its allowlist), and the shared client secret sealed via `lib/shell/07_google_sso.sh`. If it's not
  listed, the host is OPEN; if the secret isn't sealed, login fails (see [07_ingress.md](07_ingress.md)).
- `prune` is data-safe: the Postgres PVCs use `local-path` with `reclaimPolicy: Retain`, so removing
  the app never destroys the node-local volumes under `/var/mnt/cnpg` (see
  [08_storage.md](08_storage.md)).
- No PITR until backups are wired (`backups.enabled: false`, hardcoded in the `pg-cluster` wrapper):
  durability rests on Postgres replication across the 2 instances; see [08_storage.md](08_storage.md).
