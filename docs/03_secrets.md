# Sealed Secrets: committing secrets to git, safely

[Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) runs a controller holding an RSA key pair.
`kubeseal` encrypts a value against the public key into a `SealedSecret` custom resource, which is safe to
commit. Only this controller, holding the private key, can decrypt it back into a normal `Secret` in-cluster.
Asymmetric, so anyone can seal and only the cluster can unseal.

- Not an imperative bootstrap like Cilium or ArgoCD. It is a plain wave-2 ArgoCD app.
- One out-of-band step: backing up the controller's private key. Lose it and every committed `SealedSecret` is
  permanently undecryptable.
- [02_gitops.md](02_gitops.md) flagged the split: the repo clone credential stays imperative
  (chicken-and-egg), everything else waits for this.

## The wrapper chart

`argo_apps/platform/charts/02_sealed_secrets/`, same pattern as `00_cilium` and `01_argocd`:

| Path          | Holds                                                                                    |
|---------------|------------------------------------------------------------------------------------------|
| `Chart.yaml`  | a dependency on the `bitnami.github.io/sealed-secrets` chart repo, pinned                |
| `values.yaml` | all config under the `sealed-secrets:` key: `fullnameOverride`, logging, resources        |
| `Chart.lock`  | the resolved dependency; must be committed, ArgoCD's repo-server runs `helm dependency build` |

Refresh the lock with `helm dependency update argo_apps/platform/charts/02_sealed_secrets` and commit it. The
vendored `charts/*.tgz` is gitignored and reproduced from the lock, same as the other charts.

## Where it sits: wave 2

A host-network node agent and this controller are independent leaves, neither
depending on the other, so they share wave `2`: the "after the CNI and ArgoCD are in place" slot. Both carry the
`02_` prefix, and `ls argo_apps/platform/apps/templates/` still reads in deploy order.

Standard automated-leaf settings (`prune` + `selfHeal`) plus `ServerSideApply=true`. Two specifics:

- The controller's runtime-generated key Secret is not in git, so `prune` never cascade-deletes it.
- It runs in its own `sealed-secrets` namespace (`CreateNamespace=true`), mirroring how ArgoCD gets its own.

## Key custody: the one thing you must not lose

The controller generates its RSA key on first start, stores the private key in a Secret labelled
`sealedsecrets.bitnami.com/sealed-secrets-key` in the `sealed-secrets` namespace, and rotates it roughly monthly
while keeping the old keys so previously-sealed secrets still decrypt.

That key set is the only thing that can decrypt the `SealedSecret`s in this repo. A cluster rebuild without it
orphans every sealed value.

`lib/shell/03_backup_sealed_secrets_key.sh` dumps all labelled key Secrets to
`secrets/sealed-secrets-master.key`. That dir is gitignored (`/secrets` in the root `.gitignore`; `secrets/` is a
symlink to an off-repo store), so the private key is never committed. Same custody as the `kubeconfig` and
`talosconfig` already there. Native `kubectl`, PASS/FAIL summary, idempotent, re-run after each rotation.

Keep a copy off-cluster too. A backup that only exists on this cluster is useless the day you lose the cluster.

```bash
# back up the master key (after the app is Synced/Healthy, and after each ~monthly rotation):
lib/shell/03_backup_sealed_secrets_key.sh

# RESTORE on a rebuilt cluster (before sealing/unsealing anything new):
kubectl apply -f secrets/sealed-secrets-master.key
kubectl delete pod -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets   # restart to load it
```

### First-time bootstrap vs rebuild

The key is exactly what separates the two one-shot orchestrators. Neither touches the nodes: wiping Talos is
a full node wipe by whatever tooling built the cluster, run before either of these if you want one.

- `DANGEROUS_rebuild_cluster.sh` redelivers the platform onto a cluster that already has one, then RESTORES the
  backed-up master key so the committed `SealedSecret`s decrypt unchanged. It does not re-seal. Needs a current
  backup, so run `03_backup_sealed_secrets_key.sh` beforehand.
- `DANGEROUS_bootstrap_cluster.sh` is a FIRST-TIME platform install onto a cluster that has none. There is no
  prior key, so the fresh controller mints a brand-new one and the committed `google-oauth` `SealedSecret` is
  orphaned. It therefore re-seals against the new key (keeping the committed allowlists), commits, pushes, then
  backs the new key up so future rebuilds can restore it.

Which one you want depends on whether the cluster already has a platform on it, not on whether the nodes were
just wiped. After an OS-repo `make reset-cluster && make bootstrap-cluster` the cluster is bare, so that is a
bootstrap.

