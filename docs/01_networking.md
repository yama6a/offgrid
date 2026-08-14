# Networking: Cilium

The cluster arrives with no CNI and no kube-proxy, which is a prerequisite this repo states rather than
arranges (see the README). On Talos that is `cni: none` plus `proxy.disabled: true` in the machine config;
other distributions have their own switch. Cilium fills all of it
from one install: CNI, load balancer, and node-to-node encryption. `01_cilium.sh` does it and flips the nodes to
Ready.

- The one component installed imperatively. Everything after it is GitOps.
- Nothing has a pod network until it lands, so ArgoCD, CoreDNS and every workload depend on it.
- Source of truth is the wrapper chart at `argo_apps/platform/charts/00_cilium/`. The script only installs that
  chart; ArgoCD later adopts the same release (same chart, namespace, release name, values) so Argo sees it
  in-sync rather than fighting it. No version, CRD list or value lives in the script.

| Path                       | Holds                                                                                      |
|----------------------------|--------------------------------------------------------------------------------------------|
| `Chart.yaml`               | the cilium chart, declared as a dependency on `helm.cilium.io`                              |
| `values.yaml`              | the Talos-flavoured cilium values (under the `cilium:` key) + the `loadBalancer` gate       |
| `crds/`                    | empty. Cilium does not vendor the Gateway API CRDs; Envoy Gateway owns them. See [04_ingress.md](04_ingress.md) |
| `templates/cilium-lb.yaml` | the LB-IPAM pool + L2 policy, gated by `.Values.loadBalancer.enabled`                       |

## Why Cilium: one component instead of three

Bare-metal Kubernetes ships no LoadBalancer, no ingress and no encryption. The alternative is stacking three
single-purpose tools. Cilium does all of it from one agent plus operator.

| Need              | Cilium provides                  | What it replaces, and why |
|-------------------|----------------------------------|---------------------------|
| LoadBalancer IPs  | LB-IPAM + L2 announcements (ARP) | MetalLB. On an all-Cilium cluster it only duplicates the IP-announce half (eBPF already does the data-path LB), adds a second ARP owner on the same nodes, and adds pods plus CRDs for no gain. Trade-off: Cilium L2 is Beta vs MetalLB's GA L2, fine for a homelab. |
| Ingress / gateway | Gateway API (Envoy-backed)       | ingress-nginx, which the community retires in March 2026. Gateway API is the forward path. Cilium can serve it, but ingress went to Envoy Gateway for its `SecurityPolicy` CRD (label-attached SSO), so Cilium's `gatewayAPI` is off and it vendors no Gateway API CRDs. See [04_ingress.md](04_ingress.md) |
| Pod encryption    | transparent WireGuard, one flag  | Istio or another service mesh. We wanted the wire encrypted plus a gateway, not AuthorizationPolicy or VirtualService. Sidecar Istio is also heavy on 3x 8 GB Pis, one Envoy per pod |
| A mesh, if needed | sidecarless L7 + Hubble          | covers what we would use a mesh for, without per-pod sidecars |

Decisions:

- WireGuard, not mTLS. Transparent, node-to-node, no certs or SPIFFE. Exactly "encrypt the wire". Same-node pod
  traffic is NOT encrypted, since it never leaves the host. Cilium's SPIFFE mutual-auth is a separate feature we
  do not enable. The image kernel already carries `CONFIG_WIREGUARD`.
- kube-proxy replacement is mandatory: L2 announcements require it. Hence `proxy.disabled: true` at the Talos
  layer and `kubeProxyReplacement: true` in the values.
- KubePrism (`localhost:7445`) is Cilium's API endpoint. Pure host networking, so Cilium needs no external LB to
  reach the API server.

## What `01_cilium.sh` does

Native `helm` + `kubectl`, erroring out if either is missing. Talks to the cluster via the pinned kubeconfig
derived from `KUBE_CONTEXT`. Idempotent.

1. `helm dependency build argo_apps/platform/charts/00_cilium` pulls the pinned `cilium/cilium` subchart into
   `charts/`, falling back to `helm dependency update` to generate `Chart.lock` on a first run.
2. `helm upgrade --install cilium ... --wait` installs with the chart's values: KubePrism endpoint, kube-proxy
   replacement, WireGuard, L2 announcements, Hubble, and the Talos-mandatory `cgroup` (no auto-mount) plus
   `securityContext` capability blocks.
