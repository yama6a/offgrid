# NIC keeper — runtime macb-wedge recovery

The **runtime** complement to [`03e`'s machine-config NIC defences](03_operating_system.md#nic-hardening--the-macb-wedge).
`03e` hardens the Pi 5 `macb` NIC at the Talos config level (offloads off, rings → max, hardware
watchdog); the three remaining failure modes have **no `EthernetConfig` field** and must be handled by a
live agent. That agent is `nic-keeper` — one DaemonSet pod per rpi5 node, delivered by ArgoCD
([05_gitops.md](05_gitops.md)) at sync-wave 2.

Chart: `argo_apps/platform/charts/02_nic_keeper/` · Application: `argo_apps/platform/apps/02_nic_keeper.yaml`.

## Problem

Three `macb` failure modes that machine-config can't reach (the other two are `03e`'s — see its table):

| runtime trigger                 | what happens                                          | defence                              |
|---------------------------------|-------------------------------------------------------|--------------------------------------|
| EEE LPI-wake race               | link wakes from low-power idle too slowly, drops frames| assert `ethtool --set-eee end0 eee off` |
| silent wedge                    | link stays **up**, carrier fine, but no traffic passes | active ping probe → bounce `ip link` down/up |
| post-recovery kubelet socket stall | after a bounce, kubelet's old TCP sockets to the API server hang | `ss -K` to drop them so they reconnect |

## Solution

One consolidated per-node agent (`nic-keeper`, namespace `kube-system`, hostNetwork). On each node it:

1. **Asserts EEE off** on start (and after every bounce — a bounce can re-enable it).
2. **Probes link health** every `checkIntervalSeconds` (5s): pings the default gateway *and* reads
   `/sys/class/net/end0/carrier`. The ping is the real signal — a wedge keeps carrier up, so carrier
   alone misses it.
3. **On `failThreshold` (4) consecutive failures → recovers:** `ip link set end0 down` → brief sleep →
   `up`, re-assert EEE off, `ss -K dport = :6443` to drop stale API-server sockets, then honours
   `cooldownSeconds` (60s) before probing again (anti-flap).

One structured stdout line per event (`<ts> nic-keeper iface=end0 event=<name> …`). The loop script
lives in `templates/configmap.yaml` (mounted + exec'd); every knob is in `values.yaml`.

## Decisions

| decision                         | why                                                                                  |
|----------------------------------|--------------------------------------------------------------------------------------|
| **DaemonSet**                    | the fix is per-node and must run *on the host's* NIC + netns — one pod per node.      |
| **Consolidated single agent**    | EEE, link-watchdog and socket-drop share state (one wedge → all three react); one loop beats three pods racing. |
| **Runtime, not machine-config**  | no Talos `EthernetConfig` field for EEE; wedge detection is reactive; socket-drop is post-recovery. |
| **Active ping, not carrier**     | the wedge is link-up-no-traffic — carrier reads healthy, only an actual probe catches it. |
| **Flap protection**              | `failThreshold` before acting + `cooldownSeconds` after — never bounce in a tight loop. |
| **`NET_ADMIN` + `NET_RAW`**      | NET_ADMIN covers `ethtool` EEE / `ip link` / `ss -K`; NET_RAW is required for `ping`'s ICMP socket (drop:ALL removes it). Still least-privilege — beats `privileged: true`. |
| **Auto-sync (prune + selfHeal)** | safe leaf — it can't cut the cluster off its own network, so drift just auto-corrects. Contrast Cilium (wave 0), which auto-syncs *without* selfHeal/prune precisely because it can. |
| **`instance-type: rpi5` selector** | the macb wedge is Pi 5-only; selecting rpi5 hardware keeps the pod off a future non-rpi5 node. Not `os: linux` (too broad), not `control-plane:DoesNotExist` (every node here is control-plane → matches zero nodes, same trap as the Cilium L2 policy). |

The selector label `node.kubernetes.io/instance-type: rpi5` is stamped by Talos `machine.nodeLabels` in
[`03d`](03_operating_system.md#what-03d_talos_cluster_configsh-does) (`NODE_INSTANCE_TYPE` in `03_config.sh`).
That key works because it's on the kubelet **NodeRestriction allowlist** — an arbitrary `kubernetes.io/*`
label would be rejected by admission.

## Caveats / preconditions

- **Kernel 6.18** — older Pi 5 kernels can't toggle EEE; the loop logs `event=eee-unsupported` and keeps
  running the link-watchdog. The custom image already ships 6.18 (see [03a](03_operating_system.md)).
- **`CONFIG_INET_DIAG_DESTROY`** — required for `ss -K`. If absent, the loop logs `event=ss-k-unsupported`
  once and **skips** the socket-drop step rather than failing (link bounce + EEE still run).
- **A brief link bounce is expected** on every recovery (`linkDownSeconds`, ~2s of downtime).
- **Never trips the `03e` hardware watchdog** — every action is short and the loop always makes progress
  (no unbounded waits).
- **Thresholds are tunable** in `values.yaml` (`checkIntervalSeconds`, `failThreshold`, `linkDownSeconds`,
  `cooldownSeconds`, `ssKillFilter`, `pingTarget`). The agent only ever touches `iface` (`end0`).

## Run / verify

ArgoCD picks it up automatically at sync-wave 2 (after Cilium + ArgoCD). No imperative step — it's
GitOps from the first commit. To check:

```bash
export KUBECONFIG=./03_operating_system/talos-cluster/kubeconfig

kubectl get ds -n kube-system nic-keeper                              # DESIRED = CURRENT = READY = 3
kubectl logs -n kube-system -l app.kubernetes.io/name=nic-keeper     # one pod per node
#   ... event=eee-off ok          <- startup assert
#   ... event=start target=192.168.10.1 interval=5s ...

kubectl get nodes -L node.kubernetes.io/instance-type                # all three show rpi5
```

A recovery looks like (in the logs of the affected node's pod):

```
... event=probe-fail target=192.168.10.1 carrier=1 count=4/4
... event=wedge fail_count=4 threshold=4 carrier=1 — bouncing link
... event=ss-kill filter='dport = :6443' result=...
... event=recovery link bounced + eee re-asserted; cooldown=60s
```

> **Live cluster (label not yet present):** if the cluster predates the `03d` change, stamp the label
> without a reboot the same way `03e` patches config:
> `talosctl -n <node-ip> patch mc --mode no-reboot --patch '{"machine":{"nodeLabels":{"node.kubernetes.io/instance-type":"rpi5"}}}'`
> (repeat per node). Otherwise the DaemonSet has nothing to schedule onto.
