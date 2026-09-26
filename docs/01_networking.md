# Networking: Cilium

Cilium is the CNI, the load balancer and the node-to-node encryption, all from one install. Procedures are in
[runbooks/01_networking.md](runbooks/01_networking.md).

- The cluster must arrive with no CNI and no kube-proxy. On Talos, the machine config sets `cni: none` and
  `proxy.disabled: true`.
- Cilium is the only component installed imperatively before Argo CD, because nothing has a pod network until it
  runs. `01_cilium.sh` installs the wrapper chart `argo_apps/platform/charts/00_cilium/`. Argo CD later adopts the
  same release with the same values, so it sees the release as in sync.

## Why Cilium: one component instead of three

Bare-metal Kubernetes ships no LoadBalancer, no ingress and no encryption. Cilium covers all three with one agent
and one operator.

| Need | Cilium provides | What it replaces, and why |
|---|---|---|
| LoadBalancer IPs | LB-IPAM, which hands out IPs from a pool, and L2 announcements, where one node answers ARP for each IP | MetalLB. With Cilium, MetalLB only duplicates the announcement and adds a second ARP owner, pods and CRDs. Trade-off: Cilium L2 is Beta, MetalLB L2 is GA. Beta is fine for a homelab |
| Pod encryption | transparent WireGuard, one flag | Istio or another mesh. The goal is an encrypted wire, not AuthorizationPolicy or VirtualService. Sidecar Istio runs one Envoy per pod, which is heavy on 3 Pis with 8 GB each |
| Ingress | Gateway API is possible, but off | Ingress runs on Envoy Gateway for its `SecurityPolicy` CRD, which attaches SSO by label. See [04_ingress.md](04_ingress.md) |

Decisions:

- **WireGuard, not mTLS.** WireGuard encrypts the wire node to node, with no certs and no SPIFFE. Pod traffic on
  one node stays unencrypted, because it never leaves the host.
- **kube-proxy replacement is on,** because L2 announcements need it.
- **KubePrism (`localhost:7445`) is the API endpoint.** It is host networking, so Cilium reaches the API server
  before any pod network exists.
- **Every `type: LoadBalancer` service uses `externalTrafficPolicy: Cluster`.** Cilium elects the announcing node
  from the `nodeSelector` alone. With `Local`, a node with no backend can win the lease, answer ARP and drop the
  traffic. Leases are sticky, so a bad draw looks like a permanent outage. The cost is the client source IP. See
  [Policy gotchas](#policy-gotchas).
- **Cilium auto-syncs with full `selfHeal` and `prune`,** like every other app, for hands-off upgrades. It is the
  one app that can cut Argo CD off its own network.
  - Argo CD reverts an out-of-band fix unless you commit it.
  - A bad change pushed to git applies unattended. Check every Cilium push.
  - `01_cilium.sh` stays as the break-glass tool, the emergency path that bypasses Argo CD.

## Hubble

Hubble is Cilium's flow observability layer. Relay and UI run in `kube-system`. The platform-ingress app exposes
the UI as `hubble.<domain>` behind Google SSO.

- **A small metric set with peer labels.** Every handler carries namespace and workload context, so panels can
  split traffic by sender. The set stays small to limit series on the Pis. The same metrics drive the
  `cilium-health` alerts. See [06_monitoring.md](06_monitoring.md).
- **A first-party dashboard.** `05_grafana/files/dashboards/hubble.json` replaces the chart's dashboards, which
  draw one line per node with no way to tell them apart.
- **No L7 HTTP metrics.** Hubble sees HTTP only when an L7 policy routes it through Cilium's Envoy proxy. That
  costs a policy change per workload and an extra hop. The `ingress-http` dashboard already covers HTTP from
  Envoy Gateway's own metrics.
- **Dropped-flow logs.** Each denied flow becomes a JSON line in VictoriaLogs as `source:hubble`. It names the pod,
  port and identity, which the `drop` metric only counts. Use it to find the missing rule in a policy.

## Network policy

Each component opts in to lockdown with a `CiliumNetworkPolicy` (CNP). There is no cluster-wide default-deny.

CNP over vanilla `NetworkPolicy` gives two things:

- The `kube-apiserver` and `world` entities, so no policy hardcodes an IP.
- Policy verdicts in Hubble, so a missing rule is visible.

Each chart holds its full policy in its own `templates/networkpolicy.yaml`. No shared library sits in between, so
the file you open is the policy Cilium applies. Platform policies fall in three groups:

| Group | Scope | Components |
|---|---|---|
| Secret holders | the whole namespace (`endpointSelector: {}`) | `sealed-secrets`, `cert-manager`, `argocd` |
| Data stores and services | pod-scoped, because the namespace also holds an unrestricted scraper | `vmsingle`, `vlsingle`, `grafana`, `ntfy`, the RabbitMQ broker, the `redis-backup` and `vm-backup` CronJobs |
| Operators and the backup plugin | pod-scoped | `cnpg-operator`, `redis-operator`, both RabbitMQ operators, the `barman-cloud` plugin |

- External egress uses `toEntities: [world]` on one port, not `toFQDNs`, so no policy depends on Cilium's DNS
  proxy.
- Policies repeat peer selectors word for word: CoreDNS `k8s-app: kube-dns`, vmagent, the Envoy edge, the stores.
  If a component gets new labels, grep for the old ones and update each policy.

### Policy gotchas

- **An admission webhook needs `remote-node` on its ingress rule.** An API server on another node reaches the
  webhook from its `cilium_host` IP, which carries `remote-node`, not `kube-apiserver`. With `kube-apiserver`
  alone, about two admissions in three fail on a 3-node control plane. `kubeseal` fetching its cert through the
  API server proxy hits the same rule.
- **A peer selector without a namespace label matches only the policy's own namespace.** To reach another
  namespace, add `matchExpressions: [{key: k8s:io.kubernetes.pod.namespace, operator: Exists}]`.
- **Traffic through a LoadBalancer service is not `world`.** `externalTrafficPolicy: Cluster` rewrites the source
  to the announcing node. A pod behind its own LoadBalancer needs `[world, remote-node, host]`.
- **Upstream charts can bundle an allow-all `NetworkPolicy`.** Cilium unions it with the CNP, which opens the
  default-deny. So `03_rabbitmq` and `01_argocd` turn theirs off.

### Components with no policy

| Component | Reason |
|---|---|
| The Envoy data plane | `mergeGateways` fans its egress out to every backend |
| The Envoy Gateway controller | same namespace as the data plane, and on the ingress critical path |
| `vmagent`, the VictoriaLogs collector | they scrape everything |
| `metrics-server`, host-network node agents | they sit in `kube-system` or on the host network |
| `longhorn` | it runs a node-to-node replication mesh |
| `vm-operator` | it only talks to the API server |
| `03_gateway`, `google-sso` | they run no pods, or almost none |
| `kube-system`, Cilium itself | a policy there can cut the cluster off its own network |
| the `storage-bench` namespace | it exists for a few hours and holds no data. See [12_storage_bench.md](12_storage_bench.md) |

### Audit-first rollout

Cilium's global `policyAuditMode` is on. Every policy logs a would-be drop as verdict `AUDIT` and drops nothing.
Turn audit mode off once the policies are validated. The runbook lists where to read the would-be drops.

## CoreDNS placement

Talos sets a `preferred` hostname anti-affinity on CoreDNS, so both replicas can land on one node. This repo keeps
it. `required` would leave one replica Pending forever on a single-node cluster. The `CoreDNS replica down` alert
catches the failure instead.
