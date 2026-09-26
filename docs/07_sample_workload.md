# sample-user-manager, a real app and its Postgres behind the Gateway

The end-to-end sample workload. It tests the whole stack at once:

- a real app with its own database
- both ingress modes, open and behind SSO
- Redis in both persistence modes
- a live RabbitMQ message loop

There are three workloads. The sample-app image holds three binaries, one per workload:

| Chart | Binary | Runs |
|---|---|---|
| `sample_user_manager` | `/manager` | The hub. Everything below. It also consumes `create-user-command`, stores each user, emits `users.created` and `users.deleted` on the `user-events` topic, and emits audit messages on the `user-audit-logger` fanout |
| `sample_user_signup` | `/signup` | Emits the command every 10s. Consumes created and audit messages. Messaging only |
| `sample_audit_logger` | `/auditor` | Consumes audit messages only. Messaging only |

The messaging topology and isolation are in [08_messaging.md](08_messaging.md). The rest of this doc covers the app,
Postgres, Redis and ingress of `sample-user-manager`.

## What the chart ships

- **App:** a Deployment and a Service that run `/manager`. The Deployment injects the Postgres `app`-role password
  as `PG_PASSWORD` from the Secret that CNPG generates. It also sets the `RABBITMQ_*` and `WORKLOAD_NAME` env vars
  for the messaging hub. The app serves `GET /users`, the stored users as JSON, and `GET /audit`.
- **Databases:** two CloudNativePG (CNPG) `Cluster`s through the shared `pg-cluster` wrapper chart, on
  `longhorn-r2-ephemeral`.
  - `sample-user-manager-db` has 3 instances with synchronous replication. The binary connects to this one.
  - `sample-user-manager-analytics` has a single instance, and nothing connects to it. It shows that one workload
    can have several databases.
- **Redis:** two instances through the shared `redis-instance` wrapper, one per persistence mode. See
  [09_redis.md](09_redis.md).
  - `sample-user-manager-redis-cache` is ephemeral. It holds an audit log with a 1h TTL, which the app can rebuild.
  - `sample-user-manager-redis-sessions` is durable, and the central S3 RDB backup includes it.
- **Ingress:** one ingress with two hosts. The shared `ingress` chart renders plain edges for them, see
  [04_ingress.md](04_ingress.md). `mergeGateways` folds the Gateway of each host onto the one shared Envoy. This
  chart configures no SSO. `04_google_sso` gates hosts centrally:
  - `sample-user-manager.app.example.com` is open, because `04_google_sso` does not list it. It is the unprotected
    control.
  - `sample-user-manager-sso.app.example.com` is gated, because `04_google_sso` lists its subdomain in `hosts`.
    That chart's one `SecurityPolicy` has a `targetRef` to this route. The login redirects through the shared
    `google-sso.example.com` callback host.

Both hosts front the same app Service.

Argo CD delivers everything:

