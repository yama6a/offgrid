# Renovate (automatic dependency updates)

Renovate opens PRs to bump every pinned dependency in the repo.

- Config: [`/renovate.json5`](../renovate.json5)
- Runner: [`.github/workflows/renovate.yaml`](../.github/workflows/renovate.yaml)
- Gate: [`.github/workflows/ci.yaml`](../.github/workflows/ci.yaml) validates every PR (shellcheck, `helm
  dependency build`/lint/template, kubeconform, renovate-config-validator, yamllint, actionlint) and the
  automerge waits on it. See "How the automerge works".

## Why Renovate, not Dependabot

Dependabot has no Helm manager and cannot touch image tags inside `values.yaml`. It would cover Terraform and
GitHub Actions only. Renovate covers everything this repo pins:

| Manager | Covers |
|---|---|
| `helmv3` | every wrapper chart's `Chart.yaml` + `Chart.lock`. `file://` deps have no datasource, so they are skipped |
| `terraform` | the aws provider in `terraform/versions.tf` + `.terraform.lock.hcl` |
| `github-actions` | the workflow's own action pins, kept digest-pinned |
| `helm-values` | standard-shape `image:` / `repository`+`tag` in a `values.yaml` |
| regex, annotated | anything carrying `# renovate: datasource=...`: chart-template images, shell-script image literals, the per-workload `postgresVersion`/`redisVersion` scalars, the pg-cluster image map |

`helmUpdateSubChartArchives` is on but currently does nothing: no chart commits a vendored `charts/*.tgz` any
more. Kept as a guard in case one comes back.

The pin is the single source of truth. Versions are never restated in prose or comments, so a bump cannot strand
a stale number. A version literal survives in a doc only when that exact version is the point: a minimum, a
ceiling, or a must-match constraint.

## Running it

Self-hosted GitHub Action, cron every 3 hours plus `workflow_dispatch`.

One-time setup:

1. Create a PAT. Fine-grained: this repo, Contents + Pull requests + Workflows + Issues read-write. Or classic:
   `repo` + `workflow`.
2. Add it as the repo secret `RENOVATE_TOKEN`.
3. Trigger the workflow by hand. It populates the dependency-dashboard issue and opens the first PRs.

The built-in `GITHUB_TOKEN` cannot open PRs that re-trigger workflows and lacks the scope, so the dedicated PAT
is required. Issues read-write is what lets Renovate create and maintain the dashboard issue.

## PR grouping, and when Renovate self-merges

- One combined, auto-merged PR for every non-major update: `minor`, `patch`, `digest`, `pin` and lockfile bumps
  all land in a single "all non-major dependencies" PR that Renovate merges itself.
- Each major update is its own PR, left for review. A breaking bump is never bundled or automerged. The one
  exception: the VictoriaMetrics charts keep their majors together, because the CRDs must match the operator.

### How the automerge works

`platformAutomerge: false`, so Renovate merges through the API itself rather than using GitHub's native
auto-merge. It merges only when the PR is mergeable, which now means after the required CI checks pass: Renovate
waits on status checks by default, and `main`'s branch protection enforces them on the API merge too.

Consequence: the combined PR merges on a LATER run once CI is green, roughly 2h+ after it was opened, one merge
per run. That two-pass timing is why the cron runs every 3 hours. A weekly cron would leave a green,
auto-mergeable PR sitting for a week. A manual `workflow_dispatch` also completes a pending merge on demand.

Branch protection on `main` requires the CI checks, not reviews. A required review would deadlock Renovate,
since it cannot approve its own PR. `enforce_admins` stays off so a break-glass fix can still land.

Run this once, after the CI checks have run at least once (open a PR first so GitHub registers the check
contexts):

```bash
gh api -X PUT repos/yama6a/offgrid/branches/main/protection \
  -H "Accept: application/vnd.github+json" --input - <<'JSON'
{
  "required_status_checks": { "strict": true, "checks": [
    {"context": "shell"}, {"context": "helm"}, {"context": "yaml"}, {"context": "renovate-config"}
  ]},
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
JSON
```

### The risk, and how to dial it back

CI blocks a bump that fails to render or produces invalid manifests. It does NOT catch a bump that renders
cleanly but misbehaves at runtime, like a Cilium regression or a changed default. A merge reaches the live
cluster: ArgoCD syncs it and most apps run `selfHeal`, so the combined PR applies everything in it unattended.

One thing in that PR needs care: Cilium is the app that can cut the cluster, and Argo with it, off its own
network. See [01_networking.md](01_networking.md) and [02_gitops.md](02_gitops.md).

Accepted hands-off trade-off. To de-risk without splitting the PR: add `minimumReleaseAge` (e.g. `"3 days"`) so
bumps bake before they are eligible, or drop `automerge` from the specific deps you want to gate.

## Gotchas baked into the config

- No `**/charts/**` disable rule. The wrapper charts themselves live under paths containing `/charts/`, so the
  usual Helm guard would disable the whole repo.
- The three image managers must not overlap on the same key. `helm-values` only recognises `image:` or
  `repository`+`tag` structures, and a built-in manager's `managerFilePatterns` is additive, so it cannot be
  narrowed. Therefore the template/shell regex manager keeps `values.yaml` out entirely, and a separate
  datastore-version manager (scoped to `argo_apps/workloads/charts/*/values.yaml`) matches only the annotated
  `postgresVersion`/`redisVersion` line.
- Postgres version is split across two pins, MAJOR in the workload and patch/digest in the chart map. A
  workload's `postgresVersion` is a bare major (`"18"`), held MAJOR-only by a packageRule, so only an `18 to 19`
  upgrade surfaces for review. The actual image (flavour, OS, patch, digest) lives once in
  `lib/helm/pg-cluster/files/postgres-images.yaml`, one pinned `tag@digest` per supported major, tracked
  DIGEST-only because patches move the rolling `<major>-minimal-trixie` tag and the tag string never changes. A
  new major is added to the map by hand, because it is a `pg_upgrade` and not a swap. Until it is, a workload
  bumped to that major fails to render (the chart's `pg-cluster.image` helper fails on an unlisted key), which
  blocks the major PR.
- The barman-cloud vendored manifest is in `ignorePaths`. Bumping it re-vendors an upstream release verbatim per
  that chart's README, not a line edit.
- VictoriaMetrics charts are grouped. The CRD chart's app version must match its operator, which is a human
  check on the grouped PR. See [06_monitoring.md](06_monitoring.md).
