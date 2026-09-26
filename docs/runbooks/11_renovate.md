# Renovate runbook

One-time setup for Renovate. The reasons are in [11_renovate.md](../11_renovate.md).

## Set up the token

1. Create a personal access token (PAT). Fine-grained: this repo, read-write on Contents, Pull requests, Workflows
   and Issues. Classic: the `repo` and `workflow` scopes.
2. Add it as the repo secret `RENOVATE_TOKEN`.
3. Start the Renovate workflow by hand. Renovate creates the dependency-dashboard issue and opens the first PRs.

Renovate needs its own token. A PR opened with the built-in `GITHUB_TOKEN` starts no other workflow, so CI would
never run on it.

## Protect main

GitHub knows a check name only after the check has run once. Open a PR first, then run:

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

- `required_pull_request_reviews: null`, because a required review blocks every Renovate merge.
- `strict: false`, so auto-merge does not wait for a rebase onto `main`.
- `enforce_admins: false`, so an admin can still merge an urgent fix.
