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

The [`nic-keeper`](https://github.com/yama6a/talos-raspberry-pi5-cluster/blob/main/docs/03_operating_system.md) DaemonSet and this controller are independent leaves, neither
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

`lib/shell/06_backup_sealed_secrets_key.sh` dumps all labelled key Secrets to
`secrets/sealed-secrets-master.key`. That dir is gitignored (`/secrets` in the root `.gitignore`; `secrets/` is a
symlink to an off-repo store), so the private key is never committed. Same custody as the `kubeconfig` and
`talosconfig` already there. Native `kubectl`, PASS/FAIL summary, idempotent, re-run after each rotation.

Keep a copy off-cluster too. A backup that only exists on this cluster is useless the day you lose the cluster.

```bash
# back up the master key (after the app is Synced/Healthy, and after each ~monthly rotation):
lib/shell/06_backup_sealed_secrets_key.sh

# RESTORE on a rebuilt cluster (before sealing/unsealing anything new):
kubectl apply -f secrets/sealed-secrets-master.key
kubectl delete pod -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets   # restart to load it
```

### First-time bootstrap vs rebuild

The key is exactly what separates the two one-shot orchestrators:

- `DANGEROUS_rebuild_cluster.sh` wipes a RUNNING cluster and rebuilds it, then RESTORES the backed-up master key
  so the committed `SealedSecret`s decrypt unchanged. It does not re-seal. Needs a current backup, so run
  `06_backup` beforehand.
- `DANGEROUS_bootstrap_cluster.sh` is a FIRST-TIME init on freshly-flashed nodes in maintenance mode. There is
  no prior key, so the fresh controller mints a brand-new one and the committed `google-oauth` `SealedSecret` is
  orphaned. It therefore re-seals against the new key (keeping the committed allowlists), commits, pushes, then
  backs the new key up so future rebuilds can restore it. It also archives the old
  `secrets.yaml`/`kubeconfig`/`talosconfig`/`sealed-secrets-master.key` to `secrets/backup_<timestamp>/` and
  starts from a fresh Talos CA.

To re-initialize a running cluster use the rebuild script, which wipes first.

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

## Caveats

- No bootstrap script generates the lock here, unlike `01_argocd`. Run `helm dependency update
  argo_apps/platform/charts/02_sealed_secrets` and commit `Chart.lock` yourself before the app syncs, or it shows
  `OutOfSync` with a `helm dependency build` error.
- The backup is only as fresh as your last run. Keys rotate, so re-run the backup after each rotation, or
  schedule it, and a restore then has the current active key rather than only historical ones.
- A `SealedSecret` is bound to this cluster's key. Sealing against one cluster and applying to another will not
  unseal: restore the backed-up key first, or re-seal against the new one.
