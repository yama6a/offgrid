# Sealed Secrets — committing secrets to git, safely

With ArgoCD delivering everything from [step 05](05_gitops.md), the cluster needs a way to keep
**secrets** in git alongside the manifests that consume them. [05_gitops.md](05_gitops.md) already
flagged this: the repo clone credential stays imperative (chicken-and-egg), and **"sealed-secrets is
reserved for app/cluster secrets later (GitOps-managed, wave 1+)."** This is that step.

[Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) (Bitnami) runs a controller holding
an RSA key pair. You encrypt a value against its **public** key (`kubeseal`) into a `SealedSecret`
custom resource — **safe to commit to git** — and only this controller, with the **private** key, can
decrypt it back into a normal `Secret` in-cluster. Asymmetric, so anyone can seal; only the cluster
can unseal.

This is **not** an imperative bootstrap like Cilium or ArgoCD — it's a plain wave-2 ArgoCD app. The
only out-of-band step is **backing up the controller's private key** (below): lose it and every
committed `SealedSecret` is permanently undecryptable.

## The wrapper chart

Single source of truth is the wrapper chart at `argo_apps/platform/charts/02_sealed_secrets/` (same pattern as
`00_cilium` / `01_argocd`):

| Path          | Holds                                                                                    |
|---------------|------------------------------------------------------------------------------------------|
| `Chart.yaml`  | the **sealed-secrets chart version** (`2.19.0`, controller `v0.38.1`), a dependency on the `bitnami.github.io/sealed-secrets` chart repo. |
| `values.yaml` | all config under the `sealed-secrets:` key — `fullnameOverride`, logging, resources.     |
| `Chart.lock`  | pins the resolved dependency; **must be committed** (ArgoCD's repo-server runs `helm dependency build`). |

Generate/refresh the lock with `helm dependency update argo_apps/platform/charts/02_sealed_secrets` and commit
it (the vendored `charts/*.tgz` is gitignored — reproduced from the lock, same as the other charts).

## Where it sits — wave 2, same as nic-keeper

The [`nic-keeper`](06_nic_keeper.md) DaemonSet and this controller are **independent leaves** — neither
depends on the other — so they share **sync-wave `2`**. Per [CLAUDE.md](CLAUDE.md) the `NN` prefix on
an app *is* its wave, so both carry the `02_` prefix (`argo_apps/platform/apps/02_nic_keeper.yaml` and
`argo_apps/platform/apps/02_sealed_secrets.yaml`); the dir/file names stay distinct and `ls argo_apps/platform/apps/`
still reads in deploy order. Wave 2 is the "after the platform (CNI + ArgoCD) is in place" slot.

> Note on numbering: the argo-app `NN` is the **sync-wave**; the top-level `.md` files (this is `07`)
> follow **runbook step order** (…`06_nic_keeper`, `07_sealed_secrets`). The two schemes are
> independent — `nic-keeper` is argo-app `02` but runbook doc `06`.

**syncPolicy: `automated {prune: true, selfHeal: true}` + `ServerSideApply=true`** — a safe leaf,
like `nic-keeper`. It can't cut the cluster off its own network, so drift should just auto-correct.
The controller's runtime-generated **key Secret is not in git**, so `prune` never cascade-deletes it.
Runs in its **own `sealed-secrets` namespace** (`CreateNamespace=true`), mirroring how ArgoCD gets its
own ns.

## Key custody — the one thing you must not lose

The controller generates its RSA key on first start, stores the **private key** in a Secret labelled
`sealedsecrets.bitnami.com/sealed-secrets-key` in the `sealed-secrets` namespace, and **rotates it
roughly monthly, keeping the old keys** (so previously-sealed secrets still decrypt). That key set is
the *only* thing that can decrypt the `SealedSecret`s committed to this repo — a cluster rebuild
without it orphans every sealed value.

**`07_sealed_secrets/07_backup_sealed_secrets_key.sh`** dumps **all** labelled key Secrets to
`03_operating_system/talos-cluster/sealed-secrets-master.key`. That dir is **gitignored** (the
`talos-cluster` rule in `03_operating_system/.gitignore`), so the private key is never committed — the
same custody guarantee as the `kubeconfig` / `talosconfig` that already live there. Native `kubectl`,
PASS/FAIL summary, idempotent — re-run after each rotation (and stash a copy somewhere off-cluster;
surviving a cluster loss is the whole point).

```bash
# back up the master key (after the app is Synced/Healthy, and after each ~monthly rotation):
./07_sealed_secrets/07_backup_sealed_secrets_key.sh

# RESTORE on a rebuilt cluster (before sealing/unsealing anything new):
kubectl apply -f 03_operating_system/talos-cluster/sealed-secrets-master.key
kubectl delete pod -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets   # restart to load it
```

## Using it — sealing a secret

Install the `kubeseal` CLI (`brew install kubeseal`), then seal against **this** controller (the
`fullnameOverride: sealed-secrets` in `values.yaml` keeps the name/namespace stable):

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

By default a `SealedSecret` is `strict`-scoped: it only unseals into the exact name+namespace it was
sealed for. Use `--scope namespace-wide` / `cluster-wide` only when you deliberately need to relax that.

## Caveats

- **Generate + commit `Chart.lock` before the app syncs.** Unlike `01_argocd` (whose lock is generated
  by its bootstrap script), this app has no imperative step — so run `helm dependency update
  argo_apps/platform/charts/02_sealed_secrets` yourself and commit the lock, or the `sealed-secrets` app shows
  `OutOfSync` with a `helm dependency build` error (same failure mode as a missing cilium/argocd lock).
- **Push before you expect a sync.** ArgoCD reads git, not local disk — commit *and push*
  `argo_apps/**` (incl. `Chart.lock`) or the root app reports `ComparisonError`.
- **The backup is only as fresh as your last run.** Keys rotate; re-run the backup script after each
  rotation (or schedule it) so a restore has the *current* active key, not just historical ones.
- **`SealedSecret`s are bound to this cluster's key.** Sealing against one cluster's public key and
  applying to another won't unseal — restore the backed-up key first, or re-seal against the new key.
