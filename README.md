# offgrid

**A complete self-hosted Kubernetes platform: networked by [Cilium](https://cilium.io/), delivered by
[Argo CD](https://argo-cd.readthedocs.io/), on a cluster you already have.**

![Kubernetes](https://img.shields.io/badge/Kubernetes-326ce5?logo=kubernetes&logoColor=white)
![CNI: Cilium](https://img.shields.io/badge/CNI-Cilium-f8c517?logo=cilium&logoColor=white)
![GitOps: Argo CD](https://img.shields.io/badge/GitOps-Argo%20CD-ef7b4d?logo=argo&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Last commit](https://img.shields.io/github/last-commit/yama6a/offgrid)

> The platform: everything that runs *on* a Kubernetes cluster, delivered by Argo CD from this repo. Ingress,
> TLS, SSO, storage, databases, messaging, monitoring, backups, and a sample workload on top.
>
> It starts from a cluster that already exists and does not build, upgrade or recover one. Bring your own,
> from any tooling, so long as it meets **[What this expects of your cluster](#what-this-expects-of-your-cluster)**.
> The defaults were developed against a small bare-metal [Talos Linux](https://www.talos.dev/) cluster, and
> every host-level assumption that implies is a knob in `.env`.
>
> Every per-deployment value lives in `.env`, and `make configure-values` stamps it into the chart values Argo CD
> renders, so a fork changes one gitignored file and nothing else.
> See **[Make it your own](#make-it-your-own)** to get started.

## Contents

- [Overview](#overview)
- [The stack](#the-stack)
- [What this expects of your cluster](#what-this-expects-of-your-cluster)
- [What this does not do](#what-this-does-not-do)
- [Architecture](#architecture)
- [Repository layout](#repository-layout)
- [Getting started](#getting-started)
- [Make it your own](#make-it-your-own)
- [Day-2 operations](#day-2-operations)
- [Troubleshooting](#troubleshooting)
- [Documentation](#documentation)
- [Contributing](CONTRIBUTING.md)
- [License](#license) and [Credits](#credits)

## Overview

- Starts from a Kubernetes cluster that already exists. Building it is somebody else's job, see
  [What this expects of your cluster](#what-this-expects-of-your-cluster).
- `01_cilium.sh` and `02a_argocd.sh` are the only imperative steps: install the CNI, then install Argo CD.
- Everything after that is GitOps. Argo CD reconciles `argo_apps/` and delivers the platform (ingress, TLS, SSO,
  storage, databases, messaging, monitoring) plus the workloads on top.
- Config is one gitignored file, `.env`, copied from the committed `.env.example`. `make configure-values`
  stamps it into every chart value Argo CD renders. Nothing is hardcoded in a script.
- Every app is a thin Helm wrapper chart pinning its upstream version. `docs/01` to `docs/12` hold the why.

## The stack

Everything after `01`/`02a` is an Argo CD-delivered wrapper chart, each pinning its upstream version in its own
`Chart.yaml`. That file is the source of truth; no version is restated anywhere else.

| Layer             | Component                      | Role                                                                                                         |
|-------------------|--------------------------------|--------------------------------------------------------------------------------------------------------------|
| **Network**       | Cilium                         | CNI + kube-proxy replacement, LB-IPAM + L2 announcements (LoadBalancer IPs), node-to-node WireGuard, Hubble. |
| **GitOps**        | Argo CD                        | Delivery engine; self-manages after bootstrap. Two-tree app-of-apps (platform and workloads).                |
| **Ingress**       | Envoy Gateway                  | Gateway API data plane; one Envoy on a single pinned LoadBalancer IP.                                        |
| **TLS**           | cert-manager                   | Let's Encrypt certificates via ClusterIssuers (HTTP-01, plus Cloudflare DNS-01 for wildcards).               |
| **Auth**          | Google SSO                     | Central OIDC (one Envoy `SecurityPolicy`, one email allowlist, per-host gating).                                 |
| **Secrets**       | Sealed Secrets                 | Encrypted secrets committed to git.                                                                          |
| **Config reload** | Reloader                       | Restarts a workload when a ConfigMap or Secret it mounts changes, which Kubernetes never does on its own.    |
| **Storage**       | Longhorn                       | Replicated block storage, for everything stateful, so a volume outlives the machine under it.                |
| **Node health**   | dead-node-watcher              | Custom Deployment that taints a genuinely dead node, cutting volume handover from ~6 min to ~2.               |
| **Database**      | CloudNativePG                  | Kubernetes-native PostgreSQL operator.                                                                       |
| **Cache**         | OpsTree Redis operator         | Standalone Redis instances, one per workload alias.                                                          |
| **Messaging**     | RabbitMQ                       | One shared broker; workloads declare their own topology.                                                     |
| **Metrics API**   | metrics-server                 | `metrics.k8s.io` for `kubectl top` and HPAs.                                                                 |
| **Observability** | VictoriaMetrics + VictoriaLogs | PromQL-compatible metrics and logs backend (over Prometheus/Mimir + Loki, for 8 GB nodes).                   |
| **Observability** | Grafana                        | Dashboards + alerting, provisioned as code. No persistence layer.                                            |
| **Alerting**      | ntfy                           | Self-hosted mobile push. No email.                                                                           |
| **Observability** | blackbox-exporter              | Probes every ingress host over its public name, so a broken edge is caught without traffic.                  |
| **Workloads**     | sample-user-manager + 2 more   | Demo app + Postgres + Redis + messaging + open/SSO ingress: the template for real workloads.                 |

Five shared charts under `lib/helm/` are consumed as `file://` dependencies, all `type: application`:

- `ingress`: the ingress edge (Gateway, HTTPRoute, ReferenceGrant, Certificate) from an `ingresses[]` list
- `pg-cluster`: a curated CloudNativePG Postgres wrapper
- `redis-instance`: a curated standalone OpsTree Redis wrapper
- `rabbitmq-topology`: a workload's messaging topology against the shared broker
- `nfs-volume`: static PVs + PVCs for NFS exports that already exist off-cluster, from a `volumes[]` list

## What this expects of your cluster

Bring your own Kubernetes. This repo installs the CNI and everything above it, so the cluster underneath has to
satisfy a short list. Each row says what to change when yours differs; the knobs live in `.env` and
`make configure-values` stamps them into the chart values Argo CD renders.

| Requirement | Why | If your cluster differs |
|---|---|---|
| The API reachable at `KUBE_API_HOST:KUBE_API_PORT` from every node | Cilium runs `kubeProxyReplacement`, so it needs the API *before* pod networking exists | set both in `.env`. The default `localhost:7445` is Talos KubePrism; elsewhere use your API endpoint, or a node-local proxy |
| No CNI installed, kube-proxy disabled | Cilium provides both. Nodes stay `NotReady` until `01_cilium.sh` runs, which is expected | if your distribution ships a CNI, remove it first, or skip `01_cilium.sh` and adapt the Cilium values to coexist |
| `iscsid`, `fstrim` and an NFSv4 client on every node | Longhorn attaches volumes over iSCSI and trims them, an RWX volume is mounted over NFS, and `lib/helm/nfs-volume` mounts off-cluster exports the same way | install `open-iscsi`, `util-linux` and `nfs-common` (`nfs-utils` / `nfs-client` elsewhere); on an immutable OS add the equivalent extensions. Talos has the NFS client in-kernel. `kubectl get nodes.longhorn.io -n longhorn-system` reports all three as conditions |
| A filesystem at `LONGHORN_DATA_PATH`, bind-mounted into the kubelet with `rshared` | Longhorn creates one sub-mount per replica and the kubelet has to see them | any path works. Longhorn's own default is `/var/lib/longhorn`. With a containerized kubelet the mount propagation must be bidirectional |
| A 4K-page kernel | Longhorn and XFS do not cope with 16K pages | almost every distribution already is. Only a concern on SBC kernels built with 16K |
| Namespaces can carry `pod-security.kubernetes.io/enforce: privileged` | Longhorn, Cilium and the node agents need privileged pods | the app manifests set it themselves, so nothing to do unless a policy engine overrides them |
| Kubelets with self-signed certs and no CSR approver | metrics-server cannot verify kubelet identity, so it is told not to try | set `KUBELET_TLS_INSECURE=false` if your kubelets carry certs signed by a CA the apiserver trusts |
| Control-plane metrics reachable per node, etcd on `ETCD_METRICS_PORT` | the monitoring stack scrapes controller-manager, scheduler and etcd directly | exposing them is a host-level change. If yours cannot, set `enabled: false` on the three in `05_victoria_metrics_k8s_stack` |
| 3 or more nodes | Longhorn runs 2 replicas with hard anti-affinity, so it needs a spare to rebuild onto | 2 nodes works but leaves no spare. 1 node needs the replica count and the anti-affinity relaxed |
| An S3 bucket, optional | off-cluster backups | leave the `AWS_DEPLOY_*` keys empty and every backup step is skipped |

Two more things are assumed rather than configured, because they are one-line edits when wrong:

- **Node system logs as files under `/var/log`.** The log collector tails them. On a journald distribution
  there are no such files, so drop that `fileCollector` entry in `05_victoria_logs/values.yaml` and collect
  from journald instead.
- **Node filesystems are `ext4` or `xfs`.** The disk-usage alerts filter on that to skip an immutable OS's
  many tmpfs mounts. Edit the regex in `05_grafana/files/alerts/cluster-health.yaml` if yours differ.

Architecture is not assumed. `make check-multiarch` verifies every running image has a manifest for every
architecture in the cluster, and takes `ARCH=` to check before a node of a new architecture joins.

## What this does not do

It does not build, configure, upgrade or recover the machines. No node provisioning, no OS config, no etcd
management, no kubelet upgrades. That belongs to whatever tooling you use, and this repo never talks to it.

Two seams exist so the two sides can cooperate without knowing each other:

| Seam | What it is for |
|---|---|
| `make check-replication-health` | Exits non-zero until Longhorn, CNPG and RabbitMQ are healthy and in sync. Point your node tooling's pre-drain gate at it, so a rolling reboot never takes a volume's last healthy replica |
| `make reconcile-storage NODE=<host>` | Run after your tooling rejoins a replaced machine. Longhorn records a disk UUID that a reflash invalidates, and nothing else fixes it |

Neither is required. Skip both and node maintenance still works; you just lose the interlock.

## Architecture

The shell bootstrap exists only to reach Argo CD. From there, git is the source of truth.

The root-of-roots creates the platform root first, then the workloads root about 5s later. It does NOT wait for
platform health: there is no `argoproj.io/Application` health gate, on purpose. So the boundary is advisory
creation-ordering. A workload that races ahead of a not-yet-present platform CRD fails its sync and converges on
its own via unbounded retry.

```mermaid
flowchart LR
    subgraph os["Your cluster - not this repo"]
        direction TB
        HW["Machines + OS"] --> TAL["Kubernetes, no CNI,<br/>kube-proxy disabled"]
        TAL --> KC["a kubectl context"]
    end
    KC -->|" KUBE_CONTEXT points here "| CIL
    subgraph imp["Shell bootstrap - make (this repo)"]
        direction TB
        CIL["Cilium CNI, 01"] --> ARGO["Argo CD, 02a"]
    end
    ARGO -->|" adopts Cilium, reconciles the git remote "| ROOT["root-of-roots"]
    subgraph gitops["GitOps delivery - Argo CD"]
        direction TB
        ROOT --> PLAT["platform tree, waves 0-8"]
        PLAT -->|" created ~5s later, no health gate "| WORK["workloads tree"]
        PLAT --- PC["Envoy Gateway, cert-manager, Google SSO, Sealed Secrets, Reloader<br/>Longhorn, CNPG, Redis, RabbitMQ<br/>metrics-server, dead-node-watcher, VictoriaMetrics/Logs, Grafana, ntfy"]
        WORK --- WC["sample-user-manager, sample-user-signup, sample-audit-logger"]
    end
```

## Repository layout

```
.
|-- Makefile            # thin dispatcher over lib/shell; run `make help`
|-- .env.example        # template for config + secrets; copy to .env
|-- .env                # your config + secrets (gitignored)
|-- docs/               # the numbered runbook + decision records (01 to 13)
|-- terraform/          # the S3 backup bucket + its scoped IAM writer
|-- lib/
|   |-- shell/          # bootstrap shell scripts + helpers
|   |-- krr/            # the custom KRR rightsizing strategy
|   `-- helm/           # the 4 shared charts consumed as file:// dependencies
|-- argo_apps/          # everything Argo CD delivers (two-tree GitOps)
|   |-- root.yaml       #   root-of-roots (applied once by the 05 script)
|   |-- roots/          #   0_platform -> 1_workloads
|   |-- platform/{apps,charts}/   # apps/ is a chart: Applications in templates/, repoURL in values.yaml
|   `-- workloads/{apps,charts}/
`-- secrets/            # gitignored: this repo's sealed-secrets key + webhook secret (own off-repo store)
```

The `NN_` prefixes mirror the sync-wave: the order Argo *creates* the apps in, roughly 5s apart, with no health
gate, so a later app that races ahead of a dependency just retries until it lands. See
[02_gitops](docs/02_gitops.md).

## Getting started

**Prerequisite: a running Kubernetes cluster meeting
[What this expects of your cluster](#what-this-expects-of-your-cluster), and a kubectl context pointing at
it.** Build it however you like; this repo never talks to that tooling. The only thing that crosses over is
the context in your `~/.kube/config`.

Nothing else is shared on disk. The sealed-secrets key this repo mints lives in its own off-repo `secrets/`
store and never leaves.

Which cluster this repo may touch is then pinned by `KUBE_CONTEXT` in `.env`, and it is not the same thing as
your currently-selected context. Your `~/.kube/config` probably holds work clusters too, and nothing here is
read-only, so the target is stated once rather than inherited from whatever `kubectl config use-context` last
ran. Leave `KUBE_CONTEXT` empty and the first run lists your contexts, asks, and writes the answer back to
`.env`. Every script then derives a single-context kubeconfig from it into gitignored `.cache/kubeconfig`, so
no other cluster is reachable for the length of the run.

Only ever run on macOS, so Linux or WSL may need tweaks. The scripts assume a bash/zsh shell, GNU `make`, and a
POSIX-y environment. On your machine: `git`, `kubectl`, `helm`, `yq`, `kubeseal`.

```bash
# 1. Configure
cp .env.example .env                # then edit: KUBE_CONTEXT, repo URL, domains, ingress IP, secrets. Go over everything.

# 2. Recommended: point `secrets/` at storage that outlives this checkout
ln -s /path/to/your/synced/store secrets   # skip it and bootstrap creates a plain gitignored dir, warning you

# 3. Install the platform
make bootstrap-cluster              # CNI -> stamp values -> push -> Argo CD -> seal secrets -> converge

# 4. Verify
kubectl get applications -n argocd  # watch Argo CD deliver the platform, then workloads
make view-credentials               # login URLs + credentials
```

Instead of `make bootstrap-cluster` you can run the steps in runbook order. Every target maps to a script in
`lib/shell/`; `make help` lists them all. Per-phase reasoning and verification is in [the docs](#documentation).

## Make it your own

Fork the repo, then edit exactly one gitignored file, copied from a committed template:

```bash
cp .env.example .env                 # repo URL, domains, ingress IP, secrets
make configure-values                # stamps it into every chart value Argo CD renders
git add -A && git commit && git push # Argo CD reconciles the REMOTE, never your working tree
```

`make configure-values` is the whole story for per-deployment config: it writes your repo URL into all five
places that carry it, your `BASE_DOMAIN` into every public hostname, the SSO allowlist, the ingress IP, the
ACME email and the Cloudflare zones. It is idempotent, and re-running it after any `.env` change is the
supported way to re-apply config. Because a fork only ever edits `.env`, rebasing on upstream does not conflict.

What to put in it:

- Git remote: `REPO_URL`, your fork. Nothing else references a repo URL by hand.
- Domains: `BASE_DOMAIN` is a registrable domain you own. Platform UIs land on `*.ops.<base>` and workloads on
  `*.app.<base>`; both tiers must stay under the base domain, because one SSO cookie covers them all. A workload
  on its own domain goes in `04_google_sso`'s `extraDomains` (`docs/04_ingress.md`). `INGRESS_LB_IP` is the
  single IP every host resolves to, and must sit inside `LB_RANGE_START`/`LB_RANGE_STOP`.
- TLS and login: `LE_EMAIL`, `SSO_ALLOWLIST`, plus your Google OAuth app (`GOOGLE_SSO_CLIENT_ID` +
  `GOOGLE_SSO_CLIENT_SECRET`). Which hosts are gated is policy, so that list lives in
  `argo_apps/platform/charts/04_google_sso`.
- Registry: `GHCR_USER`, and the GHCR tokens if you use private images.
- Alerting: alerts reach your phone via self-hosted ntfy, no email. Set `NTFY_PHONE_PASSWORD_SECRET`, then
  post-boot run `make configure-ntfy-auth`. See `docs/06_monitoring.md`.
- Backups: off-cluster S3 needs the `AWS_DEPLOY_*` creds plus `S3_BACKUP_BUCKET`. See `docs/10_backups.md`.
- Secrets: every secret is optional. Leaving one empty disables the feature it enables.

Node topology, machine addressing and the Kubernetes version itself are NOT here. They belong to whatever
built the cluster.

## Day-2 operations

| Task                        | Command                                                                |
|-----------------------------|------------------------------------------------------------------------|
| Re-apply `.env` to charts   | `make configure-values`                                                |
| Restore a datastore         | `make restore-cnpg`, `restore-redis`, `restore-longhorn`, `restore-vm` |
| Rightsize requests          | `make krr`                                                             |
| Rotate the SSO client       | `make configure-sso`                                                   |
| Re-seed ntfy auth           | `make configure-ntfy-auth`                                             |
| Back up the sealing key     | `make backup-secrets-key`                                              |
| Redeliver the whole platform| `make rebuild-cluster`                                                 |
| Credentials + login URLs    | `make view-credentials`                                                |

Anything about the nodes themselves (OS or Kubernetes upgrades, adding or recovering a node, resetting the
cluster) belongs to whatever built them. The two seams where that tooling and this repo meet are in
[What this does not do](#what-this-does-not-do).

## Troubleshooting

- **Nodes are `NotReady`**: expected until the Cilium CNI lands (`make install-cilium`, 01).
- **An Argo CD app is `OutOfSync` or "path does not exist"**: you did not git-push. Commit and push
  `argo_apps/**`, including any `Chart.lock` ([docs/02](docs/02_gitops.md)).
- **An app is permanently `OutOfSync` with nothing apparently wrong**: that is the orphan-not-delete signal. A
  stateful CR removed from a live app is kept, not pruned ([docs/10](docs/10_backups.md)).
- **LoadBalancer IP stuck `<pending>`**: `INGRESS_LB_IP` must be inside the Cilium LB pool, on the nodes' L2,
  avoiding the DHCP range and the VIP ([docs/01](docs/01_networking.md)).
- **A gated host loops through Google forever**: its subdomain must sit under the domain it is listed against,
  because each SSO policy sets one cookie domain ([docs/04](docs/04_ingress.md)).
- **`make bootstrap-cluster` refuses to start**: it found no reachable cluster. Build one first, and point
  `KUBE_CONTEXT` at it ([What this expects of your cluster](#what-this-expects-of-your-cluster)).

## Documentation

Each doc holds the why behind a step, with verification commands:

| Doc                                                | Covers                                                                          |
|----------------------------------------------------|---------------------------------------------------------------------------------|
| [01_networking](docs/01_networking.md)             | Cilium as CNI + LoadBalancer + WireGuard (the last imperative infra).           |
| [02_gitops](docs/02_gitops.md)                     | Argo CD, the two-tree app-of-apps, sync-wave convention.                        |
| [03_secrets](docs/03_secrets.md)                   | Sealed Secrets + the master-key custody you can't lose.                         |
| [04_ingress](docs/04_ingress.md)                   | Envoy Gateway, cert-manager, Let's Encrypt, central Google SSO.                 |
| [05_storage](docs/05_storage.md)                   | Longhorn, why nothing is node-local, CloudNativePG.                             |
| [06_monitoring](docs/06_monitoring.md)             | VictoriaMetrics + VictoriaLogs, Grafana, alerting, metrics-server.              |
| [07_sample_workload](docs/07_sample_workload.md)   | An end-to-end app + Postgres behind the Gateway.                                |
| [08_messaging](docs/08_messaging.md)               | The shared RabbitMQ broker and the per-workload topology chart.                 |
| [09_redis](docs/09_redis.md)                       | Standalone Redis instances, persistence modes, resizing.                        |
| [10_backups](docs/10_backups.md)                   | Off-cluster S3 backups for Postgres, Redis, Longhorn and the monitoring stores. |
| [11_renovate](docs/11_renovate.md)                 | Automated dependency updates and when Renovate is allowed to self-merge.        |
| [12_storage_bench](docs/12_storage_bench.md)       | Measuring what Longhorn r2 costs CNPG and RabbitMQ in write latency.            |
| [13_node_loss](docs/13_node_loss.md)               | What the workloads do when a machine dies, measured, and reconciling a replaced one. |
| [14_igpu](docs/14_igpu.md)                         | The Intel iGPU: what the driver needs, how a pod claims it, and why no NFD.        |

Repo-wide conventions (layout, where a value lives, chart and Argo CD rules) are in
[CONTRIBUTING.md](CONTRIBUTING.md).


## Credits

Built on the work of the [Cilium](https://cilium.io/),
[Argo CD](https://argo-cd.readthedocs.io/), [cert-manager](https://cert-manager.io/),
[Envoy Gateway](https://gateway.envoyproxy.io/), [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets),
[Longhorn](https://longhorn.io/), [CloudNativePG](https://cloudnative-pg.io/),
[VictoriaMetrics](https://victoriametrics.com/) and [Grafana](https://grafana.com/) communities.

## License

MIT. See [LICENSE](LICENSE).
