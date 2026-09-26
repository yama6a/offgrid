# Monitoring runbook

Decisions are in [../06_monitoring.md](../06_monitoring.md).

## Check Grafana

1. Check the pod:

   ```bash
   kubectl -n monitoring get deploy,pod -l app.kubernetes.io/name=grafana   # Running, no PVC
   ```

2. Open `https://grafana.ops.example.com`. Expect Google SSO, then the UI as anonymous Admin.
3. Open Connections, then Data sources. Expect VictoriaMetrics and VictoriaLogs.

## Set up phone alerts

1. Set `NTFY_PHONE_PASSWORD_SECRET` in `.env`.
2. Wait until the ntfy pod runs, then seed the users and seal Grafana's write token:

   ```bash
   make configure-ntfy-auth
   ```

   The script creates `phone` (read-only) and `grafana` (write-only) on the `cluster-alerts` topic.
3. Commit and push the sealed token.
4. In the ntfy Android app, add `https://ntfy.ops.example.com`, log in as `phone` and subscribe to
   `cluster-alerts`.

To turn phone alerts off, empty `NTFY_PHONE_PASSWORD_SECRET` and run the script again. It offers to delete the
sealed token.

## Find the policy that denied a connection

1. Query VictoriaLogs for the source namespace:

   ```
   source:hubble | flow.source.namespace:<ns>
   ```

   `_msg` holds the drop reason. The flow fields name the destination pod, port and identity.
2. While `policyAuditMode` is on, look for verdict `AUDIT`, not `DROPPED`.
3. If a rollout floods the log, fix the policy. Do not widen the Hubble filter.

## After a VictoriaMetrics chart bump

1. Bump `victoria-metrics-operator-crds` and `victoria-metrics-operator` together. They must ship the same operator
   version.
2. Confirm no rule CRs exist:

   ```bash
   kubectl get vmrule -A   # No resources found
   ```

   The chart key is `defaultRules.enabled: false`. The chart ignores `defaultRules.create` without a warning.
3. If the bump renamed metrics, check the alert queries. A rule with a broken query stays silent on its last state.

## Opt a component into critical paging

Put `alert-criticality: critical` where the outage alert looks for it:

| Component | Where |
|---|---|
| Deployment, StatefulSet, DaemonSet | the workload `metadata.labels` and the pod template labels |
| CNPG Postgres | `alertCritical: true` on the database, per consumer alias |
| Redis | `alertCritical: true` on the instance |

## Add a dashboard

1. Write it as one JSON file in `argo_apps/platform/charts/05_grafana/files/dashboards/`.
2. Check in vmui that every metric it queries exists.
3. Add `or vector(0)` to a ratio's numerator. A rate over no series returns nothing, so the panel goes blank when
   healthy. For per-series ratios, use `or 0 * <denominator>`.
4. If a third-party dashboard is empty but its metrics exist, look for `exported_*` labels. vmagent's
   `externalLabels.cluster` renames an exporter's own `cluster` label. The fix is `honorLabels: true` on the
   scrape, as `lib/helm/pg-cluster` sets it.

Volume panels read kubelet stats, so they show only PVCs that a running pod mounts.

## Re-fork the cnpg dashboard

After a CNPG chart bump, copy the upstream dashboard into `05_grafana/files/dashboards/cnpg.json` again. Keep the
uid `cloudnative-pg`. Then redo these changes:

1. CPU, 4 targets: read raw `container_cpu_usage_seconds_total` instead of the
   `node_namespace_pod_container:...:sum_irate` recording rule. Nothing evaluates recording rules here.
2. Operator readiness, 3 targets: match `pod=~".*cloudnative-pg.*"`. The release is `cnpg-operator`, so the
   upstream `cloudnative-pg.+` matches nothing.
3. Backups, 4 targets: read `cnpg_backup_last_success_seconds` and `cnpg_backup_first_recoverability_seconds`
   from orphan-exporter. The Barman Cloud plugin leaves the upstream `cnpg_collector_*` backup metrics at 0.
4. Delete the `Volume Space Usage: Tablespaces` panel. `pg-cluster` declares no tablespaces.

## Drop a metric

1. Search every namespace for a consumer first. Dashboards and alert ConfigMaps load from all namespaces, and
   cilium and cnpg ship their own.
2. Put a drop that many jobs share in `globalScrapeMetricRelabelConfigs`. Put a single-job drop in that target's
   `metricRelabelConfigs`.
3. Add the reason as a comment next to the rule.

A new scrape must not run faster than 60s. `dedup.minScrapeInterval` discards the extra samples.

## Delete a metrics or logs store

Do it in two commits, and never leave a store unprotected.

1. Remove the protection and push:
   - VictoriaLogs: set `deletionProtection: false` in `05_victoria_logs/values.yaml`.
   - VMSingle and VMAgent: delete the `annotations:` block under each in
     `05_victoria_metrics_k8s_stack/values.yaml`.
2. Let Argo CD sync.
3. Remove the store in a second commit.

## Change the kube-apiserver audit policy

The policy lives in the machine config, outside this repo. A policy the apiserver rejects stops the apiserver.

1. Validate the policy locally. `policy.yaml` holds only the `auditPolicy` body:

   ```bash
   openssl genrsa -out /tmp/sa.key 2048
   docker run --rm -v /tmp:/x registry.k8s.io/kube-apiserver:v1.36.3 kube-apiserver \
     --audit-policy-file=/x/policy.yaml --etcd-servers=http://127.0.0.1:2379 \
     --service-account-issuer=x --service-account-key-file=/x/sa.key --service-account-signing-key-file=/x/sa.key
   ```

   Expect `error creating storage factory: context deadline exceeded`. That means the policy parsed. An error that
   names `loading audit policy file` means the policy is broken. Do not apply it.
2. Push the machine config to one control-plane node with your node tooling.
3. Check the apiserver:

   ```bash
   kubectl get --raw /healthz   # ok
   ```

4. Push to the remaining control-plane nodes.

If `source:kube-audit` stays empty, check `talosctl dmesg` for an SELinux AVC denial before you suspect the
collector. Talos labels the audit directory `kube_log_t`, which no other collected file uses.

## Check metrics-server

```bash
kubectl get apiservice v1beta1.metrics.k8s.io   # AVAILABLE: True
kubectl top nodes
kubectl top pods -A
```

If `kubectl top` shows a TLS error, move to verified kubelet TLS. Do not debug `--kubelet-insecure-tls`.

## Move to verified kubelet TLS

1. Add `rotate-server-certificates: true` to the machine config and apply it to every node.
2. Add a CSR approver as a platform app. Kubernetes never approves `kubernetes.io/kubelet-serving` CSRs on its own.
   `postfinance/kubelet-csr-approver` ships a Helm chart, so it fits the wrapper-chart convention.
3. Set `KUBELET_TLS_INSECURE=false` in `.env` and run `make configure-values`. That removes
   `--kubelet-insecure-tls` from the metrics-server args.
4. Check metrics-server as above.

## Run KRR

```bash
make krr                        # table
make krr-json
make krr-yaml
bash lib/shell/krr.sh -n <ns>   # the script passes every argument to KRR
```

Expect one row per workload with the current and recommended CPU and memory request, and no "metric not found"
or connection errors. Edit the chart `values.yaml` by hand to apply a number.