3. Waits for nodes Ready. They were NotReady with no CNI.
4. Enables the LB-IPAM pool + L2 policy. See the two-pass note below.
5. Verifies agent and operator rollout, and the LB pool.

The two-pass install exists because the `CiliumLoadBalancerIPPool` and L2 CRDs are registered by the
cilium-operator at RUNTIME, not shipped by the chart. On a fresh cluster they do not exist when Helm would apply
the pool, so step 2 runs with `--set loadBalancer.enabled=false`, then the upgrade re-runs with the gate back on
once the operator is up. On a re-run the CRD is already there and it happens in one shot. ArgoCD just leaves
`loadBalancer.enabled=true` and relies on sync-retry.

```bash
./01_cilium.sh
```

Smoke-test the LoadBalancer end to end:

```bash
kubectl create deploy nginx --image=nginx
kubectl expose deploy nginx --type=LoadBalancer --port=80
kubectl get svc nginx              # EXTERNAL-IP from your pool, reachable over ARP
```

## Hubble observability

`hubble.enabled`, `relay` and `ui` are all true, so `hubble-relay` and `hubble-ui` run in `kube-system`. Two ways
it surfaces:

- Metrics. `hubble.metrics` exports a lean flow set (`dns, drop, tcp, flow, icmp, port-distribution`, kept small
  to bound the number of series on the Pis) with a `serviceMonitor`, so it reaches vmagent like every other
  platform scrape. Every handler spells out its context options
  (`labelsContext=source_namespace,destination_namespace` plus `sourceContext`/`destinationContext` of
  `workload-name|reserved-identity`). A bare handler name emits the counter with NO peer or namespace labels at
  all, so nothing can be split by who sent the traffic. The same `cilium_*` metrics drive the `cilium-health`
  Grafana alert group: agent-down, BPF-map pressure, unreachable nodes. See
  [06_monitoring.md](06_monitoring.md).
- Dashboard. ONE first-party `hubble` dashboard, in `05_grafana/files/dashboards/hubble.json`, and
  `hubble.metrics.dashboards.enabled: false` so the chart's own four stay out of Grafana. Theirs group every
  panel by cilium-agent pod without printing it, so each panel draws one indistinguishable line per node; ours
  aggregates across agents and makes the node a variable. Rows: overview, drops and would-be (`AUDIT`) drops,
  a per-namespace talkers view, TCP/ICMP/ports, DNS.
- What the DNS panels can see. `hubble_dns_*` only counts DNS that went through Cilium's DNS proxy, and a pod
  is only routed through it by a policy with `toFQDNs` or L7 `dns` rules. Today that is just the two backup
  CronJobs, so the DNS row is near-empty and NOT broken. Everything else's DNS shows up as plain UDP flows.
- No L7 HTTP metrics. `httpV2` is off, so there is no `hubble_http_*` and no L7 row. Turning it on is not just
  the handler: Hubble only sees HTTP for traffic an L7 `http` rule in a CiliumNetworkPolicy pulls through the
  Envoy L7 proxy, so it costs a per-workload policy change plus a proxy hop, and for the ingress path it would
  recount what the edge already counts. HTTP observability lives in the `ingress-http` dashboard off Envoy's own
  metrics instead. See [04_ingress.md](04_ingress.md).
- UI. The `hubble-ui` Service is exposed as `hubble.<domain>` by the platform-ingress app (wave 6) and gated by
  Google SSO: a plain cross-namespace edge into `kube-system`, in the same `hosts` list and `04_google_sso`
  allowlist as the other platform UIs. See [04_ingress.md](04_ingress.md).
- Dropped-flow logs. `hubble.export.dynamic` writes one JSON line per `DROPPED` flow to a file on the node, which
  the log collector ships to VictoriaLogs (`source:hubble`). The `drop` metric above only counts drops; the log
  names the pod, port and identity, which is what you need to find the missing rule in a default-deny CNP. The
  live equivalent is `hubble observe --verdict DROPPED`, but that only shows what is happening right now. See
  [06_monitoring.md](06_monitoring.md).

## Network policy

Lockdown is opt-in per component via `CiliumNetworkPolicy`. There is no cluster-wide default-deny. CNP over
vanilla `NetworkPolicy` buys the `kube-apiserver` and `world` entities, so no hardcoded IPs, plus Hubble
policy-verdict visibility (`hubble observe --verdict DROPPED`).

