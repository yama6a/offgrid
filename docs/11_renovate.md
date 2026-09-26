# Renovate (automatic dependency updates)

Renovate opens PRs that bump every pinned dependency in the repo. Setup is in the
[Renovate runbook](runbooks/11_renovate.md).

- Config: [`/renovate.json5`](../renovate.json5). Its comments explain each manager and rule. It extends the
  shared preset `github>yama6a/gha:default.json5`, which holds the grouping, automerge and digest-pinning rules.
- Runner: [`.github/workflows/renovate.yaml`](../.github/workflows/renovate.yaml), daily at 05:13 UTC.
- Gate: [`.github/workflows/ci.yaml`](../.github/workflows/ci.yaml). No PR merges until its checks pass.

## Why Renovate, not Dependabot

Dependabot has no Helm manager and cannot update image tags inside `values.yaml`. Renovate covers every pin here:
chart dependencies, images in values, templates and shell scripts, the Terraform provider, the action pins, and
the annotated `postgresVersion` and `redisVersion` values.

The pin is the single source of truth. Prose and comments never restate a version, so a bump cannot leave a stale
number behind. A doc keeps a version only when that exact version is the point: a minimum, a maximum, or a
version that must match another.

## What merges without review

- **Non-major updates:** one combined PR, with auto-merge on.
- **Major updates:** one PR each, labelled `dep-major`. The VictoriaMetrics charts share one PR, because the CRDs
  must match the operator.
- **Replacements:** one PR each, labelled `dep-swap`.

After each run, a Copilot backward-compatibility check reviews every open `dep-major` and `dep-swap` PR. A `SAFE`
verdict turns on auto-merge. Any other verdict leaves the PR for a human.

Auto-merge is GitHub's own (`platformAutomerge`). GitHub merges as soon as the required checks pass, so one
Renovate run a day is enough. Branch protection requires the CI checks and no reviews, because Renovate cannot
approve its own PR.

## The risk

CI blocks a bump that fails to render. It does not catch a bump that renders but breaks at runtime, such as a
Cilium regression or a changed default. A merged bump reaches the live cluster with no human step, because Argo CD
syncs it. Cilium carries the most risk, because it can cut the cluster, and Argo CD with it, off its own network.

The repo accepts that risk to stay hands-off. To reduce it without splitting the combined PR, add
`minimumReleaseAge`, or turn `automerge` off for the dependencies you want to review.

A merged `postgresVersion` major runs an offline `pg_upgrade`, and the database is down while it runs. Read the
upgrade steps in [05_storage.md](05_storage.md) before you merge one. The backup catalog moves to a new prefix by
itself.
