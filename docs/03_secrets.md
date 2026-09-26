# Sealed Secrets: committing secrets to git, safely

[Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) runs a controller that holds an RSA key pair.
`kubeseal` encrypts a value with the public key into a `SealedSecret`, which is safe to commit. Only the controller
can decrypt it into a normal `Secret`. Procedures are in [runbooks/03_secrets.md](runbooks/03_secrets.md).

- It is a plain wave-2 Argo CD app. It needs only the CNI and Argo CD.
- Every secret in this repo uses it, except the git clone credential. Argo CD needs that one before this
  controller exists. See [02_gitops.md](02_gitops.md#git-auth).
- A `SealedSecret` is bound to one cluster's key. It does not unseal on another cluster.

## Key custody: the one thing you must not lose

The controller generates its RSA key on first start, rotates it about monthly and keeps the old keys. That key
set is the only thing that can decrypt the `SealedSecret`s in this repo. Rebuild the cluster without it, and every
sealed value is lost.

`03_backup_sealed_secrets_key.sh` writes the keys to `secrets/sealed-secrets-master.key`. `secrets/` is a symlink
to a store outside the repo, so the private key is never committed. Keep a copy off the cluster, and back up again
after each rotation.

### First-time bootstrap vs rebuild

The key decides which one-shot orchestrator to run. Pick by whether the cluster already has the platform on it,
not by whether the nodes were just wiped. Neither orchestrator touches the nodes.

| Orchestrator | Use on | What it does with the key |
|---|---|---|
| `DANGEROUS_rebuild_cluster.sh` | a cluster that had the platform | restores the backed-up key, so the committed `SealedSecret`s decrypt unchanged. Needs a current backup |
| `DANGEROUS_bootstrap_cluster.sh` | a first-time install | the new controller creates a new key. The script re-seals the committed secrets against it, commits, pushes and backs up the new key |

## Picking up a changed secret: Reloader

Kubernetes never restarts a pod when a Secret or ConfigMap changes. A pod keeps the old value until someone
restarts it.

`02_reloader` runs with `--auto-reload-all`. It restarts any Deployment, StatefulSet or DaemonSet whose pod
references a changed Secret or ConfigMap through `env`, `envFrom` or a volume. It hashes the decrypted data, so a
re-seal that keeps the credential restarts nothing.

It matters for pods that read operator-generated credentials, such as `*-db-app` and `*-user-credentials`. If
CNPG or the RabbitMQ topology operator changes a password, the app picks it up. Most sealed secrets in this repo
need no restart, because their readers fetch them through the API per use.

### What is opted out, and why

The opt-out is `reloader.stakater.com/auto: "false"` on the pod template. A workload opts out when it already
reloads without a restart, or when a restart costs more than stale config.

| Workload | Reason |
|---|---|
| `cilium`, `cilium-operator` | they restart themselves on a config change. Without the opt-out, the Hubble cert CronJob would restart the CNI on every node every few months |
| `cilium-envoy` | the L7 proxy on each node. A restart drops proxied connections |
| `envoy-eg-*` | `mergeGateways` puts all cluster ingress in one pod |
| `longhorn-manager` | the volume data path. Nothing it mounts changes today, so the opt-out is a precaution |
| `cnpg-operator` | its one mounted Secret is a webhook cert it rotates itself. A restart at the wrong moment adds about 33s to a switchover |
| `vmagent` | the operator rewrites its scrape config on every target change, and vmagent reloads it without a restart |
| `vmsingle`, `vlsingle` | the metrics and log stores, each on a single RWO volume |
| `rabbitmq-server` | each restart forces a quorum leader election across 3 brokers. The operator already restarts them itself |

Jobs and CronJobs are excluded globally, because each run is a new pod that reads the current credential anyway.
