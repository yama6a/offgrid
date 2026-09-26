# Sealed Secrets: committing secrets to git, safely

[Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) runs a controller that holds an RSA key pair.

- `kubeseal` encrypts a value with the public key into a `SealedSecret` custom resource. That is safe to commit.
- Only the controller holds the private key. It decrypts the `SealedSecret` into a normal `Secret` in the cluster.
- Anyone can seal. Only the cluster can unseal.

How it differs from Cilium and Argo CD:

- It is not an imperative bootstrap step. It is a plain wave-2 Argo CD app.
- It has one out-of-band step: back up the controller's private key. Lose the key, and no committed
  `SealedSecret` can ever be decrypted again.
- The repo clone credential stays imperative, because Argo CD needs it before this controller exists. Every other
  secret uses Sealed Secrets. See [02_gitops.md](02_gitops.md).

## The wrapper chart

`argo_apps/platform/charts/02_sealed_secrets/` follows the same pattern as `00_cilium` and `01_argocd`:

| Path          | Holds                                                                                    |
|---------------|------------------------------------------------------------------------------------------|
| `Chart.yaml`  | a pinned dependency on the `bitnami.github.io/sealed-secrets` chart repo                 |
| `values.yaml` | all config under the `sealed-secrets:` key: `fullnameOverride`, logging, resources       |
| `Chart.lock`  | the resolved dependency. Commit it, because Argo CD's repo-server runs `helm dependency build` |

Refresh the lock with `helm dependency update argo_apps/platform/charts/02_sealed_secrets` and commit it. The
vendored `charts/*.tgz` is gitignored and rebuilt from the lock, as for the other charts.

## Where it sits: wave 2

The controller needs only the CNI and Argo CD. So it sits at wave `2`, the first slot after both, with the other
apps that need nothing more. The file carries the `02_` prefix, so `ls argo_apps/platform/apps/templates/` still
lists apps in deploy order.

It uses the standard leaf settings, `prune` and `selfHeal`, plus `ServerSideApply=true`. Two details:

- The controller generates its key Secret at runtime. The key is not in git, so `prune` never deletes it.
- It runs in its own `sealed-secrets` namespace (`CreateNamespace=true`), as Argo CD does.

## Key custody: the one thing you must not lose

On first start, the controller generates its RSA key.

- It stores the private key in a Secret in the `sealed-secrets` namespace, labelled
  `sealedsecrets.bitnami.com/sealed-secrets-key`.
- It rotates the key about once a month.
- It keeps the old keys, so secrets sealed earlier still decrypt.

That key set is the only thing that can decrypt the `SealedSecret`s in this repo. Rebuild the cluster without it,
and every sealed value is lost.

`lib/shell/03_backup_sealed_secrets_key.sh` writes all labelled key Secrets to `secrets/sealed-secrets-master.key`.

- `secrets/` is a symlink to an off-repo store. The root `.gitignore` lists `/secrets`. So the private key is
  never committed.
- The Argo CD webhook secret uses the same store.
- The script uses native `kubectl`, prints a PASS/FAIL summary and is idempotent.
- Re-run it after each key rotation.

Keep a copy off the cluster too. A backup that exists only on the cluster is useless the day you lose the
cluster.

```bash
# back up the master key. Run after the app is Synced and Healthy, and after each monthly rotation:
lib/shell/03_backup_sealed_secrets_key.sh

# restore on a rebuilt cluster, before you seal or unseal anything new:
kubectl apply -f secrets/sealed-secrets-master.key
kubectl delete pod -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets   # restart so it loads the key
```

### First-time bootstrap vs rebuild

The key is what separates the two one-shot orchestrators. Neither touches the nodes. A full node wipe is a job for
the tooling that built the cluster. Run it before either orchestrator if you want one.

| Orchestrator | Use on | What it does with the key |
|---|---|---|
| `DANGEROUS_rebuild_cluster.sh` | a cluster that already has the platform | redelivers the platform, then restores the backed-up master key. The committed `SealedSecret`s decrypt unchanged. It does not re-seal. Needs a current backup, so run `03_backup_sealed_secrets_key.sh` first |
| `DANGEROUS_bootstrap_cluster.sh` | a cluster with no platform, first-time install | there is no earlier key. The fresh controller creates a new one, and the committed `google-oauth` `SealedSecret` no longer decrypts. So it re-seals against the new key, keeps the committed allowlists, commits and pushes. It then backs up the new key so later rebuilds can restore it |

Pick by whether the cluster already has a platform on it, not by whether the nodes were just wiped.

