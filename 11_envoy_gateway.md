# 11 — Envoy Gateway: the Gateway API data plane

Swap the cluster's **Gateway API data plane** from Cilium Gateway API to **Envoy Gateway**. Cilium
stays the CNI and the LB-IPAM provider; only the *gateway* implementation changes. The whole reason is
the next step: Envoy Gateway's **`SecurityPolicy`** can attach OIDC/JWT/authorization to routes **by
label** ([12_google_sso.md](12_google_sso.md)) — Cilium Gateway API has no per-route auth hook at all.

Delivered purely by ArgoCD:

- `argo_apps/platform/apps/01_envoy_gateway.yaml` — the Application, **sync-wave 1**.
- `argo_apps/platform/charts/01_envoy_gateway/` — the wrapper chart: the envoy-gateway controller (upstream
  `gateway-helm`), the `eg` `GatewayClass`, and an `EnvoyProxy` that pins the LoadBalancer IP.
- a one-line flip in `argo_apps/platform/charts/00_cilium/values.yaml` (`gatewayAPI.enabled: false`) + removal
  of the vendored Gateway API CRDs.
- `argo_apps/platform/charts/03_gateway/` retargeted to `gatewayClassName: eg` (it's now platform-only — Gateway
  + listeners + issuers; the sample workload lives in [sample-workload](13_sample_workload.md)).

This step has **no imperative script** — the only manual action is generating the chart's `Chart.lock`
(`helm dependency update argo_apps/platform/charts/01_envoy_gateway` + commit), like the other dependency charts.

## Why Envoy Gateway

The cluster needs **optional Google SSO with an email allowlist that attaches to chosen routes** (add a
host → label its route → it's protected; no per-host proxy). Cilium Gateway API can't express that.
Envoy Gateway ships a `SecurityPolicy` CRD with `targetSelectors` (label-based attachment) and native
`oidc` + `jwt` + `authorization`. That single capability is worth swapping the data plane for. Cilium
keeps doing what it's best at — CNI, WireGuard, L2 announcements, LB-IPAM — and Envoy Gateway becomes
the one thing that terminates and routes ingress.

## Decisions

### Cilium stops being the gateway; Envoy Gateway owns the Gateway API CRDs
`cilium.gatewayAPI.enabled: false` drops the `cilium` `GatewayClass` and Cilium's gateway controller.
Envoy Gateway's `gateway-helm` vendors the Gateway API CRDs (it ships **v1.5.1**, newer than the v1.4.1
Cilium vendored), so we **remove** `argo_apps/platform/charts/00_cilium/crds/gateway.networking.k8s.io_*.yaml`
and let Envoy Gateway be the single owner. The handover is safe: the Cilium app is `prune: false`, so
dropping the CRD files never cascade-deletes the live CRDs; Envoy Gateway re-applies them via
ServerSideApply and adopts field ownership. No Gateway/HTTPRoute is lost.

### Sync-wave 1 — same wave as ArgoCD
Envoy Gateway needs only the CNI (wave 0). It must come **before** two things: cert-manager (wave 2),
whose `enableGatewayAPI` wants the Gateway API CRDs present when its controller starts, and the gateway
(wave 3), which references the `eg` class. Wave 1 is the lowest wave that satisfies both. Two apps may
share a wave (distinct dir names), as the wave-2 leaves already do; ArgoCD is already running and
self-managing, so it creates the `envoy-gateway` child app fine.

### Per-app Gateways merged onto one Envoy (`mergeGateways: true`)
Each app now owns its **own** Gateway with a single `:443` listener; `shared-gateway` keeps only the
`:80` HTTP listener (cert-manager HTTP-01 + redirects). By default Envoy Gateway spawns **one Envoy
Deployment + one LoadBalancer Service per Gateway** — which would hand out a fresh external IP per app.
Setting `mergeGateways: true` on the `EnvoyProxy` collapses **every** Gateway of the `eg` class onto a
**single** Envoy Deployment and a **single** LoadBalancer Service, so the split into per-app Gateways
still presents **one ingress point on one pinned IP**. It's the precondition for both the per-app split
and the single-annotation IP pinning below.