## Sealing a secret

Install the CLI with `brew install kubeseal`. The `fullnameOverride: sealed-secrets` in `values.yaml` keeps the
name and namespace stable, which is what the flags below match on.

```bash
# seal a whole Secret manifest into a commit-safe SealedSecret:
kubectl create secret generic my-secret -n my-app \
    --dry-run=client --from-literal=token=s3cr3t -o yaml \
  | kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets --format yaml \
  > my-sealedsecret.yaml      # commit THIS; the controller unseals it into Secret/my-secret in ns my-app

# or just one raw value:
echo -n s3cr3t | kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets \
    --raw --scope strict --name my-secret --namespace my-app
```

A `SealedSecret` is `strict`-scoped by default: it unseals only into the exact name and namespace it was sealed
for. Use `--scope namespace-wide` or `cluster-wide` only when you deliberately need that.

## Picking up a changed secret: Reloader

Kubernetes never restarts a pod when a Secret or ConfigMap changes. Env vars are read once at startup, and a
mounted file is refreshed on disk but almost nothing re-reads it. So the pod keeps the old value until someone
rolls it by hand.

`02_reloader` closes that. It runs with `--auto-reload-all`, so **every** Deployment, StatefulSet and DaemonSet
is watched by default, and it restarts one when a Secret or ConfigMap that pod actually references changes.
"References" means `envFrom`, `env[].valueFrom`, or a volume. A Secret the component looks up through the API
instead is invisible to Reloader.

That last point covers most of this repo's sealed secrets, so re-sealing them restarts nothing, and does not
need to:

| Secret | Read by | Why no restart |
|---|---|---|
| `cloudflare-api-token` | cert-manager, via `apiTokenSecretRef` | fetched per DNS-01 challenge |
| `google-oauth` | Envoy Gateway, via `SecurityPolicy` | fetched by the controller |
| `longhorn-backup-s3` | Longhorn, via a setting | fetched per backup |
| `argocd-secret` | Argo CD | no Argo CD pod mounts it |
| the wildcard TLS certs | Envoy | delivered over xDS, never a file |

Where it does earn its keep: the workload pods reading operator-generated credentials (`*-db-app`,
`*-user-credentials`). If CNPG or the RabbitMQ topology operator regenerates a password, the app picks it up on
its own instead of holding a stale one forever.

Reloader also hashes the **decrypted** data, so re-running a `make configure-*` target produces fresh ciphertext
but no restart unless the underlying credential actually changed.

### What is opted out, and why

`reloader.stakater.com/auto: "false"` on the pod template. Two reasons ever: the component already reloads
without a restart, or restarting it costs more than the stale config does.

| Workload | Reason |
|---|---|
| `cilium`, `cilium-operator` | already roll themselves on a config edit (`rollOutCiliumPods`, `rollOutPods`); the hubble cert CronJob would otherwise restart the CNI on every node every few months |
| `cilium-envoy` | per-node L7 proxy, a restart drops proxied connections |
| `envoy-eg-*` | `mergeGateways` puts all cluster ingress in one pod |
| `longhorn-manager` | volume data path; nothing it mounts changes today, so pre-emptive |
| `cnpg-operator` | its one mounted Secret is a webhook cert it rotates itself, and a restart at the wrong moment adds ~33s to a switchover |
| `vmagent` | the operator rewrites its scrape config on every target change anywhere, and vmagent reloads that without restarting |
| `vmsingle`, `vlsingle` | the metrics and log stores, single RWO volume each |
| `rabbitmq-server` | rolling 3 brokers is a quorum leader election each; the operator already rolls them itself |

Jobs and CronJobs are excluded globally. Reloader would start a *run* rather than restart anything, and each run
is a fresh pod that reads the current credential anyway.

CNPG's Postgres pods are bare Pods, not a StatefulSet, so Reloader cannot act on them at all. Nothing to opt out.

## Caveats

- No bootstrap script generates the lock here, unlike `01_argocd`. Run `helm dependency update
  argo_apps/platform/charts/02_sealed_secrets` and commit `Chart.lock` yourself before the app syncs, or it shows
  `OutOfSync` with a `helm dependency build` error.
- The backup is only as fresh as your last run. Keys rotate, so re-run the backup after each rotation, or
  schedule it, and a restore then has the current active key rather than only historical ones.
- A `SealedSecret` is bound to this cluster's key. Sealing against one cluster and applying to another will not
  unseal: restore the backed-up key first, or re-seal against the new one.
