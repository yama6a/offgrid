# 10: sample-workload, a real app + its Postgres behind the Gateway

The cluster's one end-to-end sample workload, the merge of the `gateway-test` demo and the
`cnpg-cluster` Postgres into a single chart. It proves the whole stack at once: a real app, its own
database, and both ingress modes (open + SSO). One chart ships three slices:

- app: a Deployment + Service running `ghcr.io/yama6a/pi5-k8s-sample-app:1`, with the Postgres
  `app`-role password injected as `PG_PASSWORD` from the CNPG-generated Secret.
- database: a CloudNativePG `Cluster` (the upstream `cnpg/cluster` dependency), 2-instance HA on the
  node-local `local-path` class.
- ingress: two ingresses (rendered by the shared `ingress-edge` library, see [07_ingress.md](07_ingress.md)),
  each host's Gateway folded onto the one shared Envoy via `mergeGateways`:
  - `sample-workload.example.com`: OPEN (no `sso` block), the unprotected control.
  - `sample-workload-sso.example.com`: PROTECTED by this workload's OWN `SecurityPolicy` (rendered by the
    library) carrying its OWN allowlist — independent of the platform ingress even though both are on
    example.com. Auth bounces via the shared `google-sso.example.com` callback host ([`04_google_sso`](07_ingress.md)).

Both hosts front the same app Service.

Delivered purely by ArgoCD:

- `argo_apps/workloads/apps/sample_workload.yaml`: the Application. A workload (in the workloads
  tree), so no `NN_` number and no `sync-wave`, see "Ordering" below.
- `argo_apps/workloads/charts/sample_workload/`: wraps two dependencies — the `cnpg/cluster` chart and the
  shared `ingress-edge` library (both `Chart.lock`-committed, vendored `charts/*.tgz` gitignored) — and adds a
  first-party template for the app plus a one-line `{{ include "ingress-edge.render" . }}` for the ingress.

## Namespaces: two, on purpose

| Resource | Namespace | Why |
|----------|-----------|-----|
| app Deployment + Service, CNPG `Cluster`, generated `...-app` Secret, `ReferenceGrant` | `sample-workload` (the Application's `destination.namespace`, `CreateNamespace=true`) | the app must read `PG_PASSWORD` from a Secret in its own namespace, so app + DB + Secret co-locate. |
| per-host `Gateway` + `:443` listener + `HTTPRoute`, one `Certificate` per ingress, this workload's own `SecurityPolicy` | `gateway` (the library's `ingressEdge.gatewayNamespace`) | the merged-Envoy model + a `SecurityPolicy` selecting routes in its own namespace require the routes in `gateway`. |

So this is a deliberately multi-namespace Application. The HTTPRoutes (in `gateway`) reach the app
Service (in `sample-workload`) via a `ReferenceGrant` in `sample-workload`, the same cross-namespace
pattern the platform-ingress app uses for the argocd + monitoring UIs.

## The PG_PASSWORD wiring

The `cnpg/cluster` chart names the `Cluster` `<release>-cluster` -> `sample-workload-cluster`, so the CNPG
operator generates the `app`-role credentials into the Secret `sample-workload-cluster-app`. The app
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
`domain`; adding a host is a single `{ subdomain, backend }` under its `hosts:` (host = `<subdomain>.<domain>`,
or `subdomain: "@"` for the apex). A differently-gated (or different-domain) group is a new `ingresses[]`
entry with its own `domain`/`sso.allowlist`. The library renders Gateway + listener + cert + route (+ the
ingress's `SecurityPolicy` when SSO is on) together, nothing to keep in step in `03_gateway`.

### Ordering: a workload, gated behind the whole platform
This workload needs the CNPG operator's `Cluster` CRD + the `local-path` class (platform wave 2), the
shared `:80` Gateway (`03_gateway`, platform wave 3), the `SecurityPolicy` CRD (Envoy Gateway, wave 1) and
the shared `google-sso.example.com` callback host + sealed secret (`04_google_sso`, platform wave 4) to
already exist, otherwise the `Cluster` CR would hit a missing CRD, or login would fail with no callback. It
renders its OWN `SecurityPolicy` beside its protected route, so that route is never briefly exposed. As a
workload it gets all of that for free:
the root-of-roots only creates the workloads tree after the entire platform is Synced + Healthy, so
there's no per-app `sync-wave` to manage. See the two-tree model in [05_gitops.md](05_gitops.md) /
[CLAUDE.md](CLAUDE.md).

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

Checks (`export KUBECONFIG=03_operating_system/talos-cluster/kubeconfig`):

- `kubectl -n sample-workload get cluster,pods` -> `sample-workload-cluster` with 2 instances Running on 2
  distinct nodes; the `sample-workload` app pod Running.
- `kubectl -n sample-workload get secret sample-workload-cluster-app` -> exists (the source of `PG_PASSWORD`).
- `kubectl -n gateway get certificate sample-workload sample-workload-sso` -> `READY=True` once DNS + the
  `:80` forward exist.
- `https://sample-workload.example.com/` -> the app, no login (open control).
- `https://sample-workload-sso.example.com/` -> Google login -> bounce via `google-sso.example.com` -> an
  allowlisted account reaches the app; a non-listed one is denied (see [07_ingress.md](07_ingress.md)).

## Caveats

- One-place edit per host: a single `hosts[]` entry (just `subdomain` + `backend`) renders that host's
  Gateway + listener + route (+ a SAN entry on the ingress's one shared cert); the resource names derive from
  the full host `<subdomain>.<domain>` (dots -> dashes), so there's nothing else to keep in sync.
- `sample-workload-sso` is only protected once the shared client secret is sealed: run
  `07_ingress/07_google_sso.sh` and commit (its allowlist lives in this chart's `values.yaml`, edit it
  there), or the policy references a missing Secret and login fails (see [07_ingress.md](07_ingress.md)).
- `prune` is data-safe: the Postgres PVCs use `local-path` with `reclaimPolicy: Retain`, so removing
  the app never destroys the node-local volumes under `/var/mnt/cnpg` (see
  [08_storage.md](08_storage.md)).
- No PITR until backups are wired (`cluster.backups.enabled: false`): durability rests on Postgres
  replication across the 2 instances; see [08_storage.md](08_storage.md).
