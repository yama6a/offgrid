# sample-user-manager, a real app and its Postgres behind the Gateway

The sample workload tests the whole stack at once: an app with its own databases, both ingress modes, Redis in both
persistence modes, and a live RabbitMQ message loop. It is also the template for any stateful app behind the Gateway.
To deploy and check it, see [runbooks/07_sample_workload.md](runbooks/07_sample_workload.md).

One sample-app image holds three binaries, one per workload:

| Chart | Binary | Role |
|---|---|---|
| `sample_user_manager` | `/manager` | The hub. HTTP, Postgres, Redis, and every exchange of the message loop |
| `sample_user_signup` | `/signup` | Sends a create-user command every 10s. Messaging only |
| `sample_audit_logger` | `/auditor` | Reads audit messages. Messaging only |

The message loop is in [08_messaging.md](08_messaging.md). This doc covers `sample-user-manager`.

## What it runs

- **App:** a Deployment and a Service for `/manager`.
- **Postgres:** two CNPG clusters. `sample-user-manager-db` has 3 synchronous instances, and the app uses it.
  `sample-user-manager-analytics` has 1 instance and no client. It shows that a workload can own several databases.
- **Redis:** `redis-cache` is ephemeral and `redis-sessions` is durable, one per persistence mode. See
  [09_redis.md](09_redis.md).
- **Ingress:** two hosts on the same Service. `sample-user-manager` is open and is the control.
  `sample-user-manager-sso` is behind Google SSO.

## Decisions

### One workload, not an app demo and a database demo

A separate database demo would not test the path from app to database. One workload tests the full chain: ingress,
open and behind SSO, to the app, to Postgres. The CNPG operator stays a platform app. Only the clusters live here.

### The shared charts render everything except the app

The chart has one template of its own, for the app. `pg-cluster`, `redis-instance`, `rabbitmq-topology` and `ingress`
render the rest from values blocks.

- A Postgres is about 7 lines of values instead of 40. The chart presets storage class, anti-affinity, monitoring,
  initdb and backups.
- Instance names are used as is, with no release prefix. So Service and Secret names do not drift with the release.
- Each store is one alias of its shared chart, because Helm renders a dependency once.
- A new host is one `hosts[]` entry. The `ingress` chart renders its Gateway, listener, cert SAN and route together,
  so nothing in `03_gateway` changes. See [04_ingress.md](04_ingress.md).

### Two namespaces

| Resources | Namespace | Why |
|---|---|---|
| app, databases, Redis, the generated Secrets | `sample-user-manager` | The app reads its database password from a Secret, which must be in its own namespace |
| Gateway, HTTPRoute, Certificate | `gateway` | The merged Envoy and the central SSO `SecurityPolicy` need the routes there |

A `ReferenceGrant` lets the routes in `gateway` reach the app Service. The platform UIs use the same pattern.

### No sync wave

The workload needs CRDs and the Gateway from platform waves 2 to 4. Argo CD creates the workloads tree about 5s after
the platform tree, with no health gate. A sync that runs before a CRD exists fails, and unbounded retry converges it.
See [02_gitops.md](02_gitops.md).

### Network policy: default-deny both ways

This workload is where east-west lockdown is tested. The rest of the cluster allows by default, see
[01_networking.md](01_networking.md).

- The app accepts traffic only from Envoy, and reaches only DNS and the broker.
- Each store's shared chart renders its own policy, and a client-egress policy from its `allowedClients`. So
  `allowedClients` is the single source for the path from app to store, and the app policy names no store.
- Store policies have no off switch. A database must never be reachable from arbitrary sources.
- Clients must be in the store's namespace, because a namespaced policy cannot select pods elsewhere.

### Data outlives a prune

Every store sets `deletionProtection: true`, so removing the app from git leaves the databases and Redis running.
Restoring the files adopts them again. Point-in-time recovery needs the S3 backups from
[10_backups.md](10_backups.md). Until then, durability rests on Postgres replication and 2 Longhorn replicas.

## Caveats

- The `-sso` host is gated in `04_google_sso`, not in this chart. If that chart does not list the subdomain, the
  host is open. If `04_google_sso.sh` has not sealed the client secret, the login fails.
