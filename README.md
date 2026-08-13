# offgrid

**A 3x Raspberry Pi 5 Kubernetes cluster on [Talos Linux](https://www.talos.dev/), networked by
[Cilium](https://cilium.io/), delivered by [Argo CD](https://argo-cd.readthedocs.io/).**

![Talos](https://img.shields.io/badge/Talos-Linux-ff7300)
![Kubernetes](https://img.shields.io/badge/Kubernetes-326ce5?logo=kubernetes&logoColor=white)
![CNI: Cilium](https://img.shields.io/badge/CNI-Cilium-f8c517?logo=cilium&logoColor=white)
![GitOps: Argo CD](https://img.shields.io/badge/GitOps-Argo%20CD-ef7b4d?logo=argo&logoColor=white)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)
![Last commit](https://img.shields.io/github/last-commit/yama6a/offgrid)

<p align="center">
  <img src="docs/images/rackmount_0.jpeg" alt="The assembled 3-node Raspberry Pi 5 cluster in a 10-inch rack" width="600">
</p>

> The platform: everything that runs *on* a Kubernetes cluster, delivered by Argo CD from this repo. Ingress,
> TLS, SSO, storage, databases, messaging, monitoring, backups, and a sample workload on top.
>
> It starts from a cluster that already exists. Building that cluster (hardware, Talos, etcd, node lifecycle) is
> [talos-raspberry-pi5-cluster](https://github.com/yama6a/talos-raspberry-pi5-cluster), which hands over a `kubeconfig`.
>
> Every per-deployment value lives in `.env`, and `make configure-values` stamps it into the chart values Argo CD
> renders, so a fork changes one gitignored file and nothing else.
> See **[Make it your own](#make-it-your-own)** to get started.

## Contents

- [Overview](#overview)
- [The stack](#the-stack)
- [Hardware](#hardware)
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

- Starts from a Kubernetes cluster that already exists. Building it is the OS repo's job.
- `01_cilium.sh` and `02a_argocd.sh` are the only imperative steps: install the CNI, then install Argo CD.
- Everything after that is GitOps. Argo CD reconciles `argo_apps/` and delivers the platform (ingress, TLS, SSO,
  storage, databases, messaging, monitoring) plus the workloads on top.
- Config is one gitignored file, `.env`, copied from the committed `.env.example`. `make configure-values`
  stamps it into every chart value Argo CD renders. Nothing is hardcoded in a script.
- Every app is a thin Helm wrapper chart pinning its upstream version. `docs/01` to `docs/12` hold the why.

## The stack

Everything after `04`/`05` is an Argo CD-delivered wrapper chart, each pinning its upstream version in its own
`Chart.yaml`. That file is the source of truth; no version is restated anywhere else.

| Layer             | Component                      | Role                                                                                                         |
|-------------------|--------------------------------|--------------------------------------------------------------------------------------------------------------|
| **OS**            | Talos Linux                    | Immutable, API-driven Kubernetes OS. Built and installed by the OS repo, not here.                           |
| **Network**       | Cilium                         | CNI + kube-proxy replacement, LB-IPAM + L2 announcements (LoadBalancer IPs), node-to-node WireGuard, Hubble. |
| **GitOps**        | Argo CD                        | Delivery engine; self-manages after bootstrap. Two-tree app-of-apps (platform and workloads).                |
| **Ingress**       | Envoy Gateway                  | Gateway API data plane; one Envoy on a single pinned LoadBalancer IP.                                        |
| **TLS**           | cert-manager                   | Let's Encrypt certificates via ClusterIssuers (HTTP-01, plus Cloudflare DNS-01 for wildcards).               |
| **Auth**          | Google SSO                     | Central OIDC (one Envoy `SecurityPolicy`, one email allowlist, per-host gating).                                 |
| **Secrets**       | Sealed Secrets                 | Encrypted secrets committed to git.                                                                          |
| **Storage**       | Longhorn                       | Replicated block storage, for everything stateful, so a volume outlives the machine under it.                |
| **Node health**   | dead-node-watcher              | Custom Deployment that taints a genuinely dead node, cutting volume handover from ~6 min to ~2.               |
| **Database**      | CloudNativePG                  | Kubernetes-native PostgreSQL operator.                                                                       |
| **Cache**         | OpsTree Redis operator         | Standalone Redis instances, one per workload alias.                                                          |
| **Messaging**     | RabbitMQ                       | One shared broker; workloads declare their own topology.                                                     |
| **Metrics API**   | metrics-server                 | `metrics.k8s.io` for `kubectl top` and HPAs.                                                                 |
| **NIC**           | nic-keeper                     | Custom DaemonSet that keeps the flaky Pi 5 `macb` NIC and VIP healthy.                                       |
| **Observability** | VictoriaMetrics + VictoriaLogs | PromQL-compatible metrics and logs backend (over Prometheus/Mimir + Loki, for 8 GB nodes).                   |
| **Observability** | Grafana                        | Dashboards + alerting, provisioned as code. No persistence layer.                                            |
| **Alerting**      | ntfy                           | Self-hosted mobile push. No email.                                                                           |
| **Observability** | blackbox-exporter              | Probes every ingress host over its public name, so a broken edge is caught without traffic.                  |
| **Workloads**     | sample-user-manager + 2 more   | Demo app + Postgres + Redis + messaging + open/SSO ingress: the template for real workloads.                 |

Four shared charts under `lib/helm/` are consumed as `file://` dependencies, all `type: application`:

- `ingress`: the ingress edge (Gateway, HTTPRoute, ReferenceGrant, Certificate) from an `ingresses[]` list
- `pg-cluster`: a curated CloudNativePG Postgres wrapper
- `redis-instance`: a curated standalone OpsTree Redis wrapper
- `rabbitmq-topology`: a workload's messaging topology against the shared broker

## Hardware

Built and documented in the OS repo: 3x Raspberry Pi 5 (8 GB), all control-plane, NVMe-booted. Nothing here
assumes that hardware beyond the two charts it consumes from there (`nic-keeper`, `coredns`). See
[its docs](https://github.com/yama6a/talos-raspberry-pi5-cluster/blob/main/docs/01_hardware.md).

## Architecture

The shell bootstrap exists only to reach Argo CD. From there, git is the source of truth.

The root-of-roots creates the platform root first, then the workloads root about 5s later. It does NOT wait for
platform health: there is no `argoproj.io/Application` health gate, on purpose. So the boundary is advisory
creation-ordering. A workload that races ahead of a not-yet-present platform CRD fails its sync and converges on
its own via unbounded retry.

```mermaid
flowchart LR
    subgraph imp["Shell bootstrap - make"]
        direction TB
        HW["Hardware + EEPROM<br/>docs 01-02"] --> IMG["Flash the Talos Pi 5<br/>image release, 03a-03b"]
        IMG --> TAL["Talos machine config<br/>+ etcd + NIC hardening, 03c-03d"]
        TAL --> CIL["Cilium CNI, 04"]
        CIL --> ARGO["Argo CD, 05"]
    end
    ARGO -->|" adopts Cilium, reconciles the git remote "| ROOT["root-of-roots"]
    subgraph gitops["GitOps delivery - Argo CD"]
        direction TB
        ROOT --> PLAT["platform tree, waves 0-8"]
        PLAT -->|" created ~5s later, no health gate "| WORK["workloads tree"]
        PLAT --- PC["Envoy Gateway, cert-manager, Google SSO, Sealed Secrets<br/>Longhorn, CNPG, Redis, RabbitMQ<br/>metrics-server, nic-keeper, dead-node-watcher, VictoriaMetrics/Logs, Grafana, ntfy"]
        WORK --- WC["sample-user-manager, sample-user-signup, sample-audit-logger"]
    end
```

## Repository layout

```
.
|-- Makefile            # thin dispatcher over lib/shell; run `make help`
|-- .env.example        # template for config + secrets; copy to .env
|-- .env                # your config + secrets (gitignored)
|-- docs/               # the numbered runbook + decision records (01 to 12)
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
`-- secrets/            # gitignored: talos certs, talosconfig, kubeconfig, sealed key
```

The `NN_` prefixes mirror the sync-wave: the order Argo *creates* the apps in, roughly 5s apart, with no health
gate, so a later app that races ahead of a dependency just retries until it lands. See
[02_gitops](docs/02_gitops.md).

## Getting started

**Prerequisite: a running Talos cluster.** Build it first in
[talos-raspberry-pi5-cluster](https://github.com/yama6a/talos-raspberry-pi5-cluster), which ends by printing the handoff:

```bash
# in the OS repo
make bootstrap-cluster              # flashes, configures Talos, bootstraps etcd, writes secrets/kubeconfig
```

Both repos read the same credentials, because `secrets/` is a symlink to the same off-repo store in each. If
that symlink is missing here, point it at the same directory before continuing.

Only ever run on macOS, so Linux or WSL may need tweaks. The scripts assume a bash/zsh shell, GNU `make`, and a
POSIX-y environment. On your machine: `git`, `kubectl`, `helm`, `yq`, `kubeseal`.

```bash
# 1. Configure
cp .env.example .env                # then edit: repo URL, domains, ingress IP, secrets. Go over everything.

# 2. Install the platform
make bootstrap-cluster              # CNI -> stamp values -> push -> Argo CD -> seal secrets -> converge

# 3. Verify
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
  `*.app.<base>`; both tiers must stay under the base domain, because one SSO cookie covers them all.
  `INGRESS_LB_IP` is the single IP every host resolves to, and must sit inside `LB_RANGE_START`/`LB_RANGE_STOP`.
- TLS and login: `LE_EMAIL`, `SSO_ALLOWLIST`, plus your Google OAuth app (`GOOGLE_SSO_CLIENT_ID` +
  `GOOGLE_SSO_CLIENT_SECRET`). Which hosts are gated is policy, so that list lives in
  `argo_apps/platform/charts/04_google_sso`.
- Registry: `GHCR_USER`, and the GHCR tokens if you use private images.
- Alerting: alerts reach your phone via self-hosted ntfy, no email. Set `NTFY_PHONE_PASSWORD_SECRET`, then
  post-boot run `make configure-ntfy-auth`. See `docs/06_monitoring.md`.
- Backups: off-cluster S3 needs the `AWS_DEPLOY_*` creds plus `S3_BACKUP_BUCKET`. See `docs/10_backups.md`.
- Secrets: every secret is optional. Leaving one empty disables the feature it enables.

The node topology, VIP and Talos version are NOT here. They belong to the OS repo,
[talos-raspberry-pi5-cluster](https://github.com/yama6a/talos-raspberry-pi5-cluster).

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

Anything about the nodes themselves (Talos or Kubernetes upgrades, adding or recovering a node, resetting the
cluster) is in the OS repo: [talos-raspberry-pi5-cluster](https://github.com/yama6a/talos-raspberry-pi5-cluster).

## Troubleshooting

- **Nodes are `NotReady`**: expected until the Cilium CNI lands (`make install-cilium`, 04).
- **An Argo CD app is `OutOfSync` or "path does not exist"**: you did not git-push. Commit and push
  `argo_apps/**`, including any `Chart.lock` ([docs/02](docs/02_gitops.md)).
- **An app is permanently `OutOfSync` with nothing apparently wrong**: that is the orphan-not-delete signal. A
  stateful CR removed from a live app is kept, not pruned ([docs/10](docs/10_backups.md)).
- **LoadBalancer IP stuck `<pending>`**: `INGRESS_LB_IP` must be inside the Cilium LB pool, on the nodes' L2,
  avoiding the DHCP range and the VIP ([docs/01](docs/01_networking.md)).
- **A gated host loops through Google forever**: its subdomain must sit under `BASE_DOMAIN`, because the SSO
  policy sets one cookie domain ([docs/04](docs/04_ingress.md)).
- **`make bootstrap-cluster` refuses to start**: it found no reachable cluster. Build one first in the OS repo,
  [talos-raspberry-pi5-cluster](https://github.com/yama6a/talos-raspberry-pi5-cluster).

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

Hardware, Talos bring-up and node recovery are documented in the OS repo,
[talos-raspberry-pi5-cluster](https://github.com/yama6a/talos-raspberry-pi5-cluster).

Repo-wide conventions (layout, where a value lives, chart and Argo CD rules) are in
[CONTRIBUTING.md](CONTRIBUTING.md).


## Credits

Built on the work of the Talos/[Sidero](https://www.talos.dev/), [Cilium](https://cilium.io/),
[Argo CD](https://argo-cd.readthedocs.io/), [cert-manager](https://cert-manager.io/),
[Envoy Gateway](https://gateway.envoyproxy.io/), [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets),
[Longhorn](https://longhorn.io/), [CloudNativePG](https://cloudnative-pg.io/),
[VictoriaMetrics](https://victoriametrics.com/) and [Grafana](https://grafana.com/) communities. The Pi 5 Talos
image comes from [yama6a/talos-raspberry-pi5](https://github.com/yama6a/talos-raspberry-pi5), which credits its
own upstreams.

## License

MIT. See [LICENSE](LICENSE).
