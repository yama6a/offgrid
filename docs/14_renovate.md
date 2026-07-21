# 14 — Renovate (automatic dependency updates)

Renovate opens PRs to bump every pinned dependency in the repo. Config: [`/renovate.json5`](../renovate.json5).
Runner: [`.github/workflows/renovate.yaml`](../.github/workflows/renovate.yaml) — dedicated to running Renovate.
Separately, [`.github/workflows/ci.yaml`](../.github/workflows/ci.yaml) validates every PR (shellcheck +
`helm dependency build`/lint/template + kubeconform + renovate-config-validator + yamllint/actionlint) and now
**gates this automerge** — see "How the automerge works" below.

## Why Renovate, not Dependabot

Dependabot has no Helm manager and can't touch image tags inside `values.yaml` or the version vars in `versions.env`.
It would cover only Terraform and (once they exist) GitHub Actions. Renovate covers everything this repo pins:

- **Helm chart deps** — every wrapper chart's `Chart.yaml`, its `Chart.lock`, and the committed vendored
  `charts/*.tgz` (helmv3 + `helmUpdateSubChartArchives`). `file://` deps have no datasource, so Renovate skips
  them.
- **Terraform** — the aws provider in `terraform/versions.tf` + `.terraform.lock.hcl`.
- **GitHub Actions** — the workflow's own action pins (kept digest-pinned).
- **Everything else, via comment-annotated regex** (`# renovate: datasource=…`): single-string `image:` values,
  chart-template images, shell-script image literals, and the Talos/kernel build recipe in `versions.env`.

We keep the pin as the single source of truth (see [CLAUDE.md]) and do NOT restate versions in prose/comments,
so a bump never strands a stale number. Version literals survive in docs only where the specific version is
load-bearing (a bug fixed in X, a minimum version, a deprecation, a must-match constraint).

## Running it

Self-hosted GitHub Action on a weekly cron + `workflow_dispatch`. **One-time setup:** create a PAT (fine-grained:
this repo, Contents + Pull requests + Workflows + Issues read-write; or classic `repo` + `workflow`) and add it as the [repo
secret](https://github.com/yama6a/offgrid/settings/secrets/actions/new) `RENOVATE_TOKEN`. The built-in
`GITHUB_TOKEN` can't open PRs that re-trigger workflows and lacks scope, so the dedicated PAT is required. Issues
read-write is what lets Renovate create + maintain the dependency-dashboard issue. First run:
trigger the workflow manually — it populates the dependency-dashboard issue and opens the initial PRs.

## PR grouping and merge posture

- **One combined, auto-merged PR for every non-major update** — all `minor` / `patch` / `digest` / `pin` /
  lockfile bumps land in a single "all non-major dependencies" PR that Renovate **merges itself**.
- **Each major update is its own PR**, left for manual review — a breaking bump is never bundled or automerged.
  The one exception: the **VictoriaMetrics** charts keep their majors together (the CRDs must match the operator).

### How the automerge works (CI-gated, Renovate-driven merge)

We keep `platformAutomerge: false` and let **Renovate merge the PR through the API itself** (not GitHub's
native auto-merge). Renovate merges only when a PR is mergeable — which now means **after the required CI
checks ([`ci.yaml`](../.github/workflows/ci.yaml)) pass**: Renovate waits on a PR's status checks by default,
and `main`'s branch protection enforces them on the API merge too. So the combined PR merges on a **subsequent
run once CI is green** (~2h+ after creation), one merge per run. That two-pass timing is why the workflow cron
runs **every 3 hours** rather than weekly — a weekly cron would leave a green, auto-mergeable PR sitting for a
week. A manual `workflow_dispatch` also completes a pending merge on demand.

Branch protection on `main` requires the CI **checks, not reviews** — a required review would deadlock Renovate
(it can't approve its own PR) — and leaves `enforce_admins` off so a break-glass fix can still land. One-time
setup, run once the CI checks have run at least once — open a PR first so GitHub registers the check contexts:

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

### The risk (and how to dial it back)

CI now blocks a bump that fails to render or produces invalid manifests — but a bump that renders cleanly yet
misbehaves at runtime (a Cilium regression, a bad default) is NOT caught by static checks. Merging still
reaches the live cluster: ArgoCD syncs it, and most apps run `selfHeal`. Auto-merging the combined PR
therefore applies everything in it **unattended**, including:

- **Cilium** — the one app that can cut the cluster (and Argo) off its own network. See [04_networking.md] /
  [05_gitops.md].
- **`local-path-provisioner`** (labeled `needs-revendor`) — its manifests are vendored verbatim; a tag bump
  really needs a manual re-diff against the upstream release. If it appears in the PR, split it out and
  re-vendor rather than letting it merge.
- **The Talos/kernel build recipe** (`versions.env`) — merging these lines does NOT self-apply; a real bump
  needs a manual image rebuild ([03a]). Treat them as a "newer version exists" signal. `KUBERNETES_VERSION` is
  coupled to Talos (its ceiling is the Talos release's k8s default), so move it WITH Talos.

This is an accepted hands-off trade-off. To de-risk without splitting the PR: add `minimumReleaseAge` (e.g.
`"3 days"`) so bumps bake before they're eligible, or remove `automerge` from specific deps you want to gate.

Two things ride in the combined PR that need care before merging:

- **The Talos/kernel build recipe** (`versions.env`) — a bump here does NOT self-apply: it needs a manual image
  rebuild with source rebases ([03a]). Treat those lines as a "newer version exists" signal. `KUBERNETES_VERSION`
  is coupled to Talos (its ceiling is the Talos release's k8s default), so move it WITH Talos.
- **`local-path-provisioner`** — its manifests are vendored verbatim (a tag bump must be re-diffed against the
  upstream release); flagged `needs-revendor`. If it changed, split it out and re-vendor before merging.

## Gotchas baked into the config

- **No `**/charts/**` disable rule.** The wrapper charts themselves live under paths containing `/charts/`, so the
  usual Helm guard would disable the whole repo.
- **`helm-values` owns all `values.yaml` images; the docker regex manager does NOT scan `values.yaml`** — it
  covers only chart templates, shell scripts, and `versions.env`. They must not overlap: a built-in manager's
  `managerFilePatterns` is additive (can't narrow it), so the split is enforced by keeping `values.yaml` out of
  the regex manager, not by scoping `helm-values`.
- **The barman-cloud vendored manifest is in `ignorePaths`** — bumping it re-vendors an upstream release verbatim
  (per that chart's README), not a line edit.
- **VictoriaMetrics charts are grouped**; the CRD chart's app version must match its operator, a human check on
  the grouped PR. See [09_monitoring.md].
- **The kernel isn't a Renovate dependency — it's derived from Talos.** raspberrypi/linux has no per-version tags,
  and its `stable_YYYYMMDD` tags jump kernel lines (mid-2026 `stable_20260715` was 6.12.95), so there's nothing safe
  to track. Instead `03a` reads the kernel version Talos expects (`DefaultKernelVersion`) at build time and resolves
  the exact `raspberrypi/linux` commit via `raspberrypi/firmware`'s `extra/git_hash`. So bumping `TALOS_VERSION`
  carries the kernel with it — no separate pin or manager. See [03_operating_system.md].
