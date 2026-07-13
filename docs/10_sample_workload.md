# 10: sample-user-manager, a real app + its Postgres behind the Gateway

The cluster's end-to-end sample workload, the merge of the `gateway-test` demo and the
`cnpg-cluster` Postgres into a single chart. It proves the whole stack at once: a real app, its own
database, both ingress modes (open + SSO), **and** a live RabbitMQ message loop.

> **Three workloads, one image, three binaries.** The sample-app image bakes three binaries (see the
> pi5-k8s-sample-app repo). This chart, renamed **`sample-user-manager`** (`charts/sample_user_manager`), runs
> the default `/manager` binary — everything below, plus it's the hub of a user-lifecycle messaging demo: it
> consumes `create-user-command`, persists each user, and emits `users.created`/`users.deleted` on the
> `user-events` topic + audit messages on the `user-audit-logger` fanout. Two sibling charts
> **`sample-user-signup`** (`/signup` — emits the command every 10s, consumes created + audit) and
> **`sample-audit-logger`** (`/auditor` — consumes audit only) run the other binaries; both are messaging-only
> (no Postgres, no ingress). The messaging topology + isolation is documented in
> [11_messaging.md](11_messaging.md); the rest of this doc covers `sample-user-manager`'s app + Postgres + ingress.

`sample-user-manager` ships three slices:

- app: a Deployment + Service running the sample-app image's `/manager` binary, with the Postgres `app`-role
  password injected as `PG_PASSWORD` from the CNPG-generated Secret, plus the `RABBITMQ_*` + `WORKLOAD_NAME`
  env for the messaging hub. It serves `GET /users` (the persisted users as JSON).
- database: a CloudNativePG `Cluster` via the shared `pg-cluster` wrapper (which pins `cnpg/cluster` and
  pre-bakes the boilerplate; this workload sets only `type`/`instances`/`resources`), 2-instance HA on the
  node-local `local-path` class.
- ingress: one ingress, two hosts (plain edges rendered by the shared `ingress` library, see
  [07_ingress.md](07_ingress.md)), each host's Gateway folded onto the one shared Envoy via `mergeGateways`.
  This chart configures **no SSO** — gating is central in [`04_google_sso`](07_ingress.md):
  - `sample-user-manager.app.example.com`: OPEN — not listed in `04_google_sso`, the unprotected control.
  - `sample-user-manager-sso.app.example.com`: GATED — listed in `04_google_sso` `domains[].hosts` with its own
    allowlist; that chart's per-domain `SecurityPolicy` targetRefs this route and gates it. Auth bounces via
    the shared `google-sso.example.com` callback host.

Both hosts front the same app Service.

Delivered purely by ArgoCD:

- `argo_apps/workloads/apps/sample_workload.yaml`: the Application. A workload (in the workloads
  tree), so no `NN_` number and no `sync-wave`, see "Ordering" below.
- `argo_apps/workloads/charts/sample_workload/`: wraps two `file://` dependencies — the shared `pg-cluster`
  wrapper (which itself pins `cnpg/cluster`) and the shared `ingress` library (both `Chart.lock`-committed,
  vendored `charts/*.tgz` gitignored) — and adds a first-party template for the app plus a one-line
  `{{ include "ingress.render" . }}` for the ingress. The Postgres needs no template: `pg-cluster` renders
  the `Cluster` from the `pg-cluster:` values block. See the shared-charts section in [CLAUDE.md](../CLAUDE.md).

## Namespaces: two, on purpose

