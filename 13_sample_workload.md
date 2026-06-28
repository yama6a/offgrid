# 13 — sample-workload: a real app + its Postgres behind the Gateway

The cluster's one end-to-end **sample workload** — the merge of the old `gateway-test` demo and the
`cnpg-cluster` Postgres into a single chart. It proves the whole stack at once: a real app, its own
database, and both ingress modes (open + SSO). One chart ships three slices:

- **app** — a Deployment + Service running `ghcr.io/yama6a/pi5-k8s-sample-app:1`, with the Postgres
  `app`-role password injected as **`PG_PASSWORD`** from the CNPG-generated Secret.
- **database** — a CloudNativePG `Cluster` (the upstream `cnpg/cluster` dependency), 2-instance HA on the
  node-local `local-path` class — the same Postgres that used to be the standalone `cnpg-cluster` workload.
- **ingress** — two hosts, each owning its **own Gateway + `:443` listener** (folded onto the one shared
  Envoy via `mergeGateways`, see [11_envoy_gateway.md](11_envoy_gateway.md)):
  - **`sample-workload.example.com`** — OPEN (no `sso` label): the unprotected control.
  - **`sample-workload-sso.example.com`** — PROTECTED: its `HTTPRoute` is labelled `sso: "example.com"`,
    so the [`04_google_sso`](12_google_sso.md) `SecurityPolicy` gates it behind Google login + the
    example.com allowlist (auth bounces via the shared `google-sso.example.com` callback host).

Both hosts front the **same** app Service.

Delivered purely by ArgoCD:

- `argo_apps/workloads/apps/sample_workload.yaml` — the Application. A **workload** (in the workloads
  tree), so **no `NN_` number and no `sync-wave`** — see "Ordering" below.
- `argo_apps/workloads/charts/sample_workload/` — wraps the `cnpg/cluster` dependency (`Chart.lock`
  committed, vendored `charts/*.tgz` gitignored) and adds first-party templates for the app + ingress.

## Namespaces — two, on purpose