- `argo_apps/workloads/apps/templates/sample_user_manager.yaml` is the Application. It is a workload, so it has no
  `NN_` number and no `sync-wave`. See [Ordering](#ordering-a-workload-created-after-the-platform).
- `argo_apps/workloads/charts/sample_user_manager/` wraps `file://` dependencies on the shared `pg-cluster`,
  `redis-instance`, `rabbitmq-topology` and `ingress` charts. It adds one first-party template for the app. The
  stores and the ingress need no template of their own, because each shared chart renders from its values block.
  All its dependencies are `file://`, so the chart has no lock file and gitignores `Chart.lock`.

## Namespaces: two, on purpose

| Resource | Namespace | Why |
|----------|-----------|-----|
| app Deployment and Service, CNPG `Cluster`s, `Redis` CRs, the generated `...-app` Secret, `ReferenceGrant` | `sample-user-manager`, the Application's `destination.namespace`, with `CreateNamespace=true` | The app reads `PG_PASSWORD` from a Secret in its own namespace, so the app, the stores and the Secret share a namespace |
| `Gateway` per host with its `:443` listener, `HTTPRoute`, one `Certificate` per ingress | `gateway`, the namespace hardcoded in the ingress chart | The merged-Envoy model and the central `04_google_sso` SecurityPolicy, which targets these routes, need the routes in `gateway` |

So this Application spans two namespaces on purpose. The HTTPRoutes in `gateway` reach the app Service in
`sample-user-manager` through a `ReferenceGrant`. The platform-ingress app uses the same cross-namespace pattern for
the Argo CD and monitoring UIs.

## The PG_PASSWORD wiring

The wrapper names each `Cluster` after its required `name` value, used as is, with no `.Release.Name` prefix. The
database the app uses is `sample-user-manager-db` (`app.dbs[0]`). So the CNPG operator writes the `app`-role
credentials into the Secret `sample-user-manager-db-app`. The Deployment injects only the password:

```yaml
env:
  - name: PG_PASSWORD
    valueFrom:
      secretKeyRef:
        name: sample-user-manager-db-app   # {{ index .Values.app.dbs 0 }}-app, the explicit instance name
        key: password
```

That Secret also holds `username`, `dbname`, `host`, `port` and `uri`, if the app ever needs the full DSN. On a
cold start the app pod can sit in `CreateContainerConfigError` for a short time. That lasts until the operator
bootstraps the Cluster and writes the Secret. This is expected, and it clears by itself.

## Decisions

### Why one workload instead of an app and a DB demo

A real sample app needs a database, and a separate database demo would not test the path from app to database. One
workload tests the full chain: ingress, open and behind SSO, to the app, to Postgres. It is also the template for
any stateful app behind the Gateway. The CNPG operator stays a platform app, see [05_storage.md](05_storage.md).
Only the database clusters live here.

### One-place edit: the whole ingress is a values list

Every HTTPS host needs its own `:443` listener. That listener is on the host's own Gateway, which the `ingress`
chart renders and `mergeGateways` folds onto the shared Envoy. It is not on a shared Gateway in `03_gateway`.

The cert behind those listeners depends on the domain. HTTP-01 gives one multi-SAN cert per ingress. A Cloudflare
domain (DNS-01) shares one `*.<tier>` wildcard across every listener. See [04_ingress.md](04_ingress.md).

To add a host, add one `{ subdomain, targetService, targetPort }` entry under `hosts:`. The host is
`<subdomain>.<domain>`, and `subdomain: "@"` means the apex. A different domain needs a new `ingresses[]` entry.
The chart renders the Gateway, listener, cert and route together, so nothing in `03_gateway` needs to change.

### Postgres via the `pg-cluster` wrapper

The workload templates no CNPG resources. `lib/helm/pg-cluster` renders them. It also sets every value a workload
should not have to think about:

- the `longhorn-r2-ephemeral` storage class
- hard hostname anti-affinity
- synchronous replication when `highAvailability` is on
- monitoring on
- an initdb with database `app` and owner `app`
- backups off until configured

Each instance sets only the required knobs, so a Postgres is about 7 lines instead of 40:

- `name`: the instance name, used as is.
- `postgresVersion`: the major version, for example `"18"`. The chart maps it to a pinned image through
  `files/postgres-images.yaml`.
- `highAvailability`: one bool. True means 3 instances, synchronous `any 1` replication, a PodDisruptionBudget
  and switchover. False means a single instance.
- `size`: the disk ceiling per instance. The volume is thin, so it reserves nothing.
- `resources`, `allowedClients`, `deletionProtection`.

A validation template fails the render with a clear message if a required knob is missing. Trade-off: a consumer
can still override the preset values. `initdb` is a wrapper default, so the app template hardcodes `PG_USER` and
`PG_DATABASE` to the literal `app`.

Instance names are explicit, and one workload can have several databases. The instance name sets these names:

- the `<name>-rw`, `<name>-ro` and `<name>-r` Services
- the `<name>-app` Secret
- the PodMonitor

There is no `-cluster` suffix and no `.Release.Name` prefix. So the names do not drift, and the database does not
depend on the release name.

To run more than one Postgres, add one alias of the wrapper per database in `Chart.yaml`. Helm renders a
dependency once, so N databases need N aliased entries. A values list cannot do it. Each alias carries its own
name, sizing and allowlist.

The `file://` dependencies use `version: "*"`. For an in-repo dependency, Helm requires a version but does not use
it to select anything. An exact pin would only force a bump here each time the local chart's version changed.

### Ordering: a workload, created after the platform

This workload needs:

- the CNPG `Cluster` CRD and the Longhorn storage classes, from platform wave 2
- the shared Gateway, `03_gateway` at wave 3
- `04_google_sso` at wave 4. Its per-domain `SecurityPolicy` already lists
  `sample-user-manager-sso.app.example.com` and attaches once the route exists.

As a workload, it gets that order without a `sync-wave`. The root-of-roots creates the workloads tree about 5s after
the platform tree. There is no health gate. If a CRD it needs is not registered yet, the first sync fails, and
unbounded retry brings it to a synced state. See [02_gitops.md](02_gitops.md).

### Storage

Both `Cluster`s run on `longhorn-r2-ephemeral`:

| Cluster | Instances | Size | Postgres replication |
|---|---|---|---|
| `sample-user-manager-db` | 3, one per Pi | 10Gi each | synchronous streaming |
| `sample-user-manager-analytics` | 1 | 5Gi | none |

Both survive the loss of a machine with no manual step, for different reasons. The full reasons are in
[05_storage.md](05_storage.md).

### Network policy: default-deny both ways

This workload is where east-west lockdown is tested. The rest of the cluster allows by default, see
[01_networking.md](01_networking.md). Every `CiliumNetworkPolicy` (CNP) here lists ingress and egress rules. That
makes its endpoints deny by default in each direction. The rules then allow only what is needed.

App policy, in `templates/networkpolicy.yaml` of this chart:

- Ingress only from the merged Envoy data-plane pod in `envoy-gateway-system`, on port 8080.
- Egress only to CoreDNS (53) and the shared RabbitMQ broker (5672).
- No Postgres or Redis egress, on purpose. The chart of each store renders a client-egress CNP from its
  `allowedClients`. So `allowedClients` is the single source for the edge from app to store, in both directions,
  and this policy names no store.
- No monitoring rule. The app has no metrics port, and nothing scrapes it.
- No toggle. The app must never be reachable from arbitrary sources.

Store policies live in the shared wrapper charts, not here, because they are reusable. Every Postgres instance gets
`lib/helm/pg-cluster/templates/networkpolicy.yaml`. Every Redis gets the `redis-instance` equivalent. Each CNP is
named after its instance, so aliased stores do not collide. The policies are always enforced and cannot be turned
off. A database must never be reachable from arbitrary sources, so there is no open mode.

For Postgres, the policy allows:

- **Ingress:** port 5432 from the app and the replication peer. Port 8000, the operator's status and probe API,
  from `cnpg-system` and from the kubelet as `host` or `remote-node`. Port 9187 for the vmagent metrics scrape.
- **Egress:** CoreDNS, the peer instance on 5432, and `toEntities: [kube-apiserver]` for the instance manager.

The policy is a CNP and not a plain `NetworkPolicy` on purpose. The `kube-apiserver` entity avoids a hardcoded API
server IP.

`allowedClients` is required, and the chart validates that it is not empty, because an empty list would cut off the
store. Besides the ingress rule on the store pods, it renders a companion client-egress CNP. That CNP opens the app
pod's egress to the store, so the workload never lists its stores again. Clients must be in the same namespace,
because a namespaced CNP cannot select a client in another namespace. So an entry is only its `matchLabels`, and a
stray `namespace:` key fails the render.

The templates hardcode the fixed platform selectors: Envoy, CoreDNS, the CNPG operator and vmagent. They are
cluster constants, not per-workload knobs, so the values carry only the real decision.

Roll out in audit mode first:

1. Put the endpoints in Cilium `PolicyAuditMode`, so Cilium logs drops instead of enforcing them.
2. Run `hubble observe --verdict DROPPED,AUDIT` while you exercise every path.
3. Turn off audit mode once no unexpected flow shows up.

If a platform component got new labels and a legitimate flow shows `AUDIT`, fix the selector in the template.

## Apply and verify

1. Point the public DNS of each host at the home router. Forward `:80` to the Gateway IP so HTTP-01 can issue. The
   `:443` listener ships with the host's own Gateway, see [04_ingress.md](04_ingress.md).
2. Run `git add -A && git commit && git push`. Argo CD applies the workload through the workloads tree. If a CRD it
   needs is not registered yet, the first sync fails and retries until it is.

Checks, with `export KUBECONFIG=.cache/kubeconfig`:

```bash
kubectl -n sample-user-manager get cluster,redis,pods     # 2 clusters, 2 redis, the app pod Running
kubectl -n sample-user-manager get secret sample-user-manager-db-app     # the source of PG_PASSWORD
kubectl -n sample-user-manager get ciliumnetworkpolicy    # app, one per store, and the client-egress pairs
kubectl -n gateway get certificate                        # READY=True once DNS and the :80 forward exist
```

- `https://sample-user-manager.app.example.com/` serves the app with no login. It is the open control.
- `https://sample-user-manager-sso.app.example.com/` redirects to Google through `google-sso.example.com`. An
  allowlisted account reaches the app. Any other account is denied. See [04_ingress.md](04_ingress.md).

## Caveats

- **One entry per host.** A single `hosts[]` entry renders the host's Gateway, listener and route, and adds a SAN
  to the shared cert of the ingress. Resource names come from the full host, with dots turned into dashes. So
  nothing else needs to stay in sync.
- **The `-sso` host is gated centrally, not here.** `04_google_sso` must list its subdomain in `hosts`, and
  `lib/shell/04_google_sso.sh` must seal the shared client secret. If the subdomain is not listed, the host is
  open. If the secret is not sealed, the login fails.
- **`prune` is safe for data.** Every stateful unit sets `deletionProtection: true`, which stamps
  `Prune=false,Delete=false`. If you remove the app, the Postgres Clusters and Redis instances become orphans that
  keep running on their volumes. Argo CD does not delete them. Restoring the files adopts them again. The storage
  class does not cause this, because `longhorn-r2-ephemeral` has `reclaimPolicy: Delete`. See
  [05_storage.md](05_storage.md).
- **Point-in-time recovery needs backups configured.** It comes from the wrapper's `backupsEnabled`, true by
  default. The backup resources render only after `10b_cnpg_backup.sh` fills
  `lib/helm/pg-cluster/files/backup.yaml`. Until then, durability rests on Postgres replication across the 3
  instances and on the 2 Longhorn volume replicas. See [10_backups.md](10_backups.md).