| Resource | Namespace | Why |
|----------|-----------|-----|
| app Deployment + Service, CNPG `Cluster`, generated `...-app` Secret, `ReferenceGrant` | `sample-workload` (the Application's `destination.namespace`, `CreateNamespace=true`) | the app must read `PG_PASSWORD` from a Secret in its own namespace, so app + DB + Secret co-locate. |
| per-host `Gateway` + `:443` listener + `HTTPRoute`, one `Certificate` per ingress | `gateway` (the library's hardcoded gateway namespace) | the merged-Envoy model + the central `04_google_sso` SecurityPolicy (which targetRefs these routes) require the routes in `gateway`. |

So this is a deliberately multi-namespace Application. The HTTPRoutes (in `gateway`) reach the app
Service (in `sample-workload`) via a `ReferenceGrant` in `sample-workload`, the same cross-namespace
pattern the platform-ingress app uses for the argocd + monitoring UIs.

## The PG_PASSWORD wiring

Each `Cluster` is named by the wrapper's REQUIRED `cluster.fullnameOverride` — an explicit name, no
`.Release.Name` derivation. The app's primary is `sample-workload-db` (its `app.db` value), so the CNPG
operator generates the `app`-role credentials into the Secret `sample-workload-db-app`. The app Deployment
injects only the password, referencing that same explicit name (`app.db`):

```yaml
env:
  - name: PG_PASSWORD
    valueFrom:
      secretKeyRef:
        name: sample-workload-db-app   # {{ .Values.app.db }}-app — the explicit instance name, not the release
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
but that listener lives on the host's own Gateway (rendered by the `ingress` library), folded onto
the shared Envoy via `mergeGateways`, not on a shared Gateway in `03_gateway`. Each ingress declares one
`domain`; adding a host is a single `{ subdomain, targetService, targetPort }` under its `hosts:` (host = `<subdomain>.<domain>`,
or `subdomain: "@"` for the apex). A different-domain group is a new `ingresses[]` entry with its own
`domain`. The library renders Gateway + listener + cert + route together (no SSO — that's central in
`04_google_sso`), nothing to keep in step in `03_gateway`.

### Postgres via the `pg-cluster` wrapper, not the raw `cnpg/cluster` chart
The workload doesn't depend on `cnpg/cluster` directly; it depends on the shared `pg-cluster` wrapper
(`lib/helm/pg-cluster`, see [CLAUDE.md](../CLAUDE.md)), which pins `cnpg/cluster` and pre-bakes every
value a workload shouldn't think about (node-local `local-path` storage + 45Gi, hostname anti-affinity,
monitoring on, an `app`/`app` initdb, backups off). Each instance sets only the REQUIRED knobs —
`cluster.fullnameOverride` (the instance name), `type`, `instances` (1 or 2), `resources` — so a Postgres is
~8 lines, not ~40. A validation template in the wrapper fails the render (with a clear message) if any required
knob is missing. Trade-off, inherent to wrapping a subchart (Helm can't transform or lock a child's values):
the pre-baked values are *soft* defaults a consumer could still override, and the values sit one level deeper
(`<alias>.cluster.cluster.*`). Because `initdb` is a wrapper default (a subchart default isn't visible at this
chart's scope), the app template hardcodes `PG_USER`/`PG_DATABASE` to the literal `app`.

**Explicit names, and multiple DBs per workload.** The instance name is the wrapper's own REQUIRED
`cluster.fullnameOverride` (cnpg/cluster's native field) — used verbatim (`<name>-rw`/`-ro`/`-r` Services,
`<name>-app` Secret, PodMonitor, PrometheusRule). There is no `-cluster` suffix and no `.Release.Name`
derivation: the app's `PG_HOST`/secret and the network policies all reference the explicit name, so nothing
drifts and the DB is decoupled from the release name. To run **more than one** Postgres in a workload you
alias the wrapper per DB in `Chart.yaml` — Helm renders a dependency once, so N databases means N aliased
`pg-cluster` entries (there's no values-list alternative). This sample declares two: `maindb`
(`sample-workload-db`, 2-instance HA, the app's primary — `app.db`) and `analyticsdb`
(`sample-workload-analytics`, single-instance, a second store the app is *permitted* to reach via `app.extraDbs`
but the sample binary doesn't dial). Each alias carries its own name, sizing, and DB-lockdown allowlist. (The
file:// deps use `version: "*"` — for a local-path dependency the version is a required-but-inert constraint,
not a selector, so an exact pin would only force a bump here whenever the local chart's version changes.)

### Ordering: a workload, gated behind the whole platform
This workload needs the CNPG operator's `Cluster` CRD + the `local-path` class (platform wave 2), the
shared `:80` Gateway (`03_gateway`, platform wave 3), and `04_google_sso` (platform wave 4, whose per-domain
`SecurityPolicy` already lists `sample-user-manager-sso.app.example.com` and attaches to this route once it appears)
to already exist, otherwise the `Cluster` CR would hit a missing CRD, or login would fail with no callback.
As a workload it gets all of that for free:
the root-of-roots only creates the workloads tree after the entire platform is Synced + Healthy, so
there's no per-app `sync-wave` to manage. See the two-tree model in [05_gitops.md](05_gitops.md) /
[CLAUDE.md](../CLAUDE.md).

### Storage: node-local, off Longhorn
Both `Cluster`s run on the node-local `local-path` class (the primary `sample-workload-db` at 2 instances on 2
distinct Pi nodes with Postgres streaming replication; the single-instance `sample-workload-analytics` with no
replica). The full reasoning lives in [08_storage.md](08_storage.md).

### Network policy: the cluster's first CiliumNetworkPolicy lockdown
This workload is where east-west lockdown is exercised (the cluster is otherwise default-allow — see
[04_networking.md](04_networking.md)). Three `CiliumNetworkPolicy` objects (one app + one per DB), all in the
`sample-workload` namespace, each default-deny both directions (a CNP that lists ingress *and* egress makes its
endpoints deny-by-default in each), then allow only what's needed:

- **App** (`sample-workload-app`, in this chart's `templates/networkpolicy.yaml`): ingress ONLY from the
  merged Envoy data-plane pod (`envoy-gateway-system`) on 8080; egress ONLY to CoreDNS (53) and its
  Postgres instances on 5432 — one rule per DB it may reach (`app.db` + `app.extraDbs`). No monitoring rule —
  the app has no metrics port and nothing scrapes it (add one here if that changes). Not toggleable — there's
  no situation where we'd want the app reachable from arbitrary sources.
- **DB** (one per instance — `sample-workload-db`, `sample-workload-analytics`): lives in the shared
  **`pg-cluster`** wrapper, not here — DB lockdown is reusable, so every Postgres-backed instance inherits it
  (`lib/helm/pg-cluster/templates/networkpolicy.yaml`); the CNP is named after the instance so aliased DBs
  don't collide.
  It is **always enforced, not disableable** (a database has no business being reachable from arbitrary
  sources; there is no "open to the world" mode). A consumer just supplies its `allowedClients` — REQUIRED,
  validated non-empty like `type`/`instances`/`resources`. Ingress: 5432 from the app + replication peer, plus
  the flows CNPG needs to stay healthy — the operator's status/probe API (8000, from `cnpg-system` and from the
  kubelet as `host`/`remote-node`) and the metrics scrape (9187, from vmagent). Egress: CoreDNS, the
  peer instance (5432), and `toEntities: [kube-apiserver]` for the instance-manager. Using a CNP (not a vanilla
  `NetworkPolicy`) is deliberate: the `kube-apiserver` entity avoids hardcoding the API-server IP.

`allowedClients` is validated (render fails on an empty list — you'd wall off the database). The fixed platform
selectors (Envoy, CoreDNS, the CNPG operator, vmagent) are hardcoded in the templates — they're cluster
constants, not per-workload knobs; values carry only the one real decision (the DB's `allowedClients`).
**Rollout is audit-first**: put the app + DB endpoints in Cilium
`PolicyAuditMode` (drops logged, not enforced), watch `hubble observe --verdict DROPPED,AUDIT` while exercising
every path, and only disable audit once clean. If a platform component was relabelled and a legitimate flow
shows AUDIT, fix the selector in the template.

## Apply / verify

1. Ensure each host's public DNS -> home router and the old Pi forwards `:80` to the Gateway IP so HTTP-01
   issues its cert (the `:443` listener ships with the host's own Gateway, see [07_ingress.md](07_ingress.md)).
2. `helm dependency build argo_apps/workloads/charts/sample_workload` and commit the `Chart.lock` (ArgoCD's
   repo-server runs `helm dependency build`; a missing/stale lock breaks sync).
3. `git add -A && git commit && git push`, ArgoCD applies the workload via the workloads tree (once the
   platform is Healthy).

Checks (`export KUBECONFIG=secrets/kubeconfig`):

- `kubectl -n sample-workload get cluster,pods` -> two clusters: `sample-workload-db` (2 instances on 2
  distinct nodes) and `sample-workload-analytics` (1 instance); the `sample-workload` app pod Running.
- `kubectl -n sample-workload get secret sample-workload-db-app` -> exists (the source of `PG_PASSWORD`).
- `kubectl -n sample-workload get ciliumnetworkpolicy` -> `sample-workload-app`, `sample-workload-db`,
  `sample-workload-analytics`.
- `kubectl -n gateway get certificate sample-workload sample-workload-sso` -> `READY=True` once DNS + the
  `:80` forward exist.
- `https://sample-user-manager.app.example.com/` -> the app, no login (open control).
- `https://sample-user-manager-sso.app.example.com/` -> Google login -> bounce via `google-sso.example.com` -> an
  allowlisted account reaches the app; a non-listed one is denied (see [07_ingress.md](07_ingress.md)).

## Caveats

- One-place edit per host: a single `hosts[]` entry (`subdomain` + `targetService`/`targetPort`) renders that host's
  Gateway + listener + route (+ a SAN entry on the ingress's one shared cert); the resource names derive from
  the full host `<subdomain>.<domain>` (dots -> dashes), so there's nothing else to keep in sync.
- `sample-workload-sso` is gated centrally, not here: it must be listed in `04_google_sso` `domains[].hosts`
  (with its allowlist), and the shared client secret sealed via `lib/shell/07_google_sso.sh`. If it's not
  listed, the host is OPEN; if the secret isn't sealed, login fails (see [07_ingress.md](07_ingress.md)).
- `prune` is data-safe: the Postgres PVCs use `local-path` with `reclaimPolicy: Retain`, so removing
  the app never destroys the node-local volumes under `/var/mnt/localpath` (see
  [08_storage.md](08_storage.md)).
- No PITR until backups are wired (`backups.enabled: false`, hardcoded in the `pg-cluster` wrapper):
  durability rests on Postgres replication across the 2 instances; see [08_storage.md](08_storage.md).
