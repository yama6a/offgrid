# Networking: Cilium

Cilium is the CNI, the load balancer and the node-to-node encryption, all from one install. `01_cilium.sh`
installs it, and the nodes then turn Ready.

The cluster must arrive with no CNI and no kube-proxy. This repo states that prerequisite in the README but does
not arrange it. On Talos, the machine config sets `cni: none` and `proxy.disabled: true`. Other distributions have
their own switch.

- Cilium is the only component installed imperatively before Argo CD. Everything after Argo CD is GitOps.
- Nothing has a pod network until Cilium runs, so Argo CD, CoreDNS and every workload depend on it.
- The wrapper chart at `argo_apps/platform/charts/00_cilium/` is the source of truth. The script only installs
  that chart. Argo CD later adopts the same release, with the same chart, namespace, release name and values. So
  Argo CD sees it as in sync and does not fight it.
- The script holds no version, CRD list or value.

| Path                       | Holds                                                                                      |
|----------------------------|--------------------------------------------------------------------------------------------|
| `Chart.yaml`               | the cilium chart, declared as a dependency on `helm.cilium.io`                              |
| `values.yaml`              | the Talos-specific cilium values under the `cilium:` key, and the `loadBalancer` gate       |
| `crds/`                    | empty. Cilium does not vendor the Gateway API CRDs. Envoy Gateway owns them. See [04_ingress.md](04_ingress.md) |
| `templates/cilium-lb.yaml` | the LB-IPAM pool and the L2 policy, gated by `.Values.loadBalancer.enabled`                 |

## Why Cilium: one component instead of three

Bare-metal Kubernetes ships no LoadBalancer, no ingress and no encryption. The alternative is three
single-purpose tools. Cilium covers all of them with one agent and one operator.

- **LB-IPAM** is Cilium's LoadBalancer IP address management. It hands out IPs from a pool.
- **L2 announcements** make one node answer ARP for each LoadBalancer IP, so the LAN can reach it.

| Need              | Cilium provides                    | What it replaces, and why |
|-------------------|------------------------------------|---------------------------|
| LoadBalancer IPs  | LB-IPAM and L2 announcements (ARP) | MetalLB. On a cluster that runs Cilium, MetalLB only duplicates the IP announcement. eBPF already does the data-path load balancing. MetalLB also adds a second ARP owner on the same nodes, plus pods and CRDs, for no gain. Trade-off: Cilium L2 is Beta, MetalLB L2 is GA. Beta is fine for a homelab. |
| Ingress, gateway  | Gateway API, backed by Envoy       | ingress-nginx, which the community retired in March 2026. Gateway API is its successor. Cilium can serve Gateway API, but ingress runs on Envoy Gateway for its `SecurityPolicy` CRD, which attaches SSO by label. So Cilium's `gatewayAPI` is off and Cilium vendors no Gateway API CRDs. See [04_ingress.md](04_ingress.md) |
| Pod encryption    | transparent WireGuard, one flag    | Istio or another service mesh. The goal is an encrypted wire and a gateway. AuthorizationPolicy and VirtualService are not needed. Sidecar Istio also runs one Envoy per pod, which is heavy on 3 Pis with 8 GB each |
| A mesh, if needed | sidecarless L7 and Hubble          | the parts of a mesh this repo would use, without per-pod sidecars |

Decisions:

- WireGuard, not mTLS. WireGuard is transparent and node-to-node, with no certs and no SPIFFE. It does exactly
  one job: encrypt the wire.
  - Pod traffic on the same node is not encrypted, because it never leaves the host.
  - Cilium's SPIFFE mutual authentication is a separate feature. This repo does not turn it on.
  - The Talos kernel already has `CONFIG_WIREGUARD`.
- kube-proxy replacement is required, because L2 announcements need it. So the Talos machine config sets
  `proxy.disabled: true`, and the values set `kubeProxyReplacement: true`.
