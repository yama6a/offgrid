# sample-user-manager, a real app + its Postgres behind the Gateway

The end-to-end sample workload. It proves the whole stack at once: a real app, its own database, both ingress
modes (open and SSO), Redis in both persistence modes, and a live RabbitMQ message loop.

Three workloads, one image, three binaries. The sample-app image bakes three binaries:

| Chart | Binary | Runs |
|---|---|---|
| `sample_user_manager` | `/manager` | the hub. Everything below, plus it consumes `create-user-command`, persists each user, and emits `users.created`/`users.deleted` on the `user-events` topic and audit messages on the `user-audit-logger` fanout |
| `sample_user_signup` | `/signup` | emits the command every 10s, consumes created + audit. Messaging only |
| `sample_audit_logger` | `/auditor` | consumes audit only. Messaging only |

The messaging topology and isolation live in [08_messaging.md](08_messaging.md). The rest of this doc is
`sample-user-manager`'s app, Postgres, Redis and ingress.

## What the chart ships

- App: a Deployment + Service running `/manager`, with the Postgres `app`-role password injected as
  `PG_PASSWORD` from the CNPG-generated Secret, plus the `RABBITMQ_*` and `WORKLOAD_NAME` env for the messaging
  hub. Serves `GET /users` (the persisted users as JSON) and `GET /audit`.
- Databases: two CloudNativePG `Cluster`s via the shared `pg-cluster` wrapper, on `longhorn-r2-ephemeral`.
  `sample-user-manager-db` is 3-instance synchronous HA and the one the binary dials;
  `sample-user-manager-analytics` is single-instance and never dialled, there to show multiple DBs per workload.
- Redis: two instances via the shared `redis-instance` wrapper, one per persistence mode.
  `sample-user-manager-redis-cache` is ephemeral (1h-TTL audit log, regenerable);
  `sample-user-manager-redis-sessions` is durable and enrolled in the central S3 RDB backup. See
  [09_redis.md](09_redis.md).
- Ingress: one ingress, two hosts, plain edges rendered by the shared `ingress` chart (see
  [04_ingress.md](04_ingress.md)), each host's Gateway folded onto the one shared Envoy via `mergeGateways`.
  This chart configures NO SSO; gating is central in `04_google_sso`:
    - `sample-user-manager.app.example.com` is OPEN, not listed in `04_google_sso`. The unprotected control.
    - `sample-user-manager-sso.app.example.com` is GATED, its subdomain listed in `04_google_sso` `hosts`.
      That chart's one `SecurityPolicy` targetRefs this route. Auth bounces via the shared
      `google-sso.example.com` callback host.

Both hosts front the same app Service.

Delivered purely by ArgoCD:

- `argo_apps/workloads/apps/templates/sample_user_manager.yaml`: the Application. A workload, so no `NN_` number and no
  `sync-wave`. See "Ordering".
- `argo_apps/workloads/charts/sample_user_manager/`: wraps `file://` dependencies on the shared `pg-cluster`,
  `redis-instance`, `rabbitmq-topology` and `ingress` charts, and adds one first-party template for the app. The
  stores and the ingress need no template of their own: each shared chart renders from its values block. Being
  `file://`-only, this chart is lockless and gitignores its `Chart.lock`.

## Namespaces: two, on purpose

