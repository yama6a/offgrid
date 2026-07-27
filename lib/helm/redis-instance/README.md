# redis-instance

Shared wrapper chart that renders **one** standalone OpsTree `Redis` instance for a workload:

- the `Redis` CR (`redis.redis.opstreelabs.in/v1beta2`) — a single-pod StatefulSet + one PVC, reconciled by the
  platform's `03_redis_operator`,
- a `ServiceMonitor` scraping its redis-exporter sidecar (auto-converted to a VMServiceScrape, scraped by vmagent),
- a default-deny `CiliumNetworkPolicy` that is the instance's **only** access control (there is no password).

First-party chart — no upstream dependency, no `Chart.lock`, no vendored tgz. The Redis CRD comes from the operator.

A **REQUIRED `persistence`** flag (no default) picks the mode: `true` = durable (storage class
`longhorn-r2-retained`, `reclaimPolicy: Retain`, + AOF `everysec`); `false` = ephemeral cache
(`longhorn-r2-ephemeral`, `reclaimPolicy: Delete`, RDB-only, no AOF). Both classes are 2-replica and shipped by
the platform's `02_longhorn` app. Almost everything else is **hardcoded in the templates** (single source of
truth, updated for every instance at once): the image repo, the redis-exporter's full ref, `maxmemory` (80% of the
memory limit, `noeviction`), the non-root uid/gid 1000 security context, and no-auth. A workload sets five
**required** knobs (`name`, `redisVersion`, `resources`, `allowedClients`, `persistence`), plus an optional create-time
`initialFixedDiskSize`. `redisVersion` is the Redis SERVER version, owned per-workload (no shared default). It is a
single standalone instance, no HA/replication. **Durable** (`persistence: true`) instances are labelled
`redis-backup.raspi-cluster/enabled` and backed up to S3 centrally by the platform's `07_redis_backup` app,
nothing to configure per instance (see `docs/12_redis.md` / `docs/13_backups.md`).

## Using it in a workload

Consumed exactly like `pg-cluster`: an **aliased `file://` dependency, once per instance** (the alias is the values
key). "One or more Redis" == "one or more aliases".

**1. `Chart.yaml`** — one entry per instance:

```yaml
dependencies:
  - name: redis-instance
    alias: redis-cache
    version: "*"
    repository: "file://../../../../lib/helm/redis-instance"
  - name: redis-instance
    alias: redis-sessions
    version: "*"
    repository: "file://../../../../lib/helm/redis-instance"
```

Commit the resulting `Chart.lock` (`helm dependency update`) and gitignore `charts/*.tgz` — ArgoCD's repo-server
runs `helm dependency build`.

**2. `values.yaml`** — one block per alias, the required knobs (+ `initialFixedDiskSize` if the 1Gi default is too
small):

```yaml
redis-cache:
  name: sample-user-manager-redis-cache  # also the Service DNS: sample-user-manager-redis-cache.<ns>.svc.cluster.local:6379
  # renovate: datasource=docker depName=quay.io/opstree/redis
  redisVersion: "v8.6.2"                 # REQUIRED: Redis server version, owned per-workload
  resources:
    requests: { cpu: 25m, memory: 64Mi }
    limits: { memory: 96Mi }           # a memory limit is required — maxmemory is 80% of it
  allowedClients:
    - namespace: sample-user-manager
      matchLabels: { app: sample-user-manager }
  persistence: true                      # REQUIRED, no default: true = durable (Retain + AOF) | false = ephemeral cache (Delete, RDB-only)
  # initialFixedDiskSize: 2Gi            # optional; default 1Gi; CREATE-TIME ONLY (see docs/12_redis.md)
```

No template is needed in the consumer.

## Knobs (the complete list)

| Key                    | Required | Default | Notes                                                                                                                                                            |
|------------------------|----------|---------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `name`                 | yes      | -       | instance + Service name; unique per workload                                                                                                                     |
| `redisVersion`         | yes      | -       | Redis SERVER image tag (e.g. `v8.6.2`), owned per-workload; repo + exporter stay pinned in the chart                                                             |
| `resources`            | yes      | -       | per-pod requests/limits (set a memory limit)                                                                                                                     |
| `allowedClients`       | yes      | -       | who may reach `:6379`, the only access control                                                                                                                   |
| `persistence`          | yes      | -       | `true` = durable (Retain class + AOF); `false` = ephemeral cache (Delete class, RDB-only)                                                                        |
| `initialFixedDiskSize` |          | `1Gi`   | PVC size **at creation only**; changing it on a live instance has no effect (the storage class is fixed); grow via manual PVC expansion, see `docs/12_redis.md`  |

Everything else (the image repo, the redis-exporter's full ref, `maxmemory`, security context, no-auth) is pinned in
`templates/redis.yaml` / `templates/configmap.yaml` / `templates/networkpolicy.yaml`; the storage class + AOF follow
`persistence`. The server image tag is per-workload (`redisVersion`). To bump the repo/exporter for all instances, or to
add a `requirepass` password, edit the template. See `docs/12_redis.md` for the design rationale.
