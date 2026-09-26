# Runbook: sample-user-manager

Decisions and architecture are in [07_sample_workload.md](../07_sample_workload.md).

## Deploy

1. Point the public DNS of both hosts at the home router. Forward `:80` to the Gateway IP, so HTTP-01 can issue.
2. Commit and push. Argo CD applies the workload through the workloads tree.

   ```bash
   git add -A && git commit && git push
   ```

## Check

1. Load the pinned kubeconfig.

   ```bash
   export KUBECONFIG=.cache/kubeconfig
   ```

2. Check the resources.

   ```bash
   kubectl -n sample-user-manager get cluster,redis,pods     # 2 clusters, 2 redis, the app pod Running
   kubectl -n sample-user-manager get ciliumnetworkpolicy    # app, one per store, and the client-egress pairs
   kubectl -n gateway get certificate                        # READY=True once DNS and the :80 forward exist
   ```

   On a cold start the app pod can show `CreateContainerConfigError` for a short time. It clears once the CNPG
   operator writes the `sample-user-manager-db-app` Secret.

3. Open `https://sample-user-manager.app.example.com/`. The app answers with no login.
4. Open `https://sample-user-manager-sso.app.example.com/`. It redirects to Google. An allowlisted account reaches
   the app, and any other account is denied.
