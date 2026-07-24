# ObjectStore Helm-hook vs ArgoCD — reproduction harness (cloudnative-pg/charts#964)

Throwaway, isolated test of the one question behind why `pg-cluster` renders the CNPG CRs itself instead of
wrapping the upstream `cnpg/cluster` chart: **under ArgoCD, does the upstream ObjectStore Helm-hook survive, or
does it get pruned and take WAL archiving down with it?** Tests three variants against the *live* cluster
without rebuilding anything.

| `hookMode`    | ObjectStore annotation                                     | What it represents                          |
|---------------|------------------------------------------------------------|---------------------------------------------|
| `stock`       | `helm.sh/hook: pre-install,pre-upgrade,pre-rollback`       | EXACT upstream `cnpg/cluster` (the reported break) |
| `no-rollback` | `helm.sh/hook: pre-install,pre-upgrade`                    | maintainer's hypothesis in #964 (pre-rollback is the culprit) |
| `syncwave`    | `argocd.argoproj.io/sync-wave: "-1"` (no hook)             | our current fix                             |

Nothing here is under a roots-recursed path, so no ArgoCD root adopts it — **apply and delete the app by hand.**

## Why this needs no cluster rebuild

The bug lives entirely in how ArgoCD's sync engine classifies a Helm-hook resource. It's independent of Talos /
image / CNI / bootstrap. One disposable Application reproduces it. Do **not** rebuild the cluster.

## Prerequisites

- Platform Healthy; the barman plugin present: `kubectl get crd objectstores.barmancloud.cnpg.io` and the CNPG
  operator up (`kubectl -n cnpg-system get deploy`).
- **The chart must be pushed to git** — ArgoCD reconciles the git *remote*, not your working tree. Commit +
  push `argo_apps/_test/**` first, or the app reports `ComparisonError: path does not exist`. (`app.yaml` itself
  is applied with `kubectl`, not through a root, so it doesn't need to be pushed — only the chart it points at.)

## Tier 1 — mechanism (fast, no S3, `cluster.enabled=false`)

Answers the core question directly: is the hook ObjectStore a *live persistent* resource, or an ephemeral hook
ArgoCD deletes? Run this per variant.

```bash
# 1. pick the variant (clean slate each run so pre-install fires, not pre-upgrade)
kubectl delete -f app.yaml --ignore-not-found            # no-op on first run
#    edit app.yaml -> spec.source.helm.parameters hookMode = stock | no-rollback | syncwave
kubectl apply -f app.yaml

# 2. let it sync, then look at how ArgoCD CLASSIFIED the ObjectStore
argocd app sync oshook-test
argocd app get oshook-test                                # is ObjectStore listed as a normal resource, or "Hook"?
kubectl -n oshook-test get objectstore                    # present at all?

# 3. the smoking-gun checks — record the ObjectStore identity, then force more syncs
kubectl -n oshook-test get objectstore oshook-backups -o jsonpath='{.metadata.uid} {.metadata.creationTimestamp}{"\n"}'
argocd app sync oshook-test                               # 2nd sync = UPGRADE path (pre-upgrade fires)
kubectl -n oshook-test get objectstore oshook-backups -o jsonpath='{.metadata.uid} {.metadata.creationTimestamp}{"\n"}'
#    uid/creationTimestamp CHANGED  -> deleted+recreated each sync (hook behavior; archiving-break window)
#    uid stable                     -> genuinely persistent resource (our fix)

# 4. selfHeal test: delete it out of band, watch whether ArgoCD restores it
kubectl -n oshook-test delete objectstore oshook-backups
sleep 30 && kubectl -n oshook-test get objectstore        # a hook resource is NOT self-healed back -> stays gone
```

Watch a full auto-sync live in another pane to catch the deletion window:
`kubectl -n oshook-test get objectstore -w`

## Tier 2 — full symptom (needs a reachable bucket, `cluster.enabled=true`)

Only if Tier 1 is ambiguous and you want to see the downstream Cluster actually break. Create the creds secret,
point `backups.s3.bucket`/`region` at a real (scratch-prefix) bucket, set `cluster.enabled=true`, then:

```bash
kubectl -n oshook-test create secret generic oshook-s3-creds \
  --from-literal=ACCESS_KEY_ID=... --from-literal=ACCESS_SECRET_KEY=...
# flip cluster.enabled=true in app.yaml, re-apply, sync, then watch the Cluster condition:
kubectl -n oshook-test get cluster oshook -w
kubectl -n oshook-test get cluster oshook -o jsonpath='{.status.conditions[?(@.type=="Ready")]}{"\n"}'
```

Distinguish the two failure modes: `ContinuousArchivingFailing: ObjectStore ... not found` = **the bug** (CR was
pruned); a cred/network error = merely a bad bucket, not this bug.

## Pass / fail

For each variant across steps 2–4: **PASS** = ObjectStore stays present, stable uid, self-healed back, Cluster
stays Ready. **FAIL** = ObjectStore vanishes / uid churns / not restored / Cluster goes Ready=False.

- `stock` FAIL + `syncwave` PASS → reproduces #964; our fix justified; the break was not a fluke.
- `no-rollback` PASS → the maintainer is right that `pre-rollback` alone is the trigger; propose the smaller upstream fix.
- `no-rollback` FAIL → any PreSync mapping breaks it; the full `helmHook` opt-out (PR #965) is warranted.

The mechanism is deterministic given the annotations, so 2 clean reproductions per variant is enough — no need
for statistical runs.

## Cleanup

```bash
kubectl delete -f app.yaml            # finalizer cascade-deletes the ObjectStore/Cluster
kubectl delete ns oshook-test --ignore-not-found
```

Then delete `argo_apps/_test/` from git. Nothing here is referenced by any root, so removing it is safe.