Example: your node tooling wipes and re-creates every node, for instance with `make reset-cluster`. The cluster
is then bare, so the next step is `make bootstrap-cluster` here.

## Sealing a secret

Install the CLI with `brew install kubeseal`. `fullnameOverride: sealed-secrets` in `values.yaml` keeps the
controller name and namespace stable. The flags below match on them.

```bash
# seal a whole Secret manifest into a SealedSecret that is safe to commit:
kubectl create secret generic my-secret -n my-app \
    --dry-run=client --from-literal=token=s3cr3t -o yaml \
  | kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets --format yaml \
  > my-sealedsecret.yaml      # commit this. The controller unseals it into Secret/my-secret in ns my-app

# or seal one raw value:
echo -n s3cr3t | kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets \
    --raw --scope strict --name my-secret --namespace my-app
```

A `SealedSecret` has `strict` scope by default. It unseals only into the exact name and namespace it was sealed
for. Use `--scope namespace-wide` or `cluster-wide` only when you need that on purpose.

## Picking up a changed secret: Reloader

Kubernetes never restarts a pod when a Secret or ConfigMap changes.

- A pod reads env vars once, at startup.
- A mounted file changes on disk, but almost no process reads it again.
- So the pod keeps the old value until someone restarts it by hand.

`02_reloader` fixes that. It runs with `--auto-reload-all`, so it watches every Deployment, StatefulSet and
DaemonSet by default. It restarts one when a Secret or ConfigMap that the pod references changes.

- "References" means `envFrom`, `env[].valueFrom`, or a volume.
- Reloader cannot see a Secret that a component reads through the API.

That covers most of this repo's sealed secrets. Re-sealing them restarts nothing, and nothing needs a restart:

| Secret | Read by | Why no restart |
|---|---|---|
| `cloudflare-api-token` | cert-manager, via `apiTokenSecretRef` | fetched per DNS-01 challenge |
| `google-oauth` | Envoy Gateway, via `SecurityPolicy` | fetched by the controller |
| `longhorn-backup-s3` | Longhorn, via a setting | fetched per backup |
| `argocd-secret` | Argo CD | no Argo CD pod mounts it |
| the wildcard TLS certs | Envoy | delivered over xDS, never as a file |

Reloader matters for the workload pods that read credentials an operator generates: `*-db-app` and
`*-user-credentials`. If CNPG or the RabbitMQ topology operator regenerates a password, the app picks it up. It
does not keep a stale one forever.

Reloader hashes the decrypted data. So re-running a `make configure-*` target produces new ciphertext but
restarts nothing, unless the credential itself changed.

### What is opted out, and why

The opt-out is `reloader.stakater.com/auto: "false"` on the pod template. There are only two reasons to opt out:

- The component already reloads without a restart.
- A restart costs more than the stale config does.

| Workload | Reason |
|---|---|
| `cilium`, `cilium-operator` | they already restart themselves on a config change (`rollOutCiliumPods`, `rollOutPods`). Without the opt-out, the Hubble cert CronJob would restart the CNI on every node every few months |
| `cilium-envoy` | the L7 proxy on each node. A restart drops proxied connections |
| `envoy-eg-*` | `mergeGateways` puts all cluster ingress in one pod |
| `longhorn-manager` | the volume data path. Nothing it mounts changes today, so the opt-out is a precaution |
| `cnpg-operator` | its one mounted Secret is a webhook cert it rotates itself. A restart at the wrong moment adds about 33s to a switchover |
| `vmagent` | the operator rewrites its scrape config on every target change in the cluster. vmagent reloads that without a restart |
| `vmsingle`, `vlsingle` | the metrics and log stores, each on a single RWO volume |
| `rabbitmq-server` | each broker restart forces a quorum leader election, across 3 brokers. The operator already restarts them itself |

Jobs and CronJobs are excluded globally. Reloader would start a new run, not restart anything. Each run is a new
pod that reads the current credential anyway.

CNPG's Postgres pods are bare Pods, not a StatefulSet. Reloader cannot act on them, so there is nothing to opt
out.

## Caveats

- **No bootstrap script generates this chart's lock.** `01_argocd` has one, this chart does not. Run
  `helm dependency update argo_apps/platform/charts/02_sealed_secrets` and commit `Chart.lock` before the app
  syncs. Otherwise it shows `OutOfSync` with a `helm dependency build` error.
- **The backup is only as fresh as your last run.** Keys rotate. Re-run the backup after each rotation, or
  schedule it. A restore then has the current active key, not only old ones.
- **A `SealedSecret` is bound to this cluster's key.** A secret sealed against one cluster does not unseal on
  another. Restore the backed-up key first, or re-seal against the new key.
