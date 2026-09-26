# Contributing

Conventions for the whole repo. A rule for one area lives in the `docs/NN_*.md` of that area.

## Repository layout

The repo is organized by kind. The `NN` prefix of a file name sorts files into step order.

| Path | Holds |
|---|---|
| `lib/shell/` | every bootstrap script (`NN_name.sh`, plus the `DANGEROUS_*` orchestrators) and the shared `common.sh` |
| `docs/` | the decision record for each area (`NN_name.md`) |
| `docs/runbooks/` | the operator procedures for an area, under the same `NN_name.md` as its decision doc |
| `lib/helm/` | shared charts that other charts use as a `file://` dependency |
| `lib/krr/` | the custom KRR rightsizing strategy |
| `lib/bench/` | static inputs for `lib/shell/storage_bench.sh`: the fio job files and the pgbench percentile awk script |
| `argo_apps/` | everything Argo CD delivers, in two GitOps trees |
| `Makefile` | a thin dispatcher over `lib/shell/` and the orchestrators. `make help` lists every target |
| `terraform/` | the S3 backup bucket and its scoped IAM writer, used by steps 10a to 10e |
| `.env` | gitignored. Config and secrets for one deployment, in two blocks: CONFIG, then SECRETS. The template is `.env.example` |
| `secrets/` | the credentials of this repo: the sealed-secrets master key and the Argo CD webhook secret. A symlink to an off-repo store, never committed |
| `.cache/` | scratch space for benchmark runs. Gitignored |

This repo starts from a cluster that already exists and shares nothing on disk with the tooling that built it.
Only a kubectl context crosses over.

## Where a value lives

Every value lives in exactly one place.

| Kind of value | Lives in |
|---|---|
| Upstream chart versions and digest pins | the `Chart.yaml` of each chart |
| Per-deployment scalars (domains, ingress IP, backups) and all secrets | `.env`, gitignored |
| Fixed identifiers that are not per-deployment config (namespaces, operator names) | constants in `lib/shell/common.sh` |
| Internals of one script (its own check expectations, asset file names, tool refs only it runs) | that script |

**Never hand-edit a per-deployment value into a chart.** `lib/shell/04_values.sh` (`make configure-values`) writes
every one from `.env`. That is what lets a fork change one gitignored file and rebase on upstream without
conflicts. To add a per-deployment value, add it to `.env.example` and make `04_values.sh` write it.

`04_values.sh` only writes values, and it must stay that way. Argo CD reconciles the pushed remote. So these
values must be committed and pushed before the bootstrap reaches `02a_argocd.sh`. Anything that applies to the
cluster, such as sealing a secret, goes in a later step.

`.env` holds plain `KEY=value` lines only. No logic, no arrays, no command substitution. `common.sh` derives
everything else. Scripts read secrets from `.env` and never prompt for them.

## Bootstrap scripts

- **Output:** use the helpers from `common.sh` and end with `summary`. Exit non-zero on any failure.
- **Idempotent:** a script must be safe to run again. Running it again after a partial failure is the normal
  recovery.
- **Knobs:** put script-local tunables in a `# ---- knobs ----` block near the top, as plain assignments. No
  `${VAR:-default}` overrides from the environment. To change a value, edit it.
- **Shell options:** PASS/FAIL scripts use `set -uo pipefail`, without `-e`, so that all checks run and the
  summary is complete. One-shot scripts that must stop at the first error use `-euo`.
- **Tools:** use the native `helm` and `kubectl`. A tool that needs a pinned version, such as KRR, runs in Docker.
- **Cluster access:** call `use_kubeconfig` before you touch the cluster, and `assert_api` after it. It pins every
  command to `KUBE_CONTEXT`.
- **`DANGEROUS_` prefix:** on anything that wipes or resets state, so nobody runs it by reflex.
- **Never write a tracked YAML file with `yq -i`.** It rewrites the whole file, so even a no-op write leaves it
  dirty and stops the rebuild at the uncommitted-changes gate in `02a_argocd`. Use the `ys_set*` writers in
  `common.sh`, and read the result back with `yq -r`.

## Helm wrapper charts

Every app that Argo CD manages is a thin wrapper chart under the `charts/` dir of its tree. `Chart.yaml` pins the
upstream version, and `values.yaml` holds all configuration.

A bootstrap script that installs an app uses the same chart, release name and namespace as Argo CD. So Argo CD
adopts the running release in sync, and no pod restarts.

