# Renovate (automatic dependency updates)

Renovate opens PRs that bump every pinned dependency in the repo.

- Config: [`/renovate.json5`](../renovate.json5). It extends the shared preset `github>yama6a/gha:default.json5`,
  which holds the grouping, automerge and digest-pinning rules.
- Runner: [`.github/workflows/renovate.yaml`](../.github/workflows/renovate.yaml).
- Gate: [`.github/workflows/ci.yaml`](../.github/workflows/ci.yaml) checks every PR. It runs shellcheck, `helm
  dependency build`, `helm lint`, `helm template`, kubeconform, renovate-config-validator, yamllint and actionlint.
  No PR merges until these checks pass. See [How the automerge works](#how-the-automerge-works).

## Why Renovate, not Dependabot

Dependabot has no Helm manager and cannot update image tags inside `values.yaml`. It covers only Terraform and
GitHub Actions. Renovate covers every pin in this repo:

| Manager | Covers |
|---|---|
| `helmv3` | every wrapper chart's `Chart.yaml` and `Chart.lock`. A `file://` dep has no datasource, so Renovate skips it |
| `terraform` | the aws provider in `terraform/versions.tf` and `.terraform.lock.hcl` |
| `github-actions` | the workflow's own action pins, kept pinned to a digest |
| `helm-values` | a standard `image:` block, or a `repository` and `tag` pair, in a `values.yaml` |
| regex, annotated | every line with a `# renovate: datasource=...` comment: images in chart templates, image literals in shell scripts, the per-workload `postgresVersion` and `redisVersion` values, the pg-cluster image map |

`helmUpdateSubChartArchives` is on. It re-packs a committed `charts/*.tgz`. No chart commits one today, so the
option has no effect. It stays on as a guard for a chart that commits one later.

The pin is the single source of truth. Prose and comments never restate a version, so a bump cannot leave a stale
number behind. A doc keeps a version number only when that exact version is the point: a minimum, a maximum, or a
version that must match another.

## Running it

A self-hosted GitHub Action runs Renovate once a day at 05:13 UTC. You can also start it by hand with
`workflow_dispatch`, which takes a log level and a dry-run switch.

One-time setup:

1. Create a PAT (personal access token). Fine-grained: this repo, with read-write on Contents, Pull requests,
   Workflows and Issues. Classic: the `repo` and `workflow` scopes.
2. Add it as the repo secret `RENOVATE_TOKEN`.
3. Start the workflow by hand. Renovate creates the dependency-dashboard issue and opens the first PRs.

Renovate needs its own PAT. A PR opened with the built-in `GITHUB_TOKEN` does not start other workflows, so CI
would never run on it. `GITHUB_TOKEN` also lacks the scopes. Read-write on Issues lets Renovate create and update
the dashboard issue.

## PR grouping, and when a PR merges without review

- **Non-major updates:** one combined PR with auto-merge on. It holds every `minor`, `patch`, `digest`, `pin` and
  lockfile update, under the title "all non-major dependencies".
- **Major updates:** one PR each, with the `dep-major` label. Renovate never auto-merges one. The VictoriaMetrics
  charts are the exception to one-PR-each: their majors share one PR, because the CRDs must match the operator.
- **Replacements:** one PR each, with the `dep-swap` label. A replacement swaps a package for a different one.

After each run, the workflow sends every open `dep-major` and `dep-swap` PR through a backward-compatibility
check. The check uses Copilot and gives a verdict per PR head. A `SAFE` verdict turns on auto-merge for that PR.
Any other verdict leaves the PR for a human to review.

### How the automerge works

The preset sets `platformAutomerge: true`. Renovate turns on GitHub's own auto-merge when it opens the PR. GitHub
then merges the PR as soon as the required CI checks pass. One daily run is enough, because GitHub does the merge.

Branch protection on `main` requires the CI checks and no reviews. A required review would block every merge,
because Renovate cannot approve its own PR. `enforce_admins` stays off, so an admin can still merge an urgent fix.
`strict` stays off, so auto-merge does not wait for a rebase onto `main` first.

Set the protection once. GitHub knows a check name only after that check has run once, so open a PR first:

```bash
gh api -X PUT repos/yama6a/offgrid/branches/main/protection \
  -H "Accept: application/vnd.github+json" --input - <<'JSON'
{
  "required_status_checks": { "strict": false, "checks": [
    {"context": "shell"}, {"context": "helm"}, {"context": "yaml"}, {"context": "renovate-config"},
    {"context": "chart-tests"}
  ]},
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
JSON
```

### The risk, and how to reduce it

CI blocks a bump that fails to render or gives invalid manifests. CI does not catch a bump that renders but
breaks at runtime, for example a Cilium regression or a changed default. A merged bump reaches the live cluster
with no human step: Argo CD syncs it, and most apps run `selfHeal`.

Cilium needs the most care. It is the one app that can cut the cluster, and Argo CD with it, off its own network.
See [01_networking.md](01_networking.md) and [02_gitops.md](02_gitops.md).

This repo accepts that risk to stay hands-off. To reduce it without splitting the combined PR:

- Add `minimumReleaseAge`, for example `"3 days"`. A new release then waits that long before Renovate offers it.
- Turn `automerge` off for the dependencies you want to review by hand.

## Gotchas in the config

- **No `**/charts/**` disable rule.** The wrapper charts live under paths that contain `/charts/`. The usual Helm
  guard would turn Renovate off for the whole repo.
- **The three image managers must not match the same line.** `helm-values` reads only an `image:` block or a
  `repository` and `tag` pair. A built-in manager's `managerFilePatterns` only adds files, so you cannot narrow
  it. So the regex manager for templates and shell scripts excludes `values.yaml`. A second regex manager covers
  only `argo_apps/workloads/charts/*/values.yaml`, and matches only the annotated `postgresVersion` and
  `redisVersion` lines.
- **Two pins set the Postgres version.** The workload holds the major. The pg-cluster chart holds the patch and
  the digest.
  - A workload's `postgresVersion` is a bare major, for example `"18"`. A packageRule allows only major updates
    on it, so Renovate offers only an upgrade such as 18 to 19, as a PR for review.
  - The image itself lives once in `lib/helm/pg-cluster/files/postgres-images.yaml`. It holds one pinned
    `tag@digest` per supported major. Renovate updates only the digest. A patch release moves the rolling
    `<major>-minimal-trixie` tag, so the tag string itself never changes.
  - A human adds a new major to that map. Until then, a workload on that major fails to render: the chart's
    `pg-cluster.image` helper fails on a major that is not in the map. So CI blocks the major PR.
- **A merged `postgresVersion` major PR runs the upgrade.** The operator runs an offline `pg_upgrade`, and the
  database is down while it runs. Read the runbook in [05_storage.md](05_storage.md) before you merge one. No
  other step is needed: the backup catalog moves to a new prefix for the new major by itself. Renovate never
  auto-merges a major, so you always get the chance to read the runbook.
- **The vendored barman-cloud manifest is in `ignorePaths`.** A bump re-vendors a full upstream release, per
  that chart's README. It is never a one-line edit.
- **The VictoriaMetrics charts share one major PR.** The CRD chart's app version must match the operator's. A
  human checks that on the combined PR. See [06_monitoring.md](06_monitoring.md).
- **Every `Chart.lock` gets a fixed `generated:` time.** `helm dependency update` writes the current time into
  that field. A `postUpgradeTasks` command sets it to `1970-01-01T00:00:00Z`, so two independent updates to the
  same versions give the same file. The command must also be in the `allowed-commands` input in
  `.github/workflows/renovate.yaml`, or Renovate does not run it.