Two places carry policies. Workloads: the sample workload's app plus its CNPG Postgres, see
[07_sample_workload.md](07_sample_workload.md) for those and for the reusable DB policy baked into the
`pg-cluster` wrapper. Platform: a full explicit policy per chart in its own `templates/networkpolicy.yaml`, so
the file you open is the policy that gets applied, with no shared library or render abstraction. Three groups:

- Secret-holders, namespace-wide default-deny (`endpointSelector: {}`): `sealed-secrets`, `cert-manager`,
  `argocd`.
- Data stores and services, pod-scoped because their namespace also holds an unrestricted scraper: `vmsingle`,
  `vlsingle`, `grafana` (`vmagent` shares `monitoring` and scrapes the whole cluster, so it stays unrestricted),
  `ntfy`, the RabbitMQ broker, and the egress-only backup CronJobs `redis-backup` and `vm-backup`.
- Operators and the backup plugin, pod-scoped, added so no pod-running component is left implicitly
  default-allow: `cnpg-operator`, `redis-operator`, the RabbitMQ `cluster-operator` and
  `messaging-topology-operator`, and the `barman-cloud` CNPG-I plugin (the S3 backup coordinator, which holds the
  S3 client mTLS identity). Each allows only its real surface: the metrics scrape where a PodMonitor exists, the
  admission webhook where enabled, the kubelet health probe, DNS, the API server, and egress to the specific pods
  it manages.

External egress (argocd to GitHub, cert-manager to ACME, grafana to a plugin download, barman to S3) is
`toEntities: [world]` on the specific port rather than `toFQDNs`, so there is no DNS-proxy dependency. Peer
selectors (CoreDNS `k8s-app: kube-dns`, vmagent, the Envoy edge, the stores) are repeated verbatim across the
manifests, so if a platform component is relabelled you grep and update each one.

Three Cilium subtleties to know:

- An admission webhook needs `remote-node` on its ingress rule, not just `kube-apiserver`. When the apiserver on
  node A dials a pod on node B, the packet's source is node A's `cilium_host` router IP (a `10.244.x.y` address),
  which carries the `remote-node` identity. Only the node's PRIMARY IP maps to `kube-apiserver`. So a
  `fromEntities: [kube-apiserver]` rule misses roughly two admissions in three on a 3-node control plane, and the
  webhook only works when the admitting apiserver happens to be co-located with the pod. Same for anything
  reached through the apiserver's service proxy, which is how `kubeseal` fetches the sealed-secrets public cert.
- A `fromEndpoints`/`toEndpoints` selector that OMITS the namespace label matches the policy's OWN namespace
  only. To reach a managed pod in another namespace (cnpg-operator to its instances, redis-operator to its
  redises) use `matchExpressions: [{key: k8s:io.kubernetes.pod.namespace, operator: Exists}]`, NOT the empty `{}`
  selector, which is also same-namespace.
- The RabbitMQ operator subchart ships bundled vanilla `NetworkPolicy`s that default to allow-all-egress. Cilium
  UNIONs those with our CNP and would blow the default-deny open, so we pin `...networkPolicy.enabled: false`.
  Same move as argocd's `global.networkPolicy.create: false`. See [02_gitops.md](02_gitops.md) and
  [08_messaging.md](08_messaging.md).

Deliberately NOT policed, listed so it reads as a decision rather than an omission:

- The Envoy data plane (`mergeGateways` means egress fans out to every backend) and its Gateway controller (same
  namespace, on the ingress critical path).
- `vmagent` and the VictoriaLogs collector, which scrape everything.
- `metrics-server`, and any host-network node agent your OS tooling applies, which sit in kube-system or on
  the host network and so are not subject to these policies.
- `longhorn`, which runs a node-to-node replication mesh.
- `vm-operator`, a tiny apiserver-only surface.
- `03_gateway` and `google-sso`, which have no or thin pods.
- `kube-system` and Cilium itself. Policing those risks cutting the cluster off its own network.
- The `storage-bench` namespace, which exists for hours at a time and holds no data. See
  [12_storage_bench.md](12_storage_bench.md).

Rollout is audit-first: with Cilium's global `policyAuditMode` on, every policy stages as log-only until
validated, then gets enforced by turning audit off. Three places to look, cheapest first:

- `sum by (source, destination) (increase(hubble_flows_processed_total{verdict="AUDIT"}[24h]))` in Grafana, or
  the "would-be drops" row of the `hubble` dashboard. Cluster-wide and survives restarts, but has no port label.
