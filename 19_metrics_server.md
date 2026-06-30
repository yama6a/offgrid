# metrics-server — the in-tree resource-metrics API

The cluster had **no `metrics.k8s.io`**: `kubectl top node/pod` failed and CPU/memory
HorizontalPodAutoscalers had nothing to read. The [monitoring stack](15_monitoring.md) (VictoriaMetrics)
collects rich custom/observability metrics, but it does **not** serve the in-tree resource-metrics API —
that is a separate, narrow contract that core Kubernetes (HPA, `kubectl top`, the scheduler's metrics)
expects from an aggregated APIService. [metrics-server](https://github.com/kubernetes-sigs/metrics-server)
fills exactly that gap: it scrapes each kubelet's Summary API over HTTPS (`:10250`) and registers the
`v1beta1.metrics.k8s.io` APIService.

It's a plain wave-2 ArgoCD app — a thin wrapper chart pinning the upstream
`kubernetes-sigs/metrics-server` chart, like every other leaf.

## The kubelet-TLS decision

metrics-server connects to each kubelet over HTTPS and, by default, verifies the kubelet's **serving
certificate**. On Talos that cert is **self-signed** out of the box, so verification fails and the scrape
errors. There are three knobs in play; only one is a real *choice*:

| Flag | Role | Verdict |
|------|------|---------|
| `--kubelet-preferred-address-types=InternalIP` | *Which* node address to dial — not a TLS toggle. | **Kept (chart default)** — the chart already sends `InternalIP,ExternalIP,Hostname`, InternalIP first. Correct for Talos: the kubelet serving-cert SANs are the node IPs, and Talos hostnames aren't in DNS. |
| `--kubelet-insecure-tls` | Skip serving-cert verification. Connection stays TLS-encrypted; only the cert *identity* is unverified. | **Chosen.** |
| `--kubelet-certificate-authority` | Verify the cert against a CA. | **Rejected (for now)** — only works if the kubelet cert is CA-signed, which Talos does *not* do by default. |

**Why `--kubelet-insecure-tls` and not the "secure" path.** Making `--kubelet-certificate-authority` work
on Talos is not a one-flag change — it needs **two** extra moving parts:

1. `rotate-server-certificates: true` in [`03d`](03_operating_system.md)'s `cp-patch.yaml`
   (`machine.kubelet.extraArgs`) — a change to the **OS step** that must be re-applied to all three nodes;
   and
2. a **CSR-approver** component, because Kubernetes never auto-approves `kubernetes.io/kubelet-serving`
   CSRs. The one Talos documents (`alex1989hu/kubelet-serving-cert-approver`) ships **raw kustomize YAML,
   no Helm chart** — so it would break the repo's wrapper-chart convention; the Helm-native alternative
   (`postfinance/kubelet-csr-approver`) needs SAN/IP-regex config.

Against that cost, the security gain is marginal here: the scrape is a **pod→kubelet hop on the cluster's
own trusted, NIC-hardened L2** (see [`03e`](03_operating_system.md)), and the connection is still
encrypted — only the cert identity goes unchecked. So we take the one-flag, one-app, zero-OS-change route.

> **The secure path stays open as a clean upgrade.** If kubelet-cert verification is ever wanted, add
> `rotate-server-certificates: true` to `03d`, add a CSR-approver platform app, and swap
> `--kubelet-insecure-tls` for `--kubelet-certificate-authority=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt`.

## The wrapper chart

Standard dependency-pin pattern (`argo_apps/platform/charts/02_metrics_server/`): `Chart.yaml` pins the
upstream chart (`3.13.1` → metrics-server `v0.8.1`), `values.yaml` is all config, `Chart.lock` is
committed. Config worth calling out:

- **`args: [--kubelet-insecure-tls]`** — the chart *appends* `args` to its `defaultArgs`, so we keep the
  three sensible defaults (`--kubelet-preferred-address-types=…`, `--kubelet-use-node-status-port`,
  `--metric-resolution=15s`, plus `--cert-dir=/tmp`) and only add the one flag.
- **`metrics.enabled` + `serviceMonitor.enabled`** — emit a ServiceMonitor for metrics-server's own
  `/metrics`. The [VM operator's](15_monitoring.md) prometheus converter turns it into a `VMServiceScrape`
  and vmagent (`selectAllByDefault`) scrapes it — same wiring as [cnpg](17_cnpg.md) / [longhorn](09_longhorn.md)
  / [sealed-secrets](07_sealed_secrets.md). The ServiceMonitor CRD exists from wave 0
  (`00_prometheus_operator_crds`).
- **Single replica**, modest requests (50m / 100Mi) — plenty for `kubectl top` + HPA on three nodes.

No imperative bootstrap script: only [Cilium](04_networking.md) and [ArgoCD](05_gitops.md) bootstrap
imperatively (the chicken-and-egg pair); everything else, this included, is ArgoCD-only.

## Where it sits — wave 2, with the other leaves

Platform, **sync-wave 2**, alongside [cert-manager](08_cert_manager.md) / [longhorn](09_longhorn.md) /
[cnpg-operator](17_cnpg.md) / [sealed-secrets](07_sealed_secrets.md) — independent leaves that only need
the CNI (wave 0). Per [CLAUDE.md](CLAUDE.md) the `NN` prefix *is* the wave, so it carries `02_`. It runs
in `kube-system` (the conventional home; `CreateNamespace=true` is a no-op there), runs **non-root** so no
privileged PSA is needed, and is `automated {prune: true, selfHeal: true}` — a safe leaf that owns only
its own APIService + RBAC + Deployment (a prune cascade-deletes nothing shared).

## Verifying it

```bash
# the chart renders, with the insecure flag appended to the defaults:
helm template metrics-server argo_apps/platform/charts/02_metrics_server -n kube-system \
  | grep -E 'kubelet-insecure-tls|kubelet-preferred-address-types|v1beta1.metrics.k8s.io'

# after commit + push — ArgoCD reconciles it (reads git, not local disk):
export KUBECONFIG=03_operating_system/talos-cluster/kubeconfig
kubectl -n argocd get app metrics-server                  # Synced + Healthy
kubectl get apiservice v1beta1.metrics.k8s.io             # AVAILABLE: True
kubectl top nodes                                         # CPU/memory per node  <- the real end-to-end check
kubectl top pods -A                                       # CPU/memory per pod
kubectl -n kube-system get vmservicescrape | grep metrics-server   # VM operator picked up the ServiceMonitor
```

## Caveats

- **Push before you expect a sync.** ArgoCD reads git, not local disk — commit *and push* `argo_apps/**`
  and this doc, or the root app reports `ComparisonError`.
- **If `kubectl top` ever returns a TLS error despite `--kubelet-insecure-tls`**, that's the signal to
  move to the secure path (the upgrade note above), not to debug the flag.
