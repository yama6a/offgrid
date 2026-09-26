# GitOps runbook

Decisions are in [02_gitops.md](../02_gitops.md).

## Bootstrap Argo CD

Run `01_cilium.sh` first. Argo CD needs the pod network.

1. On the first run only, generate the argo-cd lock:

   ```bash
   helm dependency update argo_apps/platform/charts/01_argocd
   ```

2. Commit and push everything under `argo_apps/` and `lib/helm/`. Argo CD clones the remote, and the script
   refuses a dirty tree or unpushed commits.
3. For a private repo, set a fine-grained PAT in `.env`. Give it access to this repo only, with
   `Contents: Read-only`:

   ```bash
   ARGOCD_GITHUB_PAT_SECRET="github_pat_..."
   ```

4. Run the script:

   ```bash
   make install-argocd
   ```

   Expected: every check prints `[PASS]`, and the root creates the `platform` app. Apps that use sealed secrets
   stay Degraded until the master key is restored.
5. Open the UI with no login:

   ```bash
   kubectl -n argocd port-forward svc/argocd-server 8080:80   # then http://localhost:8080
   ```

6. Optional: once Argo CD has adopted its app, delete the leftover `sh.helm.release.v1.argocd.*` Secret in
   `argocd`.

To rotate the PAT, set the new token in `.env` and run the script again.

## Set up the GitHub webhook

Do this once, after the cluster serves `argocd.<domain>` on its production cert.

1. Seal the secret and set the poll cadence:

   ```bash
   make configure-argocd-webhook
   git add -A && git commit -m "Add the Argo CD GitHub webhook secret" && git push
   ```

2. In GitHub, open the repo, then Settings, Webhooks, Add webhook:

   | Field | Value |
   |---|---|
   | Payload URL | `https://argocd.<domain>/api/webhook` |
   | Content type | `application/json` |
   | Secret | the contents of `secrets/argocd-github-webhook-secret.txt` |
   | SSL verification | enabled |
   | Events | just the push event |

3. Push a trivial commit. Expected: the apps refresh within seconds.

   ```bash
   kubectl -n argocd get applications -w
   ```

To rotate the secret, delete `secrets/argocd-github-webhook-secret.txt`, run step 1 again and paste the new value
into GitHub.

## Break-glass

- **Argo CD broke itself with a bad value.** Run `make install-argocd` again. It forces the release back to the
  chart. Then fix the value in git.
- **You are locked out of the UI.** Use the port-forward above. It bypasses the Gateway and SSO.
- **There is no login prompt.** That is expected. To restore password login, set `admin.enabled: "true"` in the
  argocd values and push.

## Troubleshooting

- **An app shows `ComparisonError` or "app path does not exist".** The files are not on the remote. Commit and
  push `argo_apps/`, including any `Chart.lock`.
- **An app is `OutOfSync` with a `helm dependency build` error.** Its `Chart.lock` is missing or stale. Run
  `make fix-chart-locks`, commit and push.
- **The `cilium` app stays `OutOfSync`.** A short OutOfSync heals itself. A lasting one means Argo CD cannot sync
  at all. Look for a `Chart.lock`, CRD or path problem.
- **`server` or `repo-server` pods stay Pending.** Their topology spread needs 2 schedulable nodes with room.
  Check `kubectl -n argocd get pods -o wide` and node pressure.
- **A deleted app stays `Terminating`.** The application-controller is gone, so nothing processes the finalizer.
  Clear it by hand:

  ```bash
  kubectl -n argocd patch app <name> --type=merge -p '{"metadata":{"finalizers":[]}}'
  ```
