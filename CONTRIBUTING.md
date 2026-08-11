# Contributing

Conventions that span the whole repo. Anything specific to one step lives in that step's `docs/NN_*.md`, which
is where a decision or trade-off belongs, not in a code comment and not here.

## Repository layout

Organized by kind. The runbook order lives in the file NAMES, where the `NN` prefix keeps things in step order
at a glance.

| Path | Holds |
|---|---|
| `lib/shell/` | every bootstrap script (`NN_name.sh`, plus the `DANGEROUS_*` orchestrators) and the shared `common.sh` |
| `docs/` | the narrative and decision record per step (`NN_name.md`) |
| `lib/helm/` | shared charts consumed as a dependency by other charts |
| `lib/bench/` | static payloads for `lib/shell/storage_bench.sh`: the fio job files and the pgbench percentile awk |
| `argo_apps/` | everything Argo CD delivers, the two-tree GitOps root |
| `Makefile` | a thin dispatcher over `lib/shell/` plus the orchestrators. `make help` lists every target |
| `versions.env` | committed. The shared, renovate-managed version recipe: upstream versions + digest pins |
| `inventory.yaml` | gitignored. One entry per node. `inventory.example.yaml` is the template and documents the fields |
| `.env` | gitignored. Per-deployment config + secrets, in two blocks: CONFIG then SECRETS. Template: `.env.example` |
| `lib/talos/` | static Talos payloads: the Image Factory schematic per node type without a custom build |
| `secrets/` | cluster credentials written by `03c`. A symlink to an off-repo store, gitignored, never committed |
| `.cache/` | scratch: downloaded Talos images, benchmark runs. Gitignored |

Run the steps in order: `02_raspi_eeprom`, then `03a` to `03g`, then `04_cilium`, `05_argocd`, and onward.
Either by hand (`bash lib/shell/NN_name.sh`) or via the Makefile.

## Where a value lives

Every value lives in exactly one place.

| Kind of value | Lives in |
|---|---|
| Versions and digest pins | `versions.env`, committed |
| The node list: per-node role, hardware type and image source | `inventory.yaml`, gitignored |
| Per-deployment scalars (domains, VIP, sizing) and all secrets | `.env`, gitignored |
| Fixed identifiers that are not per-deployment config (namespaces, operator names, the Pi 5 NIC and disk, the Talos API port) | constants in `lib/shell/common.sh` |
| Internals used by one script (its own check expectations, asset filenames, tool refs it alone runs) | that script |

**No per-deployment value is ever hand-edited into a chart.** `lib/shell/07_values.sh` (`make configure-values`)
reads `.env` and `inventory.yaml` and stamps every one of them into the chart values Argo CD renders: the repo
URL in all five places that carry it, `BASE_DOMAIN` into every public hostname, the SSO allowlist, the ingress
IP, the ACME email, the Cloudflare zones, and the control-plane scrape endpoints. That is what lets a fork
change two gitignored files and rebase on upstream without conflicts. If you add a per-deployment value, add it
to `.env.example` and teach `07_values.sh` to write it; do not commit it into a chart.

It must keep running with **no cluster**: Argo CD reconciles the pushed remote, so these values have to be
committed and pushed before the bootstrap reaches `05_argocd.sh`. Anything needing a live cluster (sealing a
secret) goes in a later step instead.

`.env` is plain `KEY=value` only: no logic, arrays or command substitution. Anything derived is derived in
`common.sh` (`OPS_DOMAIN` and `APP_DOMAIN` from `BASE_DOMAIN`, for example). Node topology outgrew that, which
is why it is a separate YAML file. Secrets are read from `.env`, never prompted; `common.sh` defaults each to
empty so an older `.env` does not trip `set -u`, and an empty secret skips the feature it enables.

## Bootstrap scripts

- UX contract from `common.sh`: `say`/`die`/`warn`/`ok`/`bad`, `PASS`/`FAIL` counters, a trailing `summary`,
  non-zero exit on any failure.
- Idempotent and re-run-safe. Re-running after a partial failure is the normal recovery path.
- A `# ---- knobs ----` block near the top for script-local tunables, as plain assignments. No
  `${VAR:-default}` env overrides: to change a value, edit it.
- `set -uo pipefail`, deliberately not `-e` in the PASS/FAIL scripts so checks accumulate and report a full
  summary. One-shot scripts that should abort early use `-euo`.
- Talos work runs its tooling in Docker; apply-to-cluster scripts use native `helm`/`kubectl` and hard-fail if
  either is missing.
- A `DANGEROUS_` prefix on anything that wipes or resets state, so it cannot be run by reflex.

### `common.sh`

Sourced by every script. It self-locates the repo root, loads `versions.env` then `.env`, derives what a flat
file cannot express, parses `inventory.yaml` into the per-role arrays, and provides the output helpers,
`require`, `use_kubeconfig`, a dockerized `talosctl`, `seal_secret`, and the values writers.

**Never write a tracked YAML file with `yq -i`.** It rewrites the whole document and drops the blank line before
a comment block, so even a no-op write leaves the file dirty, which aborts the rebuild at `05_argocd`'s
uncommitted-changes gate. Use the line-surgical writers instead, and assert the result with a `yq -r` read-back:

| Writer | Sets |
|---|---|
| `ys_set <file> <value> <key...>` | one scalar at a nested mapping path |
| `ys_set_list <file> "<space-separated>" <key...>` | a whole block sequence of scalars |
| `ys_set_each <file> <value> <key...> <leaf>` | one key on EVERY item of a block sequence |