| Resource | Namespace | Why |
|----------|-----------|-----|
| app Deployment + Service, CNPG `Cluster`s, `Redis` CRs, the generated `...-app` Secret, `ReferenceGrant` | `sample-user-manager` (the Application's `destination.namespace`, `CreateNamespace=true`) | the app must read `PG_PASSWORD` from a Secret in its own namespace, so app, stores and Secret co-locate |
| per-host `Gateway` + `:443` listener + `HTTPRoute`, one `Certificate` per ingress | `gateway` (the ingress chart's hardcoded namespace) | the merged-Envoy model and the central `04_google_sso` SecurityPolicy, which targetRefs these routes, require the routes in `gateway` |

So this is deliberately a multi-namespace Application. The HTTPRoutes in `gateway` reach the app Service in
`sample-user-manager` via a `ReferenceGrant`, the same cross-namespace pattern the platform-ingress app uses for
the argocd and monitoring UIs.

## The PG_PASSWORD wiring

Each `Cluster` is named by the wrapper's REQUIRED `name`, used verbatim, with no `.Release.Name` derivation. The
dialled DB is `sample-user-manager-db` (`app.dbs[0]`), so the CNPG operator generates the `app`-role credentials
into the Secret `sample-user-manager-db-app`. The Deployment injects only the password:

```yaml
env:
  - name: PG_PASSWORD
    valueFrom:
      secretKeyRef:
        name: sample-user-manager-db-app   # {{ index .Values.app.dbs 0 }}-app, the explicit instance name
        key: password
```

That Secret also carries `username`, `dbname`, `host`, `port` and `uri` if the app ever needs the full DSN. On a
cold start the app may briefly sit in `CreateContainerConfigError` until the operator finishes bootstrapping the
Cluster and writes the Secret. Expected, and it self-heals.

## Decisions

### Why one workload instead of an app and a DB demo

A real sample app needs a database, and the old split (an echo server plus a standalone CNPG cluster) never
exercised an app-to-DB path. One workload proves the full chain (ingress, open and SSO, to app to Postgres) and
is the template for any stateful app behind the Gateway. The CNPG operator stays a platform app
([05_storage.md](05_storage.md)); only the clusters live here.

### One-place edit: the whole ingress is a values list

Every HTTPS host needs its own `:443` listener, and that listener lives on the host's own Gateway rendered by the
`ingress` chart, folded onto the shared Envoy via `mergeGateways`, not on a shared Gateway in `03_gateway`.

What differs is the cert behind those listeners: HTTP-01 gives a per-ingress multi-SAN cert, while a Cloudflare
domain (DNS-01) shares one `*.<tier>` wildcard across every listener. See [04_ingress.md](04_ingress.md).

Adding a host is one `{ subdomain, targetService, targetPort }` under `hosts:`, where the host is
`<subdomain>.<domain>` and `subdomain: "@"` means the apex. A different domain is a new `ingresses[]` entry. The
chart renders Gateway, listener, cert and route together, so there is nothing to keep in step in `03_gateway`.

### Postgres via the `pg-cluster` wrapper

The workload templates no CNPG CRs. `lib/helm/pg-cluster` renders them and pre-bakes every value a workload
should not think about: the `longhorn-r2-ephemeral` class, hard hostname anti-affinity, synchronous replication
when HA, monitoring on, an `app`/`app` initdb, backups off until configured.

Each instance sets only the REQUIRED knobs, so a Postgres is about 7 lines rather than 40:

- `name`: the instance name, used verbatim.
- `postgresVersion`: the MAJOR (e.g. `"18"`), which the chart resolves to a pinned image via
  `files/postgres-images.yaml`.
- `highAvailability`: one bool. True means 3 instances + synchronous `any 1` + PDB + switchover, false means a
  single instance.
- `size`: the per-instance disk ceiling. Thin, so it reserves nothing.
- `resources`, `allowedClients`, `deletionProtection`.

A validation template fails the render with a clear message if a required knob is missing. Trade-off: the
pre-baked values are soft defaults a consumer could still override. Because `initdb` is a wrapper default, the app
template hardcodes `PG_USER` and `PG_DATABASE` to the literal `app`.

Explicit names, and multiple DBs per workload. The instance name drives the `<name>-rw`/`-ro`/`-r` Services, the
`<name>-app` Secret and the PodMonitor. No `-cluster` suffix, no `.Release.Name`, so nothing drifts and the DB is
decoupled from the release name.

To run more than one Postgres you alias the wrapper per DB in `Chart.yaml`. Helm renders a dependency once, so N
databases means N aliased entries; there is no values-list alternative. Each alias carries its own name, sizing
and allowlist. The `file://` deps use `version: "*"`, because for an in-repo dependency the version is a
required-but-inert constraint rather than a selector, and an exact pin would only force a bump here whenever the
local chart's version changed.

### Ordering: a workload, created after the platform

This workload needs the CNPG `Cluster` CRD and the Longhorn classes (platform wave 2), the shared Gateway
(`03_gateway`, wave 3), and `04_google_sso` (wave 4, whose per-domain `SecurityPolicy` already lists
`sample-user-manager-sso.app.example.com` and attaches once the route appears).

As a workload it gets that ordering without a `sync-wave`: the root-of-roots creates the workloads tree about 5s
after the platform tree. There is NO health gate, so if a CRD it needs is not registered yet, the first sync
fails and unbounded retry converges it. See [02_gitops.md](02_gitops.md).

### Storage

Both `Cluster`s run on `longhorn-r2-ephemeral`: `sample-user-manager-db` at 3 instances, one per Pi, with
synchronous streaming replication and a 10Gi ceiling each, and `sample-user-manager-analytics` as a single
instance with 5Gi. Both survive losing a machine without hands, for different reasons. Full reasoning in
[05_storage.md](05_storage.md).

### Network policy: default-deny both ways

This workload is where east-west lockdown is exercised; the cluster is otherwise default-allow, see
[01_networking.md](01_networking.md). Every `CiliumNetworkPolicy` here lists ingress AND egress, which makes its
endpoints deny-by-default in each direction, then allows only what is needed.

App (`sample-user-manager`, in this chart's `templates/networkpolicy.yaml`):

- Ingress only from the merged Envoy data-plane pod in `envoy-gateway-system`, on 8080.
- Egress only to CoreDNS (53) and the shared RabbitMQ broker (5672).
- Postgres and Redis egress is deliberately NOT listed. Each store's own chart renders a client-egress CNP from
  its `allowedClients`, so `allowedClients` is the single source of truth for the app-to-store edge in both
  directions, and this policy names no store.
- No monitoring rule: the app has no metrics port and nothing scrapes it.
- Not toggleable. There is no situation where we would want the app reachable from arbitrary sources.

Stores: each store's lockdown lives in its shared wrapper, not here, because it is reusable. Every
Postgres-backed instance inherits `lib/helm/pg-cluster/templates/networkpolicy.yaml` and every Redis inherits
the redis-instance equivalent, each CNP named after the instance so aliased stores do not collide. Always
enforced, never disableable: a database has no business being reachable from arbitrary sources, and there is no
"open to the world" mode.

For Postgres that means ingress on 5432 from the app and the replication peer, plus what CNPG needs to stay
healthy: the operator's status/probe API on 8000 (from `cnpg-system` and from the kubelet as `host`/`remote-node`)
and the metrics scrape on 9187 from vmagent. Egress: CoreDNS, the peer instance on 5432, and `toEntities:
[kube-apiserver]` for the instance-manager. Using a CNP rather than a vanilla `NetworkPolicy` is deliberate: the
`kube-apiserver` entity avoids hardcoding the API-server IP.

`allowedClients` is REQUIRED and validated non-empty, since an empty list would wall off the store. Besides the
ingress rule on the store pods it renders a companion client-egress CNP opening the app pod's egress to that
store, so the workload never re-lists its stores. Same-namespace only, because a namespaced CNP cannot select a
cross-namespace client, so an entry is just its `matchLabels` and a stray `namespace:` key fails the render.

The fixed platform selectors (Envoy, CoreDNS, the CNPG operator, vmagent) are hardcoded in the templates. They
are cluster constants, not per-workload knobs, so values carry only the real decision.

Rollout is audit-first: put the endpoints in Cilium `PolicyAuditMode` so drops are logged rather than enforced,
watch `hubble observe --verdict DROPPED,AUDIT` while exercising every path, and disable audit once clean. If a
platform component was relabelled and a legitimate flow shows AUDIT, fix the selector in the template.

## Apply and verify

1. Point each host's public DNS at the home router, and forward `:80` to the Gateway IP so HTTP-01 can issue.
   The `:443` listener ships with the host's own Gateway, see [04_ingress.md](04_ingress.md).
2. `git add -A && git commit && git push`. ArgoCD applies the workload via the workloads tree. If a CRD it needs
   is not registered yet, the first sync fails and retries until it is.

Checks, with `export KUBECONFIG=secrets/kubeconfig`:

```bash
kubectl -n sample-user-manager get cluster,redis,pods     # 2 clusters, 2 redis, the app pod Running
kubectl -n sample-user-manager get secret sample-user-manager-db-app     # the source of PG_PASSWORD
kubectl -n sample-user-manager get ciliumnetworkpolicy    # app + one per store, plus the client-egress pairs
kubectl -n gateway get certificate                        # READY=True once DNS + the :80 forward exist
```

- `https://sample-user-manager.app.example.com/` serves the app with no login. The open control.
- `https://sample-user-manager-sso.app.example.com/` bounces to Google via `google-sso.example.com`. An
  allowlisted account reaches the app; a non-listed one is denied. See [04_ingress.md](04_ingress.md).

## Caveats

- One-place edit per host: a single `hosts[]` entry renders that host's Gateway, listener and route, plus a SAN
  entry on the ingress's shared cert. Resource names derive from the full host with dots turned to dashes, so
  there is nothing else to keep in sync.
- The `-sso` host is gated centrally, not here. Its subdomain must be listed in `04_google_sso` `hosts`, and
  the shared client secret sealed via `lib/shell/04_google_sso.sh`. Unlisted means the host is OPEN; unsealed
  means login fails.
- `prune` is data-safe because every stateful unit sets `deletionProtection: true`, which stamps
  `Prune=false,Delete=false`. Removing the app ORPHANS the Postgres Clusters and Redis instances, still running
  on their volumes, rather than deleting them, and restoring the files re-adopts them. This is NOT the storage
  class doing it: `longhorn-r2-ephemeral` is `reclaimPolicy: Delete`. See [05_storage.md](05_storage.md).
- Point-in-time recovery comes from the wrapper's `backupsEnabled` (default true), which only renders once
  `lib/helm/pg-cluster/files/backup.yaml` is populated by `10b_cnpg_backup.sh`. Until then durability rests on
  Postgres replication across the 3 instances plus Longhorn's 2 volume replicas. See
  [10_backups.md](10_backups.md).