| Resource | Namespace | Why |
|----------|-----------|-----|
| app Deployment + Service, CNPG `Cluster`, generated `…-app` Secret, `ReferenceGrant` | **`sample-workload`** (the Application's `destination.namespace`, `CreateNamespace=true`) | the app must read `PG_PASSWORD` from a Secret in **its own** namespace, so app + DB + Secret co-locate. |
| per-host `Gateway` + `:443` listener, `Certificate`, `HTTPRoute` | **`gateway`** (explicit `metadata.namespace`) | the merged-Envoy model + the `04_google_sso` `SecurityPolicy` (which selects routes in **its own** namespace) require routes in `gateway`. |

So this is a deliberately **multi-namespace** Application. The HTTPRoutes (in `gateway`) reach the app
Service (in `sample-workload`) via a `ReferenceGrant` in `sample-workload` — the same cross-namespace
pattern `06_argocd_ingress` / `07_monitoring_ingress` use.

## The PG_PASSWORD wiring

The `cnpg/cluster` chart names the `Cluster` `<release>-cluster` → `sample-workload-cluster`, so the CNPG
operator generates the `app`-role credentials into the Secret **`sample-workload-cluster-app`**. The app
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
full DSN — only the password is injected here. On a cold start the app may briefly sit in
`CreateContainerConfigError` until the operator finishes bootstrapping the Cluster and writes the Secret,
then it starts — expected, self-heals.

## Decisions

### Why merge the two workloads
A real sample app needs a database; the old split (`gateway-test` echo + standalone `cnpg-cluster`) never
exercised an app→DB path. Merging gives one workload that proves the full chain — ingress (open + SSO) →
app → Postgres — and is the template for *any* stateful app behind the Gateway. The CNPG operator stays a
platform app ([17_cnpg.md](17_cnpg.md)); only the **cluster** moved here, into the `sample-workload`
namespace.

### One-place edit — each host owns its whole ingress slice
Per-host HTTP-01 (no wildcard without DNS-01) still means **every HTTPS host needs its own `:443`
listener** — but that listener lives on the host's **own Gateway** (`templates/gateway.yaml`), folded onto
the shared Envoy via `mergeGateways`, not on a shared Gateway in `03_gateway`. Adding a host is a single
`ingress.hosts[]` entry that renders its Gateway + listener + cert + route together — nothing to keep in
step in `03_gateway`.

### Ordering — a workload, gated behind the whole platform
This workload needs the CNPG operator's `Cluster` CRD + the `local-path` class (platform wave 2), the
Gateway listeners (`03_gateway`, platform wave 3) **and** the SSO policies (`04_google_sso`, platform wave
4) to already exist — otherwise the `Cluster` CR would hit a missing CRD, or `sample-workload-sso` could
be briefly exposed before its `SecurityPolicy` attaches. As a **workload** it gets all of that for free:
the root-of-roots only creates the workloads tree **after the entire platform is Synced + Healthy**, so
there's no per-app `sync-wave` to manage. See the two-tree model in [05_gitops.md](05_gitops.md) /
[CLAUDE.md](CLAUDE.md).

### Storage — node-local, off Longhorn
Unchanged from the old `cnpg-cluster`: the `Cluster` runs on the node-local `local-path` class (2
instances on 2 distinct Pi nodes, Postgres streaming replication as the only replication layer). The full
reasoning lives in [17_cnpg.md](17_cnpg.md) / [18_local_path_provisioner.md](18_local_path_provisioner.md).

## Apply / verify

1. Ensure each host's public DNS → home router and the old Pi forwards `:80` to the Gateway IP so HTTP-01
   issues its cert (the `:443` listener ships with the host's own Gateway — see [10_gateway.md](10_gateway.md)).
2. `helm dependency build argo_apps/workloads/charts/sample_workload` and commit the `Chart.lock` (ArgoCD's
   repo-server runs `helm dependency build`; a missing/stale lock breaks sync).
3. `git add -A && git commit && git push` — ArgoCD applies the workload via the workloads tree (once the
   platform is Healthy).

Checks (`export KUBECONFIG=03_operating_system/talos-cluster/kubeconfig`):

- `kubectl -n sample-workload get cluster,pods` → `sample-workload-cluster` with 2 instances Running on 2
  distinct nodes; the `sample-workload` app pod Running.
- `kubectl -n sample-workload get secret sample-workload-cluster-app` → exists (the source of `PG_PASSWORD`).
- `kubectl -n gateway get certificate sample-workload sample-workload-sso` → `READY=True` once DNS + the
  `:80` forward exist.
- `https://sample-workload.example.com/` → the app, **no login** (open control).
- `https://sample-workload-sso.example.com/` → **Google login** → bounce via `google-sso.example.com` → an
  allowlisted account reaches the app; a non-listed one is denied (see [12_google_sso.md](12_google_sso.md)).

## Caveats

- **One-place edit per host** — a single `ingress.hosts[]` entry renders the whole slice (Gateway +
  listener + cert + route), so keep its own fields consistent (`name`/`host`/`tlsSecretName`), or the
  route won't bind / the cert won't fill the listener's Secret.
- **`sample-workload-sso` is only protected once `04_google_sso` is configured** — run
  `12_google_sso/12_google_sso.sh` and commit, or the policy doesn't attach and the route is open (see
  [12_google_sso.md](12_google_sso.md)).
- **`prune` is data-safe** — the Postgres PVCs use `local-path` with `reclaimPolicy: Retain`, so removing
  the app never destroys the node-local volumes under `/var/mnt/cnpg` (see
  [18_local_path_provisioner.md](18_local_path_provisioner.md)).
- **No PITR until backups are wired** (`cluster.backups.enabled: false`) — durability rests on Postgres
  replication across the 2 instances; see [17_cnpg.md](17_cnpg.md).