- `source:hubble AND verdict:AUDIT` in VictoriaLogs, which has the port and identity. Retained, so use it for
  anything that already happened. See [06_monitoring.md](06_monitoring.md).
- `hubble observe --verdict AUDIT -f` inside a `cilium-agent` pod, per node. Live only, and the ring buffer holds
  a few minutes, so it is for reproducing on demand: `kubectl apply --dry-run=server` re-triggers admission
  webhooks without changing anything.

## CoreDNS placement

Talos owns the coredns Deployment and sets a `preferred` hostname anti-affinity on it at weight 100. Nothing
here strengthens that. `preferred` is only a score, summed with ImageLocality and the rest, so on a fresh
cluster both replicas CAN land on one node and that node then owns all cluster DNS until something
reschedules them.

That was previously patched to `required` by a wave-0 app. It was removed deliberately: `required` at 2
replicas leaves a pod Pending forever on a single-node cluster, and the risk was judged not worth the
mechanism. The `CoreDNS replica down` alert is what catches the failure now.

## Caveats

- Run order: any node-level network hardening belongs BEFORE this, ahead of Cilium's network-heavy rollout.
  The script's only
  cluster-side dependency is a reachable API, which works over the VIP even with no CNI.
- All nodes are control-plane, so the L2 policy selects every Linux node. The `node-role.kubernetes.io/control-plane:
  DoesNotExist` selector from upstream examples would match zero nodes here and nothing would answer ARP.
  `cilium-lb.yaml` gets this right; do not copy the example blindly.
- CRD apiVersion split: `CiliumLoadBalancerIPPool` is `cilium.io/v2`, `CiliumL2AnnouncementPolicy` is still
  `cilium.io/v2alpha1`. Easy to get wrong by hand.
- L2 announcements is Beta and leans on leader-election leases. If you grow the pool and see operator API
  throttling, raise `k8sClientRateLimit`.
- LB pool placement must sit outside the router's DHCP lease range and clear of the VIP, or you get IP conflicts.
- Circular dependency once Argo owns it: ArgoCD runs on Cilium's network, so a bad Cilium change synced through
  Argo can cut Argo off. Upgrades are normally non-disruptive (per-node agent restart, the eBPF datapath
  persists). The Cilium Application auto-syncs with full `selfHeal` + `prune`, chosen for convenience, so
  upgrades are hands-off but Argo WILL revert an out-of-band fix and WILL cascade-delete a resource or CRD
  dropped from the chart. Keep `01_cilium.sh` as break-glass, and after using it commit the fix to git FAST,
  before `selfHeal` reverts it. A bad change pushed to git applies unattended and is self-healed in place, so
  mind your pushes: this is the one app that can take the whole cluster down. See
  [02_gitops.md](02_gitops.md).

## Troubleshooting

- Nodes stay NotReady after `01_cilium.sh`: the agents are not Ready. `kubectl -n kube-system get pods -l
  k8s-app=cilium`, then `kubectl -n kube-system logs ds/cilium`. Usual causes are the Talos
  `cgroup`/`securityContext` values missing or wrong, or KubePrism unreachable, in which case check that
  `proxy.disabled` and `kubePrism` landed in the machine config.
- `type: LoadBalancer` stuck `<pending>`: no pool, or it is exhausted or overlapping. `kubectl get
  ciliumloadbalancerippool`, and confirm the range is outside the DHCP lease and clear of the VIP.
- LB IP assigned but unreachable: L2 is not announcing. Cilium picks the announcing node from the policy's
  `nodeSelector` ALONE and applies the `interfaces` regex only afterwards, so a node that matches the selector
  but matches no device takes the lease and programs nothing. `interfaces` is therefore the ethernet CLASS
  (`^en`, matching `end0` on a Pi and `eno1`/`enp0s31f6` on x86) rather than one device name, which is what lets
  `nodeSelector` stay broad without that risk. Check who holds it with `kubectl get lease -n kube-system | grep
  l2announce`, and `kubectl get ciliuml2announcementpolicy`.
- Gateway not programmed: that is Envoy Gateway now, not Cilium, whose `gatewayAPI` is disabled. The Gateway API
  CRDs and the `eg` GatewayClass come from the `01_envoy_gateway` app. See [04_ingress.md](04_ingress.md).
