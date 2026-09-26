# Networking runbook

Decisions are in [01_networking.md](../01_networking.md).

## Install or repair Cilium

Use this on a new cluster, or as break-glass when a bad Cilium sync cut the network.

1. Set the LoadBalancer pool in `.env`. Keep it outside the router's DHCP range and away from the control-plane
   VIP, or IPs conflict.
2. Run the script:

   ```bash
   make install-cilium
   ```

   Expected: every check prints `[PASS]`, and the nodes turn Ready.
3. After a break-glass run, commit the fix at once. Otherwise Argo CD `selfHeal` reverts it.

## Test a LoadBalancer

```bash
kubectl create deploy nginx --image=nginx
kubectl expose deploy nginx --type=LoadBalancer --port=80
kubectl get svc nginx   # EXTERNAL-IP comes from your pool and answers over ARP
```

## Find would-be drops during the audit rollout

Three places show them, cheapest first:

1. Grafana, the "would-be drops" row of the `hubble` dashboard, or:

   ```promql
   sum by (source, destination) (increase(hubble_flows_processed_total{verdict="AUDIT"}[24h]))
   ```

   Covers the whole cluster and survives restarts. It has no port label.
2. VictoriaLogs: `source:hubble AND verdict:AUDIT`. It has the port and identity, and it keeps history.
3. Live, one node at a time, inside a `cilium-agent` pod:

   ```bash
   hubble observe --verdict AUDIT -f
   ```

   The ring buffer holds a few minutes. `kubectl apply --dry-run=server` calls the admission webhooks again
   without changing anything, so it reproduces a webhook drop on demand.

## Troubleshooting

- **Nodes stay NotReady after the install.** Run `kubectl -n kube-system logs ds/cilium`. The usual cause is wrong
  Talos `cgroup` or `securityContext` values. Another cause is an unreachable KubePrism: check `proxy.disabled`
  and `kubePrism` in the machine config.
- **A LoadBalancer service stays `<pending>`.** The pool is missing, full or overlaps. Run
  `kubectl get ciliumloadbalancerippool`.
- **The LB IP is assigned but unreachable.**
  1. Check the service's `externalTrafficPolicy`. It must be `Cluster`.
  2. Find the lease holder: `kubectl get lease -n kube-system | grep l2announce`.
  3. Check that the holder has an interface matching `^en`. A node without one takes the lease and answers no ARP.
- **The operator logs API throttling after the pool grew.** Raise `k8sClientRateLimit` in the Cilium values.
- **A Gateway is not programmed.** Envoy Gateway serves Gateways, not Cilium. See the
  [ingress doc](../04_ingress.md).
