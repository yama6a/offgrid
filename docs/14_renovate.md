# 14 — Renovate (automatic dependency updates)

Renovate opens PRs to bump every pinned dependency in the repo. Config: [`/renovate.json5`](../renovate.json5).
Runner: [`.github/workflows/renovate.yaml`](../.github/workflows/renovate.yaml) — the repo's ONLY CI, it exists
solely to run Renovate (nothing here builds or tests the cluster).

## Why Renovate, not Dependabot

Dependabot has no Helm manager and can't touch image tags inside `values.yaml` or the version vars in `.env`.
It would cover only Terraform and (once they exist) GitHub Actions. Renovate covers everything this repo pins:

- **Helm chart deps** — every wrapper chart's `Chart.yaml`, its `Chart.lock`, and the committed vendored
  `charts/*.tgz` (helmv3 + `helmUpdateSubChartArchives`). `file://` deps have no datasource, so Renovate skips
  them.
- **Terraform** — the aws provider in `terraform/versions.tf` + `.terraform.lock.hcl`.
- **GitHub Actions** — the workflow's own action pins (kept digest-pinned).
- **Everything else, via comment-annotated regex** (`# renovate: datasource=…`): single-string `image:` values,
  chart-template images, shell-script image literals, and the Talos/kernel build recipe in `.env.example`.

We keep the pin as the single source of truth (see [CLAUDE.md]) and do NOT restate versions in prose/comments,
so a bump never strands a stale number. Version literals survive in docs only where the specific version is
load-bearing (a bug fixed in X, a minimum version, a deprecation, a must-match constraint).

## Running it

Self-hosted GitHub Action on a weekly cron + `workflow_dispatch`. **One-time setup:** create a PAT (fine-grained:
this repo, Contents + Pull requests + Workflows read-write; or classic `repo` + `workflow`) and add it as the [repo
secret](https://github.com/yama6a/offgrid/settings/secrets/actions/new) `RENOVATE_TOKEN`. The built-in
`GITHUB_TOKEN` can't open PRs that re-trigger workflows and lacks scope, so the dedicated PAT is required. First run:
trigger the workflow manually — it populates the dependency-dashboard issue and opens the initial PRs.

## Merge posture (and its risk)

Merging a PR reaches the live cluster: ArgoCD syncs it, and most apps run `selfHeal`. So the posture is
deliberate:

- **Automerge** only `patch` / `digest` / `pin` updates. Minor and major are always PR-only.
- **PR-only (never automerged)**, even for a patch:
    - **Cluster-critical apps** — cilium, argocd, cert-manager, longhorn, envoy gateway. Cilium especially: it is
      the one app that can cut the cluster (and Argo) off its own network. See [04_networking.md] / [05_gitops.md].
    - **The Talos/kernel build recipe** (`.env.example`) — a real bump needs a full manual image rebuild with
      source rebases ([03a]); merging the PR changes only `.env.example` and applies nothing. The PRs are purely a
      "a newer version exists" signal. Grouped as one PR. `KUBERNETES_VERSION` lives here too — its ceiling is the
      Talos release's k8s default, so it must move WITH Talos.
    - **`local-path-provisioner`** — its manifests are vendored verbatim (a tag bump must be re-diffed against the
      upstream release); flagged `needs-revendor`.

## Gotchas baked into the config

- **No `**/charts/**` disable rule.** The wrapper charts themselves live under paths containing `/charts/`, so the
  usual Helm guard would disable the whole repo.
- **`helm-values` owns all `values.yaml` images; the docker regex manager does NOT scan `values.yaml`** — it
  covers only chart templates, shell scripts, and `.env.example`. They must not overlap: a built-in manager's
  `managerFilePatterns` is additive (can't narrow it), so the split is enforced by keeping `values.yaml` out of
  the regex manager, not by scoping `helm-values`.
- **The barman-cloud vendored manifest is in `ignorePaths`** — bumping it re-vendors an upstream release verbatim
  (per that chart's README), not a line edit.
- **VictoriaMetrics charts are grouped**; the CRD chart's app version must match its operator, a human check on
  the grouped PR. See [09_monitoring.md].
