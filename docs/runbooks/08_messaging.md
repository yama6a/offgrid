# Runbook: messaging

Decisions and architecture are in [08_messaging.md](../08_messaging.md).

## Deploy

1. Build the chart dependencies and commit the new lock. Argo CD fails to sync on a missing or stale lock. The
   workload charts use only `file://` dependencies and need nothing.

   ```bash
   helm dependency build argo_apps/platform/charts/03_rabbitmq
   ```

2. Commit and push. Argo CD reconciles the pushed remote, not your working tree.

## Check

1. Load the pinned kubeconfig.

   ```bash
   export KUBECONFIG=.cache/kubeconfig
   ```

2. Check the broker.

   ```bash
   kubectl -n rabbitmq get pods                        # 2 operator pods, rabbitmq-server-0..2 on 3 nodes
   kubectl -n rabbitmq get rabbitmqcluster,vhost       # AllReplicasReady=True, vhost apps Ready
   ```

3. Check a workload's topology. Repeat for `sample-user-signup` and `sample-audit-logger`.

   ```bash
   kubectl -n sample-user-manager get \
     user.rabbitmq.com,exchange.rabbitmq.com,queue.rabbitmq.com,binding.rabbitmq.com,permission.rabbitmq.com
   ```

   Expected: every object `Ready=True`. On a cold start the pod can show `CreateContainerConfigError` until the
   operator writes `<user>-user-credentials`. It clears by itself.

4. Watch the message loop.

   ```bash
   kubectl -n sample-user-signup logs deploy/sample-user-signup     # sends a command every 10s, gets users.created
   kubectl -n sample-user-manager logs deploy/sample-user-manager   # stores users, emits events
   kubectl -n sample-audit-logger logs deploy/sample-audit-logger   # audit messages only
   ```

5. Check isolation. Each user has only its own `read` and `write` regexes, and `configure` is empty.

   ```bash
   kubectl -n rabbitmq exec rabbitmq-server-0 -c rabbitmq -- rabbitmqctl list_permissions -p apps
   ```

6. Open `https://rabbitmq.ops.example.com/`. Sign in with Google, then with the RabbitMQ admin credentials:

   ```bash
   kubectl -n rabbitmq get secret rabbitmq-default-user -o jsonpath='{.data}'   # base64-decode both values
   ```

## Change a queue's type, durability or arguments

The operator does not change a live queue.

1. Delete the queue in the management UI, or delete and sync its `Queue` CR again.
2. The operator declares it again with the new settings. Any messages in the old queue are lost.

## Rotate a workload's credentials

Editing `<user>-user-credentials` does nothing, because the operator does not watch it.

1. Add or change an annotation on the workload's `User` CR, or delete the CR and let Argo CD create it again.

## A User stays Ready: False after you create or restore a Secret

The topology operator sees only Secrets labelled `rabbitmq.com/topology-operator: "true"`. Without the label, it
retries a create forever against `already exists`. Argo CD shows the app Degraded but names no unhealthy child.

1. Label the Secret.

   ```bash
   kubectl -n <ns> label secret <name> rabbitmq.com/topology-operator=true
   ```

## A Permission hangs in Terminating

The operator needs the user's credentials to remove a permission. If the `User` and its Secret were deleted first,
the finalizer cannot complete. Delete `Permission` before `User` to avoid it.

1. Clear the finalizer.

   ```bash
   kubectl -n <ns> patch permission <name> -p '{"metadata":{"finalizers":[]}}' --type=merge
   ```