- KubePrism (`localhost:7445`) is Cilium's API server endpoint. KubePrism is pure host networking, so Cilium
  needs no external load balancer to reach the API server.

## What `01_cilium.sh` does

The script uses native `helm` and `kubectl` and fails if either is missing. It reaches the cluster through the
pinned kubeconfig that `KUBE_CONTEXT` selects. It is idempotent.

1. `helm dependency build argo_apps/platform/charts/00_cilium` pulls the pinned `cilium/cilium` subchart into
   `charts/`. On a first run it falls back to `helm dependency update`, which generates `Chart.lock`.
2. `helm upgrade --install cilium ... --wait` installs with the chart's values. These set the KubePrism endpoint,
   kube-proxy replacement, WireGuard, L2 announcements and Hubble. They also set the `cgroup` block with no
   auto-mount and the `securityContext` capability block, which Talos requires.
3. Waits for the nodes to turn Ready. They stay NotReady while there is no CNI.
4. Turns on the LB-IPAM pool and the L2 policy. See the two-pass install below.
5. Checks the agent and operator rollout, and the LB-IPAM pool.

The install runs in two passes. The cilium-operator registers the `CiliumLoadBalancerIPPool` and L2 CRDs at
runtime. The chart does not ship them.

- On a fresh cluster, the CRDs do not exist yet when Helm applies the pool. So step 2 runs with
  `--set loadBalancer.enabled=false`.
- Once the operator is up, the script runs the upgrade again with the gate on.
- On a re-run the CRDs already exist, so one pass does it.
- Argo CD keeps `loadBalancer.enabled=true` and relies on sync retry.

```bash
./01_cilium.sh
```

Test the LoadBalancer end to end:

```bash
kubectl create deploy nginx --image=nginx
kubectl expose deploy nginx --type=LoadBalancer --port=80
kubectl get svc nginx              # EXTERNAL-IP comes from your pool and answers over ARP
```

## Hubble observability

Hubble is Cilium's flow observability layer. `hubble.enabled`, `relay` and `ui` are all true, so `hubble-relay`
and `hubble-ui` run in `kube-system`.

- **Metrics.** `hubble.metrics` exports a small flow set: `dns, drop, tcp, flow, icmp, port-distribution`. The set
  stays small to limit the number of series on the Pis. A `serviceMonitor` sends it to vmagent like every other
  platform scrape.
  - Every handler spells out its context options: `labelsContext=source_namespace,destination_namespace`, plus
    `sourceContext` and `destinationContext` of `workload-name|reserved-identity`.
  - A bare handler name emits the counter with no peer or namespace labels. Then nothing can split the traffic
    by sender.
  - The same `cilium_*` metrics drive the `cilium-health` Grafana alert group: agent down, BPF map pressure,
    unreachable nodes. See [06_monitoring.md](06_monitoring.md).
- **Dashboard.** One first-party `hubble` dashboard lives in `05_grafana/files/dashboards/hubble.json`.
  - `hubble.metrics.dashboards.enabled: false` keeps the chart's own four dashboards out of Grafana. Those group
    every panel by cilium-agent pod without showing the pod. So each panel draws one line per node, and the
    lines cannot be told apart.
  - The first-party dashboard sums across agents and makes the node a variable.
  - Rows: overview, drops and would-be (`AUDIT`) drops, top talkers per namespace, TCP, ICMP and ports, DNS.
- **What the DNS panels can see.** `hubble_dns_*` only counts DNS that goes through Cilium's DNS proxy. A pod
  only goes through that proxy when a policy has `toFQDNs` or L7 `dns` rules.
  - Today only the two backup CronJobs have such a policy. So the DNS row is almost empty, and that is correct.
  - DNS from every other pod shows up as plain UDP flows.
