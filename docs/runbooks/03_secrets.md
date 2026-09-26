# Sealed Secrets runbook

Decisions are in [03_secrets.md](../03_secrets.md).

## Back up the master key

Run this once the `sealed-secrets` app is Synced and Healthy, and again after each monthly key rotation.

```bash
make backup-secrets-key
```

Expected: `[PASS]` for each key, and `secrets/sealed-secrets-master.key` exists. Copy that file to a store off the
cluster.

## Restore the master key

Run this on a rebuilt cluster, before you seal or unseal anything new.

```bash
make restore-secrets-key
```

By hand, if the script is not an option:

```bash
kubectl apply -f secrets/sealed-secrets-master.key
kubectl delete pod -n sealed-secrets -l app.kubernetes.io/name=sealed-secrets   # the restart loads the key
```

## Seal a secret

Install the CLI with `brew install kubeseal`.

```bash
# a whole Secret manifest. Commit the output. The controller unseals it into Secret/my-secret in ns my-app.
kubectl create secret generic my-secret -n my-app \
    --dry-run=client --from-literal=token=s3cr3t -o yaml \
  | kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets --format yaml \
  > my-sealedsecret.yaml

# one raw value:
echo -n s3cr3t | kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets \
    --raw --scope strict --name my-secret --namespace my-app
```

The default scope is `strict`: the value unseals only into the exact name and namespace it was sealed for. Use
`--scope namespace-wide` or `cluster-wide` only on purpose.

## Troubleshooting

- **The `sealed-secrets` app is `OutOfSync` with a `helm dependency build` error.** Its `Chart.lock` is missing or
  stale. Run `make fix-chart-locks`, commit and push.
- **A `SealedSecret` does not unseal after a rebuild.** The controller has a new key. Restore the backed-up key, or
  seal the value again against the new key.