### Pinning the LoadBalancer IP (unchanged externally)
The old Pi forwards `:80`/`:443` to a fixed IP — it must stay `192.168.100.10`. Under `mergeGateways`
there is exactly **one** data-plane `LoadBalancer` Service for the whole `eg` class, and the `EnvoyProxy`
provider config is its **sole** IP authority: `provider.kubernetes.envoyService.annotations:
{ lbipam.cilium.io/ips: 192.168.100.10 }` (Cilium LB-IPAM honours it on >= 1.15). The old
belt-and-suspenders per-Gateway `spec.addresses` request is **dropped everywhere** — with the class
collapsed onto one Service, multiple Gateways each asserting an address on it would conflict, so the
annotation pins the IP alone. The IP must stay inside the LB-IPAM pool (`192.168.100.10-250`, from
`04_networking/config.sh`).

### cert-manager HTTP-01 is unaffected
The `gatewayHTTPRoute` solver is standard Gateway API — cert-manager creates a temporary HTTPRoute on
the `:80` listener exactly as before, now served by Envoy Gateway. No ClusterIssuer change. The
`03_gateway` chart's issuers + Gateway carry over untouched apart from the class (its sample workload has
since moved to [`sample-workload`](13_sample_workload.md), and per-host certs/routes are owned by each app).

### The `eg` GatewayClass + EnvoyProxy live in the controller chart
`GatewayClass eg` (`controllerName: gateway.envoyproxy.io/gatewayclass-controller`) points its
`parametersRef` at the `EnvoyProxy` in `envoy-gateway-system`, so every Gateway of this class inherits
the pinned-IP provider config. The shared Gateway (`03_gateway` chart) just sets
`gatewayClassName: eg`.

## Apply / verify

1. Generate the lock and commit: `helm dependency update argo_apps/platform/charts/01_envoy_gateway` then commit
   `Chart.lock` (the vendored `charts/*.tgz` is gitignored, reproduced from the lock — same as the other
   wrapper charts).
2. `git add -A && git commit && git push`. ArgoCD brings up Envoy Gateway (wave 1), then the rest of the
   waves re-converge on the `eg` class.

Checks:

- `kubectl get gatewayclass eg` → `ACCEPTED=True`.
- `kubectl -n gateway get gateway shared-gateway` → `PROGRAMMED=True`, address `192.168.100.10`.
- `kubectl -n envoy-gateway-system get pods` → controller Running; a data-plane `envoy-*` pod appears
  once the Gateway is programmed, and its Service has EXTERNAL-IP `192.168.100.10`.
- `kubectl get clusterissuer` → both Ready; `kubectl -n gateway get certificate` issuing as before.
- once the sample workload ([sample-workload](13_sample_workload.md)) syncs,
  `curl -kv https://sample-workload.<baseDomain>/` → the sample app (no auth — the unprotected control;
  `sample-workload-sso` gets SSO in step 12).

## Caveats

- **Commit `Chart.lock`** (and push `argo_apps/**`) before expecting a sync — ArgoCD's repo-server runs
  `helm dependency build`, which needs the lock.
- **The CRD handover is one-way and version-bumping** (v1.4.1 → v1.5.1, experimental channel). It's
  additive for the core kinds we use; if Envoy Gateway ever rejects an externally-managed CRD version,
  the fallback is to keep Cilium vendoring the CRDs and have Envoy Gateway install only its own (the
  separate `gateway-crds-helm` chart with `crds.gatewayAPI.enabled=false`).
- **Old-Pi forwarding is unchanged** — same IP, same `:80`/`:443` forwards (see [10_gateway.md](10_gateway.md)).
- **Free the pinned IP at cutover.** Cilium created `cilium-gateway-shared-gateway` (LoadBalancer, IP
  `.10`) for the old Gateway. With Cilium's gateway controller disabled nothing reconciles that Service,
  so it can **linger and hold `192.168.100.10`**, blocking Envoy Gateway's new Service from getting it.
  Flipping `mergeGateways` likewise makes Envoy Gateway tear down its old per-Gateway data-plane Services
  and recreate a single merged one under the per-class name (`envoy-gateway-system/envoy-eg-<hash>`), so a
  stale per-Gateway EG Service can also hold the IP. After the change, verify **exactly one** `LoadBalancer`
  Service holds `192.168.100.10`; if any orphan (Cilium's or a stale per-Gateway EG one) still holds it,
  delete it so LB-IPAM reassigns — e.g. `kubectl -n gateway delete svc cilium-gateway-shared-gateway`.
  One-off, apply-time only.

## Next step

[12_google_sso.md](12_google_sso.md) — the `SecurityPolicy` that attaches Google SSO to labelled routes,
proven on `sample-workload-sso`.