- **No L7 HTTP metrics.** `httpV2` is off, so there is no `hubble_http_*` and no L7 row.
  - Turning it on takes more than the handler. Hubble only sees HTTP that an L7 `http` rule in a
    CiliumNetworkPolicy sends through the Envoy L7 proxy.
  - So each workload needs a policy change and pays an extra proxy hop.
  - For the ingress path it would count what the edge already counts.
  - HTTP observability comes from the `ingress-http` dashboard, built on Envoy's own metrics. See
    [04_ingress.md](04_ingress.md).
- **UI.** The platform-ingress app (wave 6) exposes the `hubble-ui` Service as `hubble.<domain>`, gated by Google
  SSO. It is a plain cross-namespace edge into `kube-system`. It sits in the same `hosts` list and
  `04_google_sso` allowlist as the other platform UIs. See [04_ingress.md](04_ingress.md).
- **Dropped-flow logs.** `hubble.export.dynamic` writes one JSON line per `DROPPED` flow to a file on the node.
  The log collector ships it to VictoriaLogs as `source:hubble`.
  - The `drop` metric only counts drops. The log names the pod, port and identity. Use it to find the missing
    rule in a default-deny policy.
  - `hubble observe --verdict DROPPED` shows the same live, but only for what happens right now. See
    [06_monitoring.md](06_monitoring.md).

## Network policy

Each component opts in to lockdown with a `CiliumNetworkPolicy` (CNP). There is no cluster-wide default-deny.

CNP over vanilla `NetworkPolicy` gives two things:

- The `kube-apiserver` and `world` entities, so no policy hardcodes an IP.
- Policy verdicts in Hubble: `hubble observe --verdict DROPPED`.

Policies live in two places:

- **Workloads.** The sample workload's app and its CNPG Postgres. The `pg-cluster` wrapper also carries a
  reusable DB policy. See [07_sample_workload.md](07_sample_workload.md).
- **Platform.** Each chart holds its full policy in its own `templates/networkpolicy.yaml`. The file you open is
  the policy Cilium applies. No shared library or render layer sits in between.

Platform policies fall in three groups:

| Group | Scope | Components |
|---|---|---|
| Secret holders | the whole namespace, default-deny (`endpointSelector: {}`) | `sealed-secrets`, `cert-manager`, `argocd` |
| Data stores and services | pod-scoped, because the namespace also holds an unrestricted scraper | `vmsingle`, `vlsingle`, `grafana`, `ntfy`, the RabbitMQ broker, and the egress-only backup CronJobs `redis-backup` and `vm-backup` |
| Operators and the backup plugin | pod-scoped, so no pod-running component stays default-allow | `cnpg-operator`, `redis-operator`, the RabbitMQ `cluster-operator` and `messaging-topology-operator`, the `barman-cloud` CNPG-I plugin |

- `vmagent` shares the `monitoring` namespace with the stores. It scrapes the whole cluster, so it stays
  unrestricted.
- The `barman-cloud` plugin coordinates S3 backups and holds the S3 client mTLS identity.
- Each operator policy allows only what the operator uses:
  - the metrics scrape, where a PodMonitor exists
  - the admission webhook, where it is on
  - the kubelet health probe
  - DNS and the API server
  - egress to the pods it manages

External egress uses `toEntities: [world]` on the specific port, not `toFQDNs`. So no policy depends on the DNS
proxy. Examples: argocd to GitHub, cert-manager to ACME, grafana to a plugin download, barman to S3.

The manifests repeat peer selectors word for word: CoreDNS `k8s-app: kube-dns`, vmagent, the Envoy edge, the
stores. If a platform component gets new labels, grep for the old ones and update each policy.

### Cilium gotchas

- **An admission webhook needs `remote-node` on its ingress rule.** `kube-apiserver` alone is not enough.
  - Example: the API server on node A calls a webhook pod on node B. The packet's source is node A's
    `cilium_host` router IP, a `10.244.x.y` address. That IP carries the `remote-node` identity.
  - Only the node's primary IP maps to `kube-apiserver`.
  - So a `fromEntities: [kube-apiserver]` rule misses about two admissions in three on a 3-node control plane.
    The webhook only works when the calling API server runs on the same node as the pod.
  - The same applies to anything reached through the API server's service proxy. `kubeseal` fetches the
    sealed-secrets public cert that way.