`yq` is still the right tool for reads.

## Helm wrapper charts

Every app Argo CD manages is a thin wrapper chart under its tree's `charts/` dir. `Chart.yaml` pins the upstream
version and nothing else does; `values.yaml` holds all configuration. A first-party chart's own `version:` is
inert and stays `0.1.0` forever: nothing publishes these, Argo CD renders from the git path, and every consumer
pins its `file://` dep at `"*"`. Never bump it.

The imperative bootstrap script and Argo CD consume the same chart, release name and namespace, so Argo adopts
the running release in-sync with no pod churn.

**`Chart.lock`: commit it only for a REMOTE dependency.** A chart with an `https`/`oci` dep commits its lock,
because Argo CD's repo-server runs `helm dependency build` and a missing or stale lock breaks sync
(`make fix-chart-locks` regenerates one). A chart whose deps are all `file://` is lockless and gitignores it:
the git commit already fixes those deps, so a lock pins nothing and only breaks sync when it goes stale. Either
way, gitignore `charts/*.tgz` and never commit one.

### Shared charts (`lib/helm/`)

Consumed as `file://` dependencies rather than by Argo CD directly, because charts in both trees use them. All
`type: application`, all render from values, none pins an upstream, so none ships a lock or a tgz.

| Chart | Renders |
|---|---|
| `ingress` | the ingress edge: per host a Gateway, HTTPRoute and ReferenceGrant, plus one multi-SAN Certificate per ingress |
| `pg-cluster` | the CNPG `Cluster`, `PodMonitor`, a default-deny CNP pair, and when backups are on the Barman `ObjectStore` + `ScheduledBackup` |
| `redis-instance` | one standalone `Redis` CR, its ServiceMonitor, and a default-deny CNP |
| `rabbitmq-topology` | a `User` with operator-generated credentials, its exchanges/queues/bindings, a `.dlx`/`.dlq` pair per consumer queue, and one aggregated `Permission` |

Cluster wiring is hardcoded in each as a platform invariant, not a per-consumer value: `ingress`'s gateway
namespace, gateway class and fallback issuer; `rabbitmq-topology`'s broker and vhost.

## Argo CD apps

```
argo_apps/
  root.yaml                 # root-of-roots, applied once by 05_argocd.sh
  roots/                    #   platform (wave 0) and workloads (wave 1)
  platform/{apps,charts}/   # CNI, operators, CRDs, storage, gateway, SSO, monitoring, platform-ingress
  workloads/{apps,charts}/  # the actual apps
```

Each `apps/` dir is itself a Helm chart: the Applications live in `templates/`, and `repoURL` comes from that
chart's `values.yaml` so it exists once per tree instead of once per app. `ls argo_apps/platform/apps/templates/`
reads in deploy order.

- **Waves order creation, not health.** There is no `argoproj.io/Application` health gate, on purpose, so the
  platform-to-workloads boundary is advisory ordering. An app that races ahead of a dependency fails its sync
  and converges via unbounded retry.
- **Keep three things in agreement** for a platform app: the `apps/templates/NN_name.yaml` prefix, the
  `charts/NN_name/` prefix, and the `argocd.argoproj.io/sync-wave: "N"` annotation. Pick the lowest wave that
  sits after everything the app depends on. Do not renumber casually.
- **Workloads carry no wave.** They have nothing to order among themselves. If a workload genuinely depends on
  another, it belongs in platform.
- **Every app stays `automated` with unbounded retry** (`retry.limit: -1`, `refresh: true`). With no health
  gate, that is the only thing that converges an app on its own.
- **Every Application carries the `resources-finalizer`,** so removing or renaming one cascade-deletes its
  resources instead of orphaning them. `prune` is within-app and does not cascade on deletion.
- **Every pod-running app carries an explicit `CiliumNetworkPolicy`,** default-deny both ways, rolled out
  audit-first, unless it is on the deliberately-unpoliced list in `docs/04_networking.md`. Two gotchas: a
  cross-namespace peer needs `matchExpressions: [{key: k8s:io.kubernetes.pod.namespace, operator: Exists}]`,
  because an omitted namespace label is same-namespace-only; and disable any upstream-bundled vanilla
  `NetworkPolicy`, since those default to allow-all-egress and Cilium unions them with ours.
- **Alerting is Grafana-only.** `vmalert` and `alertmanager` are off, so any `PrometheusRule` or `VMRule` is
  inert. Never enable a chart's bundled alerts; add a Grafana alert file under
  `argo_apps/platform/charts/05_grafana/files/alerts/` instead. Invariant: `kubectl get vmrule -A` stays empty.
- **Roll-forward only.** Recovery is a git revert re-synced by Argo, never `argocd app rollback`, so every
  Application and first-party chart sets `revisionHistoryLimit: 0`.
- **Push before you expect a sync.** Argo CD reconciles the pushed remote, not your working tree.

Cilium is the one app that can cut the cluster off its own network, and it still auto-syncs with full `selfHeal`
and `prune`. An out-of-band break-glass fix IS reverted unless you commit it, and a bad Cilium change pushed to
git applies unattended. Mind your pushes.

## Docs

`docs/NN_*.md` is where the why lives. Fragments, bullets and tables over paragraphs. State the current reason,
not the history: this repo rolls forward, so "what it used to be" is dead weight that also goes stale.

Comments are the exception, not the habit: write one when the reason is not derivable from the code, keep it
short, and attach it to the exact line. `values.yaml`, `.env.example` and `variables.tf` are the API, so every
tunable knob gets one aligned trailing comment.
