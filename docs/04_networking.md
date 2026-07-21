# Networking: Cilium

The cluster from [step 03](03_operating_system.md) comes up with no CNI (`cni: none`) and no kube-proxy
(`proxy.disabled: true`), both set in [bring-up](03_operating_system.md#cluster-bring-up). Cilium fills all of it
(CNI, load balancer, gateway, and node-to-node encryption) from one install. `04_cilium.sh` does it, and flips the
nodes to Ready.

This is the one component installed imperatively, everything after it is GitOps. The cluster has no working pod
network until it lands, so ArgoCD (and CoreDNS, and every workload) depend on it.

The single source of truth is the wrapper Helm chart at `argo_apps/platform/charts/00_cilium/`. `04_cilium.sh` just
installs that chart; ArgoCD later adopts the same release (same chart, namespace, release name, values, so Argo sees
it in-sync rather than fighting it). Nothing (no version, no CRD list, no values) is defined in the script. The chart:

| Path                       | Holds                                                                                      |
|----------------------------|--------------------------------------------------------------------------------------------|
| `Chart.yaml`               | the cilium chart version, declared as a dependency on `helm.cilium.io`.         |
| `values.yaml`              | the Talos-flavoured cilium values (under the `cilium:` key) + the `loadBalancer` gate.     |
| `crds/`                    | (empty). Cilium doesn't vendor the Gateway API CRDs; Envoy Gateway owns them now. See [07_ingress.md](07_ingress.md). |
| `templates/cilium-lb.yaml` | the LB-IPAM pool + L2 policy (gated by `.Values.loadBalancer.enabled`).                    |

## Why Cilium: one component instead of three

Bare-metal Kubernetes ships no LoadBalancer, no ingress, and no encryption. The alternative to Cilium is stacking three
single-purpose tools; Cilium provides all of it from one agent + operator:

| Need              | Cilium provides                      | What it replaces, and why                                                                                                                                                                                                                                                                          |
|-------------------|--------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| LoadBalancer IPs  | LB-IPAM + L2 announcements (ARP)     | MetalLB. On an all-Cilium cluster MetalLB only duplicates the IP-announce half (eBPF already does the data-path LB), adds a second ARP owner on the same nodes (conflict-prone), and adds pods/CRDs for no gain. Trade-off: Cilium L2 is Beta vs MetalLB's GA L2, acceptable for a homelab. |
| Ingress / gateway | Gateway API (Envoy-backed)           | ingress-nginx, which is retired (community EOL March 2026). Gateway API is the forward path. Cilium can serve it, but ingress moved to Envoy Gateway (for its SecurityPolicy CRD, label-attached SSO); Cilium's `gatewayAPI` is disabled and it doesn't vendor the Gateway API CRDs. See [07_ingress.md](07_ingress.md).                                                                                                                                                |
| Pod encryption    | transparent WireGuard (one flag)     | Istio / a service mesh. We only wanted the wire encrypted + a gateway, not AuthorizationPolicy/VirtualService. Sidecar Istio is also heavy on 3x 8 GB Pis, an Envoy per pod.                                                                                                                    |
| (mesh, if needed) | sidecarless L7 + Hubble              | covers what we'd use a mesh for, without per-pod sidecars.                                                                                                                                                                                                                                         |

Decision notes:

- Encryption is WireGuard, not mTLS. Transparent, node-to-node, no certs/SPIFFE, exactly "encrypt the wire."
  Same-node pod traffic isn't encrypted (it never leaves the host). Cilium's SPIFFE mutual-auth is a separate feature we
  don't enable. The image kernel already carries `CONFIG_WIREGUARD`.
- kube-proxy replacement is mandatory here, L2 announcements requires it. Hence `proxy.disabled: true` at the Talos
  layer and `kubeProxyReplacement: true` in the values.
- KubePrism (`localhost:7445`, default-on in recent Talos) is Cilium's API endpoint, pure host networking, no
  external LB needed for Cilium to reach the API server.

## What `04_cilium.sh` does

Uses native `helm` + `kubectl` (errors out if either is missing), unlike the dockerized talos-phase scripts
(03a-03e). Talks to the cluster via `secrets/kubeconfig` (written by 03d). Idempotent
(re-run safe).

1. `helm dependency build argo_apps/platform/charts/00_cilium` pulls the pinned `cilium/cilium` subchart into `charts/`
   (falls back to `helm dependency update` to generate `Chart.lock` on first run).
2. `helm upgrade --install cilium argo_apps/platform/charts/00_cilium --wait` installs Cilium with the chart's values.
   They are Talos-flavoured: KubePrism endpoint, kube-proxy replacement, WireGuard, L2 announcements, Hubble, and the
   Talos-mandatory `cgroup` (no auto-mount) + `securityContext` capability blocks. Cilium's `gatewayAPI` is off, the
   ingress data plane is Envoy Gateway (see [07_ingress.md](07_ingress.md)), so no Gateway API CRDs
   ride along here.
3. Waits for nodes Ready (they were NotReady with no CNI).
4. Enables the LB-IPAM pool + L2 policy. The `CiliumLoadBalancerIPPool` / L2 CRDs are registered by the
   cilium-operator at runtime, not shipped by the chart, so on a fresh cluster they don't exist when Helm would
   apply the pool. The script handles this: it installs step 2 with `--set loadBalancer.enabled=false`, then once the
   operator is up re-runs the upgrade with the gate back on (default `true`) so the pool + L2 policy land. On a re-run
   (CRD already present) it does it in one shot. ArgoCD just leaves `loadBalancer.enabled=true` and relies on
   sync-retry.
5. Verifies agent/operator rollout and the LB pool.

```bash
./04_cilium.sh
```

Smoke-test the LoadBalancer end to end:

```bash
kubectl create deploy nginx --image=nginx
kubectl expose deploy nginx --type=LoadBalancer --port=80
kubectl get svc nginx              # EXTERNAL-IP from your pool, reachable over ARP
```

## Hubble observability

Hubble (flow visibility) is on in the chart values: `hubble.enabled`, `relay`, and `ui` are all true, so
`hubble-relay` + `hubble-ui` run in `kube-system`. Two ways it surfaces:

- **Metrics + dashboards.** `hubble.metrics` exports a lean flow set (`dns, drop, tcp, flow, icmp,
  port-distribution` — kept small to bound cardinality on the Pis) with a `serviceMonitor`, so the metrics
  reach vmagent like every other platform scrape (see [09_monitoring.md](09_monitoring.md)).
  `hubble.metrics.dashboards.enabled: true` makes the Cilium chart emit its official Hubble dashboards as
  `grafana_dashboard`-labelled ConfigMaps into `kube-system`; the Grafana sidecar (`searchNamespace: ALL`)
  imports them with no extra wiring. Those same scraped `cilium_*` metrics also drive the `cilium-health`
  Grafana alert group (agent-down, BPF-map pressure, unreachable nodes); see [09_monitoring.md](09_monitoring.md).
- **UI.** The `hubble-ui` Service is exposed as `hubble.<domain>` by the platform-ingress app (wave 6) and
  gated by Google SSO — a plain cross-namespace edge into `kube-system`, added to the same `hosts` list and
  `04_google_sso` allowlist as the other platform UIs (see [07_ingress.md](07_ingress.md)). Before it was
  published this was `kubectl -n kube-system port-forward svc/hubble-ui 12000:80` only.

## Network policy

Lockdown is opt-in per component via `CiliumNetworkPolicy` (there is no cluster-wide default-deny). CNP over
vanilla `NetworkPolicy` buys the `kube-apiserver` / `world` entities (no hardcoded IPs) and Hubble
policy-verdict visibility (`hubble observe --verdict DROPPED`). Two places carry policies:

- **Workloads** — the `sample-workload` (app + its CNPG Postgres); see [10_sample_workload.md](10_sample_workload.md)
  for the app/DB policies and the reusable DB policy baked into the `pg-cluster` wrapper.
- **Platform** — each a full, explicit `CiliumNetworkPolicy` in that chart's `templates/networkpolicy.yaml`
  (no shared library or render abstraction; the policy reads as the resource it is), in three groups:
  - **Secret-holders**, namespace-wide default-deny (`endpointSelector: {}`): `sealed-secrets` / `cert-manager` / `argocd`.
  - **Data stores / services**, pod-scoped (their namespace also holds an unrestricted scraper): the monitoring
    stores `vmsingle` / `vlsingle` / `grafana` (`vmagent` shares `monitoring` and scrapes the whole cluster, so
    it must stay unrestricted), `ntfy`, the RabbitMQ broker, and the egress-only backup CronJobs `redis-backup` / `vm-backup`.
  - **Operators + the backup plugin**, pod-scoped — added so no pod-running component is left implicitly
    default-allow: `cnpg-operator`, `redis-operator`, the RabbitMQ `cluster-operator` + `messaging-topology-operator`,
    and the `barman-cloud` CNPG-I plugin (the S3 backup coordinator, which holds the S3 client mTLS identity).
    Each allows only its real surface — the metrics scrape where a PodMonitor exists, the admission webhook where
    enabled, the kubelet health probe, DNS, the API server, and egress to the specific pods it manages.

  External egress (argocd→GitHub, cert-manager→ACME, grafana→plugin download, barman→S3) is `toEntities: [world]`
  on the specific port, not `toFQDNs` — no DNS-proxy dependency. Peer selectors (CoreDNS `k8s-app: kube-dns`,
  vmagent, the Envoy edge, the stores) are repeated verbatim across the manifests; if a platform component is
  relabeled, grep and update each. Two Cilium subtleties to know: (1) a `fromEndpoints`/`toEndpoints` selector
  that OMITS the namespace label matches the policy's OWN namespace only — to reach a managed pod in another
  namespace (cnpg-operator→instances, redis-operator→redis) use `matchExpressions: [{key:
  k8s:io.kubernetes.pod.namespace, operator: Exists}]`, NOT the empty `{}` selector (also same-namespace); (2)
  the RabbitMQ operator subchart ships bundled vanilla `NetworkPolicy`s defaulting to allow-all-egress — Cilium
  UNIONs those with our CNP and would blow the default-deny open, so we pin `…networkPolicy.enabled: false`
  (the same move as argocd's `global.networkPolicy.create: false`; see [05_gitops.md](05_gitops.md) / [11_messaging.md](11_messaging.md)).

  **Deliberately NOT policed** (documented so it's a decision, not an omission): the Envoy data-plane
  (`mergeGateways` → egress fans out to every backend) AND its Gateway controller (same namespace, on the ingress
  critical path), `vmagent` + the VictoriaLogs collector (scrape everything), `metrics-server` and `nic-keeper`
  (kube-system / host-network), `longhorn` (node-to-node replication mesh), `vm-operator` /
  `local-path-provisioner` (tiny apiserver-only surface), and `03_gateway` / `google-sso` (no or thin pods).
  `kube-system` and Cilium itself are left alone — policing them risks cutting the cluster off its own network.
  (The workload-stack operators above were once in this bucket for the same "tiny surface" reason; they were
  promoted to policed so the exclusion list is now infra-only.)

Rollout is audit-first: with Cilium's global `policyAuditMode` on (see `00_cilium`), every policy stages as
log-only (`hubble observe --verdict AUDIT`) until validated, then enforced by turning audit off.

## Caveats

- Run order: 03e before 04. Harden the NIC ahead of Cilium's network-heavy rollout. `04_cilium.sh`'s only
  cluster-side dependency is a reachable API, which works over the VIP even with no CNI.
- All nodes are control-plane, so the L2 policy selects every Linux node. The common
  `node-role.kubernetes.io/control-plane: DoesNotExist` selector from upstream examples would match zero nodes here
  and nothing would answer ARP. `cilium-lb.yaml` gets this right, don't copy the example blindly.
- CRD apiVersion split: `CiliumLoadBalancerIPPool` is `cilium.io/v2`, but `CiliumL2AnnouncementPolicy` is
  still `cilium.io/v2alpha1`. Mixed, easy to get wrong by hand.
- L2 announcements is Beta and leans on leader-election leases; if you grow the pool and see operator API
  throttling, raise `k8sClientRateLimit` in the values.
- Circular dependency once Argo owns it: ArgoCD runs on Cilium's network, so a bad Cilium change synced through Argo
  can cut Argo off. Cilium upgrades are normally non-disruptive (per-node agent restart, eBPF datapath persists). The
  Cilium Argo Application auto-syncs with full `selfHeal` + `prune` (chosen for convenience): hands-off upgrades, but
  Argo WILL revert an out-of-band fix and WILL cascade-delete a resource/CRD dropped from the chart. Keep `04_cilium.sh`
  as break-glass; after using it, commit the fix to git FAST, before `selfHeal` reverts it. The trade-off is that a bad
  change pushed to git applies unattended and is self-healed in place, so mind your pushes, it's the one app that can
  take the whole cluster down. See [05_gitops.md](05_gitops.md) "sync-wave convention".
- LB pool placement: must sit outside the Archer's DHCP lease range and clear of the `.100.1` VIP, or you'll get IP
  conflicts.

## Troubleshooting

- Nodes stay NotReady after `04_cilium.sh` -> cilium agents aren't Ready.
  `kubectl -n kube-system get pods -l k8s-app=cilium`,
  then `kubectl -n kube-system logs ds/cilium`. Usual causes: the Talos `cgroup`/`securityContext` values missing or
  wrong, or KubePrism unreachable (the agent can't hit `localhost:7445` -> check `proxy.disabled` + `kubePrism` landed in
  the machine config).
- `type: LoadBalancer` stuck `<pending>` -> no pool, or it's exhausted/overlapping. `kubectl get
  ciliumloadbalancerippool`; confirm the range is outside the DHCP lease and clear of the VIP.
- LB IP assigned but unreachable -> L2 isn't announcing. On this all-control-plane cluster confirm the policy's
  `nodeSelector` is not `control-plane: DoesNotExist` (selects zero nodes here), and the `interfaces` regex matches
  `end0`. `kubectl get ciliuml2announcementpolicy`.
- Gateway not programmed -> that's Envoy Gateway now, not Cilium (Cilium's `gatewayAPI` is disabled). The
  Gateway API CRDs + the `eg` GatewayClass come from the `01_envoy_gateway` app. See [07_ingress.md](07_ingress.md).