- **A `fromEndpoints` or `toEndpoints` selector without a namespace label matches only the policy's own
  namespace.** The empty `{}` selector is also same-namespace. To reach a pod in another namespace, use
  `matchExpressions: [{key: k8s:io.kubernetes.pod.namespace, operator: Exists}]`. Examples: cnpg-operator to its
  instances, redis-operator to its Redis pods.
- **Traffic through a `type: LoadBalancer` service is not `world`.**
  - `externalTrafficPolicy: Cluster` rewrites the client source to the IP of the node that answered ARP.
  - So the policy sees `remote-node`, or `host` when that node also runs the pod.
  - A pod behind its own LoadBalancer service needs `[world, remote-node, host]` on its ingress rule.
- **Upstream charts can bundle vanilla `NetworkPolicy` objects that allow all egress.** The RabbitMQ operator
  subchart does. Cilium unions them with the CNP, which opens the default-deny.
  - So `03_rabbitmq` pins `...networkPolicy.enabled: false`.
  - `01_argocd` does the same with `global.networkPolicy.create: false`.
  - See [02_gitops.md](02_gitops.md) and [08_messaging.md](08_messaging.md).

### Components with no policy

These have no policy by decision:

| Component | Reason |
|---|---|
| The Envoy data plane | `mergeGateways` fans its egress out to every backend |
| The Envoy Gateway controller | same namespace as the data plane, and on the ingress critical path |
| `vmagent`, the VictoriaLogs collector | they scrape everything |
| `metrics-server`, host-network node agents from your OS tooling | they sit in `kube-system` or on the host network, so these policies do not apply |
| `longhorn` | it runs a node-to-node replication mesh |
| `vm-operator` | it only talks to the API server |
| `03_gateway`, `google-sso` | they run no pods, or almost none |
| `kube-system`, Cilium itself | a policy there can cut the cluster off its own network |
| the `storage-bench` namespace | it exists for a few hours and holds no data. See [12_storage_bench.md](12_storage_bench.md) |

### Audit-first rollout

Cilium's global `policyAuditMode` is on. Every policy then only logs, and drops nothing. Once a policy is
validated, turning audit mode off enforces it.

Three places show would-be drops, cheapest first:

1. Grafana: `sum by (source, destination) (increase(hubble_flows_processed_total{verdict="AUDIT"}[24h]))`, or the
   "would-be drops" row of the `hubble` dashboard. It covers the whole cluster and survives restarts. It has no
   port label.
2. VictoriaLogs: `source:hubble AND verdict:AUDIT`. It has the port and the identity. It keeps history, so use it
   for anything that already happened. See [06_monitoring.md](06_monitoring.md).
3. `hubble observe --verdict AUDIT -f` inside a `cilium-agent` pod, one node at a time. It is live only, and its
   ring buffer holds a few minutes. Use it to reproduce a drop on demand. `kubectl apply --dry-run=server` calls
   the admission webhooks again without changing anything.

## CoreDNS placement

Talos owns the coredns Deployment. It sets a `preferred` hostname anti-affinity on it, at weight 100.

- `preferred` is only a score. The scheduler adds it to ImageLocality and the other scores.
- So on a fresh cluster, both replicas can land on one node. That node then serves all cluster DNS until
  something reschedules the pods.
- This repo does not change the anti-affinity to `required`. With 2 replicas, `required` leaves one pod Pending
  forever on a single-node cluster.
- The `CoreDNS replica down` alert catches the failure instead.

## Caveats

- **Run order.** Apply any node-level network hardening before this step, ahead of Cilium's network-heavy
  rollout. The script only needs a reachable API server. That works over the control-plane virtual IP (VIP) even
  with no CNI.
