# cert-manager — X.509 certificates for the cluster

The cluster will serve HTTPS through the Cilium Gateway API (CRDs + LoadBalancer already installed by
[`00_cilium`](04_networking.md)). [cert-manager](https://cert-manager.io) is the controller that
**issues and renews** the X.509 certs behind those listeners — ultimately Let's Encrypt certificates,
fetched and rotated automatically.

This step installs the **controller only**. No `Issuer`/`ClusterIssuer` ships here — issuance has
prerequisites that aren't settled yet (see [Why no issuer yet](#why-no-issuer-yet)). cert-manager is
independently useful and unblocks that later step, so it lands on its own.

Like [`nic-keeper`](06_nic_keeper.md) and [`sealed-secrets`](07_sealed_secrets.md), this is **not** an
imperative bootstrap (unlike Cilium or ArgoCD, which have a chicken-and-egg with the cluster/network).
It's a plain wave-2 ArgoCD app — there is no out-of-band step at all.

## The wrapper chart

Single source of truth is the wrapper chart at `argo_apps/charts/02_cert_manager/` (same pattern as
`00_cilium` / `01_argocd` / `02_sealed_secrets`):

| Path          | Holds                                                                                                                      |
|---------------|----------------------------------------------------------------------------------------------------------------------------|
| `Chart.yaml`  | the **cert-manager chart version** (`v1.20.2`, controller `v1.20.2`), a dependency on the `charts.jetstack.io` chart repo. |
| `values.yaml` | all config under the `cert-manager:` key — CRD handling, resources, the (commented) future Gateway feature gate.           |
| `Chart.lock`  | pins the resolved dependency; **must be committed** (ArgoCD's repo-server runs `helm dependency build`).                   |

Generate/refresh the lock with `helm dependency update argo_apps/charts/02_cert_manager` and commit it
(the vendored `charts/*.tgz` is gitignored — reproduced from the lock, same as the other charts).

### CRDs — installed by the chart, kept on prune

`values.yaml` sets `crds.enabled: true` (the chart owns and installs the cert-manager CRDs) **and**
`crds.keep: true`. The `keep` matters because the Application runs `prune: true`: without it, a prune
that removed a CRD would **cascade-delete every `Certificate`, `Issuer` and `Order`** that depends on
it. `keep` leaves the CRDs in place, so prune stays safe — the same "never cascade-delete CRDs"
posture Cilium takes (there via `prune: false`; here, more narrowly, via `crds.keep`).

## Where it sits — wave 2, with nic-keeper and sealed-secrets

cert-manager, [`nic-keeper`](06_nic_keeper.md) and [`sealed-secrets`](07_sealed_secrets.md) are
**independent leaves** — none depends on the others — so they share **sync-wave `2`**. Per
[CLAUDE.md](CLAUDE.md) the `NN` prefix on an app *is* its wave, so all three carry the `02_` prefix
(`argo_apps/apps/02_cert_manager.yaml`, `…/02_nic_keeper.yaml`, `…/02_sealed_secrets.yaml`); the
dir/file names stay distinct and `ls argo_apps/apps/` still reads in deploy order. Wave 2 is the
"after the platform (CNI + ArgoCD) is in place" slot.

> Note on numbering: the argo-app `NN` is the **sync-wave**; the top-level `.md` files (this is `08`)
> follow **runbook step order** (…`06_nic_keeper`, `07_sealed_secrets`, `08_cert_manager`). The two
> schemes are independent — cert-manager is argo-app `02` but runbook doc `08`.

**syncPolicy: `automated {prune: true, selfHeal: true}` + `CreateNamespace=true` + `ServerSideApply=true`**
— a safe leaf, like `nic-keeper` / `sealed-secrets`. It can't cut the cluster off its own network, so
drift should just auto-correct. `ServerSideApply` is needed because the cert-manager CRDs are large
enough to blow the client-side last-applied-annotation limit (the same reason `01_argocd` uses SSA).
Runs in its **own `cert-manager` namespace** (`CreateNamespace=true`), mirroring how ArgoCD and
sealed-secrets get their own ns.

## Why no issuer yet

A *working* Let's Encrypt `ClusterIssuer` needs several things this repo hasn't decided/built:

- **An ACME account email** to register with Let's Encrypt.
- **A challenge solver, each with an unmet dependency:**
    - **HTTP-01 via Gateway API** — needs the `ExperimentalGatewayAPISupport` controller feature gate
      (the commented `featureGates` knob in `values.yaml`) **and** a real `Gateway` + `HTTPRoute` to
      attach to, plus LE reaching `http://<domain>/.well-known/...` from the public internet (a domain,
      a public DNS A-record → the Cilium LB IP, inbound :80).
    - **DNS-01** — needs a DNS-provider API token. That secrets-strategy prerequisite is now **solved**:
      [`sealed-secrets`](07_sealed_secrets.md) lets the token be committed to git as a `SealedSecret`.
- **Staging before production** — Let's Encrypt production has hard rate limits, so the normal path is
  a `letsencrypt-staging` issuer first, then flip to production once the solver provably works.

So the blocker is never cert-manager itself — it's the domain, public reachability (or DNS creds), an
actual Gateway, and staging-vs-prod. Those land together in the follow-up step that adds the
`ClusterIssuer`, enables the feature gate, and points a `Gateway` listener at the issued cert.

## Verifying it

```bash
# the lock resolves exactly as ArgoCD's repo-server will (proves sync won't break):
helm dependency build argo_apps/charts/02_cert_manager
helm template argo_apps/charts/02_cert_manager | head   # renders controller + webhook + cainjector + CRDs

# after commit/push — the root app picks up 02_cert_manager.yaml and syncs at wave 2:
kubectl -n cert-manager get pods                 # controller / webhook / cainjector Running
kubectl get crd | grep cert-manager.io           # the cert-manager CRDs are present
```

Optional smoke test (no external deps) — prove issuance end-to-end before any Let's Encrypt wiring:

```bash
kubectl create ns certtest
kubectl apply -n certtest -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: { name: selfsigned }
spec: { selfSigned: {} }
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: smoke }
spec:
  secretName: smoke-tls
  issuerRef: { name: selfsigned, kind: Issuer }
  commonName: smoke.local
  dnsNames: [smoke.local]
EOF
kubectl -n certtest get certificate smoke -w      # READY=True → cert-manager minted Secret/smoke-tls
kubectl delete ns certtest                         # clean up
```

## Caveats

- **Generate + commit `Chart.lock` before the app syncs.** Like `sealed-secrets`, this app has no
  imperative bootstrap step — so run `helm dependency update argo_apps/charts/02_cert_manager`
  yourself and commit the lock, or the `cert-manager` app shows `OutOfSync` with a `helm dependency
  build` error (same failure mode as a missing cilium/argocd/sealed-secrets lock).
- **Push before you expect a sync.** ArgoCD reads git, not local disk — commit *and push*
  `argo_apps/**` (incl. `Chart.lock`) or the root app reports `ComparisonError`.
- **CRDs persist by design.** `crds.keep: true` means uninstalling/pruning the app leaves the
  cert-manager CRDs (and any CRs) behind; remove them deliberately if you ever truly want them gone.
