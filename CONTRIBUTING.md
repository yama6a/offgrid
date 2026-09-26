# Contributing

Conventions for the whole repo. A rule for one step lives in the `docs/NN_*.md` of that step. Decisions and
trade-offs belong there too, not in a code comment and not here.

## Repository layout

The repo is organized by kind. File names carry the runbook order: the `NN` prefix sorts files into step order.

| Path | Holds |
|---|---|
| `lib/shell/` | every bootstrap script (`NN_name.sh`, plus the `DANGEROUS_*` orchestrators) and the shared `common.sh` |
| `docs/` | the narrative and decision record for each step (`NN_name.md`) |
| `lib/helm/` | shared charts that other charts use as a dependency |
| `lib/bench/` | static inputs for `lib/shell/storage_bench.sh`: the fio job files and the pgbench percentile awk script |
| `argo_apps/` | everything Argo CD delivers, in two GitOps trees |
| `Makefile` | a thin dispatcher over `lib/shell/` and the orchestrators. `make help` lists every target |
| `terraform/` | the S3 backup bucket and its scoped IAM writer, used by steps 10a to 10e |
| `.env` | gitignored. Config and secrets for one deployment, in two blocks: CONFIG, then SECRETS. The template is `.env.example` |
| `secrets/` | the credentials of this repo: the sealed-secrets master key and the Argo CD webhook secret. A symlink to an off-repo store, never committed |
| `.cache/` | scratch space for benchmark runs. Gitignored |

Run the steps in order: `01_cilium`, `02a_argocd`, and on. Run each by hand (`bash lib/shell/NN_name.sh`) or
through the Makefile.

This repo starts from a cluster that already exists. Other tooling builds, configures and recovers the machines.
This repo shares nothing on disk with that tooling. Only an active kubectl context crosses over. The README
section "What this expects of your cluster" lists what the cluster must provide.

`KUBE_CONTEXT` in `.env` pins the cluster that this repo may touch. The scripts never infer it from the selected
context.

- `use_kubeconfig` in `common.sh` is the one place that applies the pin.
- It writes a kubeconfig with only that context, with certs inlined, to gitignored `.cache/kubeconfig`.
- It exports `KUBECONFIG` to point at that file. Every later `kubectl`, `helm` and `kubeseal` uses it, so no
  other cluster is reachable.
- Call `use_kubeconfig` before you touch the cluster, and `assert_api` after it.
- Set `KUBECONFIG_SOURCE` to read the contexts from a file other than `~/.kube/config`.

## Where a value lives

Every value lives in exactly one place.

| Kind of value | Lives in |
|---|---|
| Upstream chart versions and digest pins | the `Chart.yaml` of each chart |
| Per-deployment scalars (domains, ingress IP, backups) and all secrets | `.env`, gitignored |
| Fixed identifiers that are not per-deployment config (namespaces, operator names) | constants in `lib/shell/common.sh` |
| Internals of one script (its own check expectations, asset file names, tool refs only it runs) | that script |

**Never hand-edit a per-deployment value into a chart.** `lib/shell/04_values.sh` (`make configure-values`) reads
`.env` and writes each value into the chart values that Argo CD renders:

- the repo URL, into all five places that carry it
- `BASE_DOMAIN`, into every public hostname
- the SSO allowlist, the ingress IP, the ACME email and the Cloudflare zones

So a fork changes one gitignored file, and a rebase on upstream causes no conflicts. To add a per-deployment
value, add it to `.env.example` and make `04_values.sh` write it. Do not commit it into a chart.

`04_values.sh` only writes values, and it must stay that way. Argo CD reconciles the pushed remote. So these
values must be committed and pushed before the bootstrap reaches `02a_argocd.sh`. Anything that applies to the
cluster, such as sealing a secret, goes in a later step.

`04_values.sh` reads one thing from the cluster: the control-plane node IPs. These become the scrape endpoints of
vm-k8s-stack. Many distributions bind controller-manager, scheduler and etcd to localhost, so the stack scrapes
them on each node. The script reads the IPs from the API, not from a config file. So a new control-plane node
gets into the endpoint list on the next run.

`.env` holds plain `KEY=value` lines only. No logic, no arrays, no command substitution.

- `common.sh` derives everything else. For example, it derives `OPS_DOMAIN` and `APP_DOMAIN` from `BASE_DOMAIN`.
- Scripts read secrets from `.env` and never prompt for them.
- `common.sh` defaults each secret to empty, so an older `.env` does not fail `set -u`.
- An empty secret skips the feature that it enables.

## Bootstrap scripts

