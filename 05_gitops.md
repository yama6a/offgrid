# GitOps — ArgoCD

The cluster from [step 03](03_operating_system.md) is networked by [step 04](04_networking.md) (**Cilium**). **ArgoCD**
is the next and **last component installed imperatively** — from here on, everything is GitOps. ArgoCD **manages
itself** from a wrapper chart in this repo, **adopts** the already-running Cilium, and becomes the delivery path for
every later app (the deferred NIC-recovery DaemonSet, etcd snapshots, monitoring, Longhorn, workloads). **`05_argocd.sh`**
does the one-time bootstrap.

The **single source of truth** is the wrapper Helm chart at `argo_apps/charts/02_argocd/`. `05_argocd.sh` just installs
that chart by hand, then hands off to git: ArgoCD adopts the same release (same chart, namespace, release name, values →
Argo sees it in-sync rather than fighting it) and self-manages from then on. Nothing — no version, no values — is defined
in the script. The chart:

| Path                 | Holds                                                                                          |
|----------------------|------------------------------------------------------------------------------------------------|
| `Chart.yaml`         | the **argo-cd chart version** (`9.6.0`, ArgoCD `v3.4.4`), declared as a dependency on argo-helm. |
| `values.yaml`        | the **HA-lite values** (under the `argo-cd:` key) — see below.                                  |
| `Chart.lock`         | pins the resolved dependency; **must be committed** (ArgoCD's repo-server needs it — see below). |

## The `argo_apps/` app-of-apps model

```
argo_apps/
  root-app.yaml          # the app-of-apps ROOT (applied once by 05_argocd.sh)
  apps/                  # root watches this dir (directory.recurse) — one Application per app
    01_cilium.yaml       #   adopts Cilium      (manual sync)
    02_argocd.yaml       #   ArgoCD self-manage (automated)
  charts/                # the wrapper charts the Applications point at
    01_cilium/           #   step 04's chart
    02_argocd/           #   this step's chart
```

- **`root-app.yaml`** is an Application that recurses `argo_apps/apps/` and manages every child Application it finds.
- Each child Application points at a wrapper chart under `argo_apps/charts/`.
- **Add a new app** = drop a wrapper chart under `argo_apps/charts/NN_name/` + an Application manifest under
  `argo_apps/apps/NN_name.yaml`, then commit & push. The root picks it up on its next reconcile. (Numbering mirrors the
  `charts/` dir; it's a human label — actual ordering is the sync-wave annotation.)

### sync-wave convention

Ordering across apps is `argocd.argoproj.io/sync-wave` (lower = earlier; the root waits for a wave to be **Healthy**
before the next). **Both bootstrap apps share wave `0`** — and that's deliberate:

- Cilium and ArgoCD are **already running** (step 04 + the by-hand install here); the root only **adopts** them, so
  there's no install-ordering between them.
- The Cilium app is **manual sync**, so it starts **OutOfSync** and stays that way until you adopt it. A manual app at an
  *earlier* wave would **block the root from ever creating the later-wave apps** (including `argocd`) — self-management
  would never engage. Sharing wave `0` lets the root create both Application objects together: `argocd` (automated)
  self-adopts to Healthy immediately; `cilium` waits for its one adoption click.
- **Future** managed apps go at wave **`1`+**, so they reconcile after the platform (CNI + engine) is in place.

## HA-lite — sized for 3× 8 GB Pis

ArgoCD is **not** in the data path of running apps: once an app is synced it runs regardless of Argo, so a few seconds of
no reconciliation is fine. We spend the RAM only where an outage would actually hurt:

| Component                  | Setting                          | Why                                                                       |
|----------------------------|----------------------------------|---------------------------------------------------------------------------|
| application-controller     | 1 replica                        | the reconciler; a singleton that **self-heals** on restart.               |
| redis                      | single (`redis-ha.enabled:false`)| only a cache — rebuilds in seconds on restart. (redis-ha = ~5 extra pods.) |
| repo-server                | **2 replicas + PDB**             | manifest generation; kept up across a node drain.                         |
| server (API/UI)            | **2 replicas + PDB**             | the UI/API; kept up across a node drain.                                  |
| applicationSet-controller  | 2 replicas                       | leader-elected; 2 for fast failover (drop to 1 if RAM gets tight).        |
| dex, notifications         | **disabled**                     | no SSO, no notifications yet — 2 fewer pods.                              |

The 2-replica components carry `global.topologySpreadConstraints` (`maxSkew 1`, `kubernetes.io/hostname`,
`DoNotSchedule`) — over 3 nodes that forces each pair onto **two distinct nodes**. Singletons satisfy it trivially.

## Decision notes

- **Git auth = nothing.** The repo (`yama6a/offgrid`) is **public**, so ArgoCD clones it anonymously over HTTPS —
  no token, no SSH deploy key, no repository `Secret`. (A private repo would need a `Secret` in `argocd` labelled
  `argocd.argoproj.io/secret-type: repository`; we deliberately don't.)
- **Cilium adoption is manual sync**, and stays manual. ArgoCD runs on Cilium's network, so a bad Cilium change synced
  through Argo can cut Argo (and the cluster) off — the **circular dependency** called out in
  [04_networking.md](04_networking.md). Argo tracks Cilium but never auto-reconciles it; `04_cilium.sh` stays
  **break-glass**. You **Sync the `cilium` app once** to adopt the running release — no pod churn, because the chart's
  `values.yaml` already commits `loadBalancer.enabled: true`, so Argo's rendered desired state matches what's live.
- **`Chart.lock` must be committed** for any wrapper chart with dependencies. ArgoCD's repo-server renders charts with
  `helm dependency build`, which **requires** the lock. `01_cilium` already has one; `02_argocd`'s is generated on the
  first run of `05_argocd.sh` (`helm dependency update`) — **commit it** before the `argocd` app reconciles (the script
  reminds you).
- **UI over port-forward** for now. `server.insecure: true` serves plain HTTP, so no TLS to fumble through a port-forward.
  Cilium's LB-IPAM + Gateway API are live (step 04), so a `LoadBalancer` Service or Gateway is an option later — flip
  `server.insecure` to `false` and front it with TLS when that happens.

## What `05_argocd.sh` does

Uses **native `helm` + `kubectl`** (errors out if either is missing) — like `04_cilium.sh`, unlike the dockerized
talos-phase scripts (03a–03e). Talks to the cluster via `03_operating_system/talos-cluster/kubeconfig`. Idempotent.

1. **Prereqs** — `kubectl`/`helm` present, kubeconfig reachable, the chart + root app exist, and **Cilium is up** (the
   GitOps layer needs a working pod network).
2. **Vendors** the argo-cd subchart: `helm dependency build` (falls back to `helm dependency update`, which generates
   `Chart.lock` on first run — commit it).
3. `helm upgrade --install argocd argo_apps/charts/02_argocd -n argocd --create-namespace --reset-values --wait` —
   release `argocd` / namespace `argocd` so the self-managed Application adopts THIS release.
4. Waits for the controller / repo-server / server to roll out.
5. **Hands off**: after a "did you push?" check (ArgoCD reads git, not local disk), `kubectl apply` the root app. The
   root creates both child apps; `argocd` self-adopts, `cilium` appears OutOfSync for its one adoption sync.
6. Waits for `root` + `argocd` to be **Synced/Healthy**, then prints the admin password + port-forward command.

```bash
# 1) generate + commit the argo-cd Chart.lock (first time only), commit the new files, and PUSH:
helm dependency update argo_apps/charts/02_argocd
git add argo_apps 05_gitops 03_operating_system.md && git commit -m "step 05: ArgoCD" && git push

# 2) bootstrap:
./05_gitops/05_argocd.sh

# 3) reach the UI (user: admin; password printed by the script):
kubectl -n argocd port-forward svc/argocd-server 8080:80
#    then open http://localhost:8080 and Sync the 'cilium' app once to adopt it.
```

## Caveats

- **Run order: 04 before 05.** ArgoCD (and CoreDNS, and every workload) needs Cilium's pod network; the script refuses to
  run if `ds/cilium` is absent.
- **Push before you hand off.** ArgoCD clones the **public** repo — anything not committed *and pushed* is invisible to
  the root app, which then shows `ComparisonError: path does not exist`. The script prompts; re-running after pushing is
  safe (`ASSUME_PUSHED=1` skips the prompt).
- **Self-management is real.** Once the `argocd` app is Synced, changes to `argo_apps/charts/02_argocd/values.yaml` are
  applied by ArgoCD to itself on push. A bad value can disrupt ArgoCD briefly; it self-heals, and `05_argocd.sh` remains
  break-glass (re-run to force the release back to the chart).
- **The leftover Helm release secret** (`sh.helm.release.v1.argocd.*` in `argocd`) from the by-hand install is harmless;
  once the app is adopted you may delete it.

## Troubleshooting

- **`argocd` app stuck `ComparisonError` / "app path does not exist"** → the files aren't on the remote. Commit & push
  `argo_apps/**` (incl. `Chart.lock`), then re-sync.
- **`argocd` app `OutOfSync` with a `helm dependency build` error** → `Chart.lock` isn't committed (or is stale). Run
  `helm dependency update argo_apps/charts/02_argocd`, commit the lock, re-sync.
- **`cilium` app `OutOfSync` forever** → expected until you Sync it once (manual). After adoption it stays Synced/Healthy.
- **`server`/`repo-server` pods pending** → the `DoNotSchedule` topology spread needs 2 schedulable nodes free; check
  `kubectl -n argocd get pods -o wide` and node pressure (Longhorn/monitoring not yet installed, so this is rare now).
- **Can't log in** → admin password:
  `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.

## Reading the script output

`[PASS]`/`[FAIL]` per check, then `summary: N passed, M failed` (exit non-zero on any fail). A clean run ends with `root`
and `argocd` Synced/Healthy and `cilium` OutOfSync (adopt it once in the UI).