- **The L2 policy selects every Linux node.** All nodes are control-plane nodes. Upstream examples use the
  selector `node-role.kubernetes.io/control-plane: DoesNotExist`. Here it matches zero nodes, and then no node
  answers ARP. `cilium-lb.yaml` gets this right. Do not copy the example.
- **The two CRDs use different API versions.** `CiliumLoadBalancerIPPool` is `cilium.io/v2`.
  `CiliumL2AnnouncementPolicy` is still `cilium.io/v2alpha1`. Take care when you write them by hand.
- **L2 announcements are Beta and use leader-election leases.** If you grow the pool and see the operator throttled
  by the API server, raise `k8sClientRateLimit`.
- **Place the LB-IPAM pool outside the router's DHCP range and away from the VIP.** Otherwise IPs conflict.
- **Every `type: LoadBalancer` service must use `externalTrafficPolicy: Cluster`.** Upstream documents L2
  announcements as incompatible with `Local`.
  - Cilium elects the lease holder from the `nodeSelector` alone. With `Local`, a node with no backend can win the
    lease. It then answers ARP and drops the traffic.
  - Leases are sticky. A bad draw looks like a permanent outage. A good draw holds until an agent restart, reboot
    or upgrade shuffles the leases again.
  - `Cluster` loses the client source IP, which changes the policy identity. See the `world` gotcha under
    [Cilium gotchas](#cilium-gotchas).
- **Cilium and Argo CD depend on each other.** Argo CD runs on Cilium's network, so a bad Cilium change synced by
  Argo CD can cut Argo CD off.
  - Upgrades normally cause no outage. Each node's agent restarts, and the eBPF datapath stays in place.
  - The Cilium Application auto-syncs with full `selfHeal` and `prune`, for hands-off upgrades.
  - So Argo CD reverts an out-of-band fix. It also deletes any resource or CRD that leaves the chart.
  - `01_cilium.sh` stays as the break-glass tool, the emergency path that bypasses Argo CD. After you use it,
    commit the fix to git at once, before `selfHeal` reverts it.
  - A bad change pushed to git applies unattended, and `selfHeal` keeps it in place. This is the one app that can
    take the whole cluster down, so check every push. See [02_gitops.md](02_gitops.md).

## Troubleshooting

- **Nodes stay NotReady after `01_cilium.sh`.** The agents are not Ready.
  - Run `kubectl -n kube-system get pods -l k8s-app=cilium`, then `kubectl -n kube-system logs ds/cilium`.
  - Usual cause: the Talos `cgroup` or `securityContext` values are missing or wrong.
  - Other cause: KubePrism is unreachable. Check that `proxy.disabled` and `kubePrism` are in the machine config.
- **A `type: LoadBalancer` service stays `<pending>`.** There is no pool, or the pool is full or overlaps. Run
  `kubectl get ciliumloadbalancerippool`. Confirm the range is outside the DHCP range and away from the VIP.
- **The LB IP is assigned but unreachable.**
  - Check the service's `externalTrafficPolicy` first. `Local` breaks L2 announcements per service, and only some
    of the time. See [Caveats](#caveats).
  - Otherwise L2 is not announcing at all. Cilium picks the announcing node from the policy's `nodeSelector`
    alone. It applies the `interfaces` regex only after that. So a node that matches the selector but has no
    matching device takes the lease and programs nothing.
  - So `interfaces` matches the ethernet device class, `^en`, not one device name. `^en` matches `end0` on a Pi
    and `eno1` or `enp0s31f6` on x86. That lets `nodeSelector` stay broad.
  - Find the lease holder with `kubectl get lease -n kube-system | grep l2announce`. Check the policy with
    `kubectl get ciliuml2announcementpolicy`.
- **A Gateway is not programmed.** Envoy Gateway handles Gateways, not Cilium, whose `gatewayAPI` is off. The
  Gateway API CRDs and the `eg` GatewayClass come from the `01_envoy_gateway` app. See
  [04_ingress.md](04_ingress.md).