- **Output:** use the helpers from `common.sh`. That is `say`, `die`, `warn`, `ok` and `bad`, the `PASS` and
  `FAIL` counters, and a final `summary`. Exit non-zero on any failure.
- **Idempotent:** a script must be safe to run again. Running it again after a partial failure is the normal
  recovery.
- **Knobs:** put script-local tunables in a `# ---- knobs ----` block near the top, as plain assignments. No
  `${VAR:-default}` overrides from the environment. To change a value, edit it.
- **Shell options:** PASS/FAIL scripts use `set -uo pipefail`, without `-e`, so that all checks run and the
  summary is complete. One-shot scripts that must stop at the first error use `-euo`.
- **Tools:** scripts that apply to the cluster use the native `helm` and `kubectl`, and fail hard if either is
  missing. A tool that needs a pinned version, such as KRR, runs in Docker.
- **`DANGEROUS_` prefix:** on anything that wipes or resets state, so nobody runs it by reflex.

### `common.sh`

Every script sources `common.sh`. It finds the repo root, loads `.env`, and derives the `ops.` and `app.` tiers
from `BASE_DOMAIN`. It provides the output helpers, `require`, `use_kubeconfig`, `seal_secret`, and the values
writers.

**Never write a tracked YAML file with `yq -i`.** `yq -i` rewrites the whole document and drops the blank line
before a comment block. So even a write that changes no value leaves the file dirty. The uncommitted-changes gate
in `02a_argocd` then stops the rebuild. Use the line-level writers below, and check the result with a `yq -r`
read.

| Writer | Sets |
|---|---|
| `ys_set <file> <value> <key...>` | one scalar at a nested mapping path |
| `ys_set_list <file> "<space-separated>" <key...>` | a whole block sequence of scalars |
| `ys_set_each <file> <value> <key...> <leaf>` | one key on every item of a block sequence |

Use `yq` for reads.

## Helm wrapper charts

Every app that Argo CD manages is a thin wrapper chart under the `charts/` dir of its tree.

- `Chart.yaml` pins the upstream version. Nothing else does.
- `values.yaml` holds all configuration.
- The `version:` of a first-party chart has no effect and stays `0.1.0`. Nothing publishes these charts. Argo CD
  renders from the git path, and every consumer pins its `file://` dependency at `"*"`. Never bump it.

The bootstrap script and Argo CD use the same chart, release name and namespace. So Argo CD adopts the running
release in sync, and no pod restarts.

**Commit `Chart.lock` only for a remote dependency.**

- A chart with an `https` or `oci` dependency commits its lock. The Argo CD repo-server runs
  `helm dependency build`, and a missing or stale lock breaks the sync. `make fix-chart-locks` regenerates a lock.
- A chart whose dependencies are all `file://` has no lock and gitignores it. The git commit already fixes those
  dependencies. A lock pins nothing and breaks the sync when it goes stale.
- In both cases, gitignore `charts/*.tgz` and never commit one.

### Shared charts (`lib/helm/`)

Charts in both trees use these as `file://` dependencies, so Argo CD does not deliver them directly. All are
`type: application` and render from values. None pins an upstream, so none ships a lock or a tgz.

| Chart | Renders |
|---|---|
| `ingress` | the ingress edge: a Gateway, HTTPRoute and ReferenceGrant for each host, and one multi-SAN Certificate for each ingress |
| `pg-cluster` | the CNPG `Cluster`, a `PodMonitor`, and a pair of default-deny CNPs. With backups on, also the Barman `ObjectStore` and the `ScheduledBackup` |
| `redis-instance` | one standalone `Redis` CR, its ServiceMonitor, and a default-deny CNP |
| `rabbitmq-topology` | a `User` with credentials that the operator generates, its exchanges, queues and bindings, a `.dlx`/`.dlq` pair for each consumer queue, and one combined `Permission` |

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

Each `apps/` dir is itself a Helm chart. Its `templates/` holds the Applications. `repoURL` comes from the
`values.yaml` of that chart, so it exists once per tree and not once per app. `ls argo_apps/platform/apps/templates/`
lists the apps in deploy order.

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

`docs/NN_*.md` holds the reasons.

- Fragments, bullets and tables over paragraphs.
- State the current reason, not the history. This repo rolls forward, and a note about the past only goes stale.

Code comments are the exception, not the habit.

- Write one only when the code cannot show the reason.
- Keep it short, and put it on the exact line it explains.
- `values.yaml`, `.env.example` and `variables.tf` are the API. Every tunable knob in them gets one aligned
  trailing comment.