**Commit `Chart.lock` only for a remote dependency.**

- A chart with an `https` or `oci` dependency keeps its lock in git. The Argo CD repo-server builds from it, so a
  missing or stale lock breaks the sync. `make fix-chart-locks` regenerates it.
- A chart whose dependencies are all `file://` gitignores its lock. Git already pins those, and a lock only
  breaks the sync when it goes stale.
- Never add `charts/*.tgz` to git.

### Shared charts (`lib/helm/`)

Charts in both trees use these as `file://` dependencies, so Argo CD does not deliver them directly. Each
`Chart.yaml` description says what the chart renders.

Each chart hardcodes the cluster wiring as a platform invariant, not as a value for each consumer:

- `ingress`: the gateway namespace, the gateway class and the fallback issuer
- `rabbitmq-topology`: the broker and the vhost

## Argo CD apps

```
argo_apps/
  root.yaml                 # root-of-roots, applied once by 02a_argocd.sh
  roots/                    #   platform (wave 0) and workloads (wave 1)
  platform/{apps,charts}/   # CNI, operators, CRDs, storage, gateway, SSO, monitoring, platform-ingress
  workloads/{apps,charts}/  # the actual apps
```

Each `apps/` dir is itself a Helm chart. Its `templates/` holds the Applications, and its `values.yaml` holds
`repoURL` once per tree.

- **Waves order creation, not health.** There is deliberately no health gate on `argoproj.io/Application`. So the
  boundary between platform and workloads only orders creation. An app that starts before a dependency exists
  fails its sync. Unbounded retry then converges it.
- **Keep three things in agreement for a platform app:** the `apps/templates/NN_name.yaml` prefix, the
  `charts/NN_name/` prefix, and the `argocd.argoproj.io/sync-wave: "N"` annotation. Pick the lowest wave after
  everything the app depends on. Do not renumber without a reason.
- **Workloads carry no wave.** Workloads need no order among themselves. If a workload really depends on another,
  it belongs in platform.
- **Every app stays `automated` with unbounded retry** (`retry.limit: -1`, `refresh: true`). There is no health
  gate, so retry is the only thing that converges an app by itself.
- **Every Application carries the `resources-finalizer`.** So removing or renaming an Application deletes its
  resources with it, and none are orphaned. `prune` only works inside one app and does not cascade on deletion.
- **Every app that runs pods carries an explicit `CiliumNetworkPolicy`.** It denies all traffic both ways by
  default and rolls out in audit mode first. The exceptions are on the unpoliced list in `docs/01_networking.md`.
  Two gotchas:
  - A peer in another namespace needs
    `matchExpressions: [{key: k8s:io.kubernetes.pod.namespace, operator: Exists}]`. Without a namespace label, the
    selector matches the same namespace only.
  - Disable any vanilla `NetworkPolicy` that an upstream chart bundles. Those allow all egress by default, and
    Cilium combines them with ours.
- **Alerting is Grafana only.** `vmalert` and `alertmanager` are off, so any `PrometheusRule` or `VMRule` has no
  effect. Never enable the bundled alerts of a chart. Add a Grafana alert file under
  `argo_apps/platform/charts/05_grafana/files/alerts/` instead. `kubectl get vmrule -A` must always stay empty.
- **Roll forward only.** Recovery is a git revert that Argo CD syncs, never `argocd app rollback`. So every
  Application and first-party chart sets `revisionHistoryLimit: 0`.
- **Push before you expect a sync.** Argo CD reconciles the pushed remote, not your working tree.

Cilium is the one app that can cut the cluster off its own network. It still syncs automatically with full
`selfHeal` and `prune`. So Argo CD reverts any out-of-band emergency fix that you do not commit. A bad Cilium
change pushed to git also applies with nobody watching. Push with care.

## Docs

Each fact lives in one place.

| Where | Holds |
|---|---|
| `docs/NN_*.md` | decisions and architecture: why a component or setting is there, what it beat, what it costs. Only the measurements a decision rests on |
| `docs/runbooks/NN_*.md` | operator procedures as numbered steps. The decision doc links to its runbook and holds no steps |
| a code comment | how a non-obvious mechanism works, on the exact line it explains. Nothing the code already shows |

- Fragments, bullets and tables over paragraphs. Keep documents short.
- State the current reason, not the history. This repo rolls forward, and a note about the past only goes stale.
- `values.yaml`, `.env.example` and `variables.tf` are the API. Every tunable knob in them gets one aligned
  trailing comment.
