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
| `Chart.yaml`               | the cilium chart version (`1.19.5`), declared as a dependency on `helm.cilium.io`.         |
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
  don't enable. The 6.18 image kernel already carries `CONFIG_WIREGUARD`.
- kube-proxy replacement is mandatory here, L2 announcements requires it. Hence `proxy.disabled: true` at the Talos
  layer and `kubeProxyReplacement: true` in the values.
- KubePrism (`localhost:7445`, default-on in Talos 1.13) is Cilium's API endpoint, pure host networking, no
  external LB needed for Cilium to reach the API server.

## What `04_cilium.sh` does

Uses native `helm` + `kubectl` (errors out if either is missing), unlike the dockerized talos-phase scripts
(03a-03e). Talks to the cluster via `03_operating_system/talos-cluster/kubeconfig` (written by 03d). Idempotent
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

## Caveats

- Run order: 03e before 04. Harden the NIC ahead of Cilium's network-heavy rollout. `04_cilium.sh`'s only
  cluster-side dependency is a reachable API, which works over the VIP even with no CNI.
- All nodes are control-plane, so the L2 policy selects every Linux node. The common
  `node-role.kubernetes.io/control-plane: DoesNotExist` selector from upstream examples would match zero nodes here
  and nothing would answer ARP. `cilium-lb.yaml` gets this right, don't copy the example blindly.
- CRD apiVersion split in 1.19: `CiliumLoadBalancerIPPool` is `cilium.io/v2`, but `CiliumL2AnnouncementPolicy` is
  still `cilium.io/v2alpha1`. Mixed, easy to get wrong by hand.
- L2 announcements is Beta and leans on leader-election leases; if you grow the pool and see operator API
  throttling, raise `k8sClientRateLimit` in the values.
- Circular dependency once Argo owns it: ArgoCD runs on Cilium's network, so a bad Cilium change synced through Argo
  can cut Argo off. Cilium upgrades are normally non-disruptive (per-node agent restart, eBPF datapath persists). The
  Cilium Argo Application auto-syncs but deliberately without `selfHeal` (and `prune: false`): hands-off upgrades,
  but Argo never reverts an out-of-band fix mid-incident nor cascade-deletes a CRD. Keep `04_cilium.sh` as
  break-glass; after using it, commit the fix to git so the app reconciles. The trade-off is that a bad change pushed
  to git applies unattended, so mind your pushes, it's the one app that can take the whole cluster down. See
  [05_gitops.md](05_gitops.md) "sync-wave convention".
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
