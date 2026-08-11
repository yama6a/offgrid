# 17: The node inventory, and adding a worker

Where the node list lives, and what changes when a node is not a control-plane Pi.

## inventory.yaml is the node list

Topology outgrew a flat string. A node now has a role, a hardware type, and its own image source, and
`CLUSTER_NODES="host:ip ..."` in `.env` had nowhere to put any of that. So `inventory.yaml` (gitignored, template
in `inventory.example.yaml`) replaces it. `common.sh` parses it once at source time and derives the arrays every
script iterates.

Migrating an existing `.env`: copy the template, fill in your hosts, delete the `CLUSTER_NODES` line. Leaving
that line in is a hard error, because it is no longer read as an array and `${#CLUSTER_NODES[@]}` would quietly
be 1, which would make the node-count gates compare against the wrong number.

| Field | Meaning |
|---|---|
| `host` | the Kubernetes node name; applied via a `HostnameConfig` document |
| `ip` | reserve it in your router; 03c applies config to this address |
| `role` | `controlplane` or `worker`. Decides which config 03c generates |
| `type` | the hardware. Stamped as `node.kubernetes.io/instance-type` |
| `imageSource` | `github-release` or `image-factory`. Where this node's two artifacts come from |
| `imageFile` | the raw-image filename 03a downloads and writes |
| `imageSchematic` | required for `image-factory`, rejected otherwise: the extension set to build with |

**Six keys, and only one optional.** Anything that is not a CHOICE is derived rather than stored. There is no
`arch`, because `imageFile` already names it and the kubelet sets `kubernetes.io/arch` itself. There is no
`bootVerify` or `nicHardening`, because which of 03b's checks run and whether 03d hardens the NIC both follow
from `type`: properties of the hardware, not decisions.

`imageSource` is the exception, and it is deliberate. Its presence IS inferable, from whether the node has an
`imageSchematic`, and an earlier version of this file did exactly that. It reads worse: the single most useful
question about a node ("where does its image come from?") then has no answer you can see, only one you can
deduce. So the discriminator is spelled out, and `common.sh` validates the pair in BOTH directions rather than
leaving them free to disagree.

**No hardware-type table, also deliberately.** Every field sits on the node, so a node's whole definition reads
in one place. The cost is that nodes of the same type repeat five fields and could disagree. `common.sh`
validates presence, the two enums, and uniqueness of hosts and IPs, but it cannot catch a plausible-but-wrong
`asset`: that one writes a bootable-looking image of the wrong architecture, and you find out at boot.

## Two image sources

Each node needs TWO artifacts, and they do not come from the same place:

| `imageSource` | raw image 03a flashes | installer 03c bakes in and 03e upgrades to | checksum |
|---|---|---|---|
| `github-release` | a release ASSET on `github.com/<repo>/releases/download/${TALOS_IMAGE_RELEASE}/` | a CONTAINER at `${TALOS_IMAGE_REPO}:${TALOS_IMAGE_RELEASE}` | yes, `sha256sums.txt` |
| `image-factory` | `factory.talos.dev/image/<id>/${TALOS_VERSION}/<imageFile>` | `factory.talos.dev/metal-installer/<id>:${TALOS_VERSION}` | no, HTTPS only |

The `github-release` row is the one that surprises: same repo NAME, two different hosts, because a release asset
lives on `github.com` and a container lives on `ghcr.io`. `03a` builds the first by stripping the registry
prefix off `TALOS_IMAGE_REPO`.

The Pi build exists for the rpi5 overlay and a patched kernel. An x86 node needs neither, so building one would
be maintenance with no payload; the factory serves a stock image built from a committed extension list
(`lib/talos/schematic-amd64.yaml`). The schematic id is a content hash, POSTed and resolved at run time, so
there is no id to pin and none to go stale.

**Versions stay in `versions.env`.** The inventory says where an image comes from, never which version, so one
`TALOS_IMAGE_RELEASE` bump moves every node: `TALOS_VERSION` is derived from it and the factory resolves both
the image and its extensions against that.

The one asymmetry worth knowing: extension pinning differs by source. The Pi image bakes whatever its release
built; the factory resolves the schematic's names per Talos version. Same upstream versions, different mechanism.
Not something to "fix".

## Adding a worker

```
make flash-talos-nvme         # pick the node from a list; writes its image to an NVMe over USB
make add-node NODE=<host>     # generates + applies its config; it joins on its own
```

The flasher's pick selects the IMAGE, not the drive, so one run covers every drive of the same hardware type.
It asks rather than defaulting to a node, because the wrong pick writes another architecture's image and that
boots to nothing. `NODE=<host>` skips the prompt for a scripted run.

A full `make bootstrap-cluster` or `make rebuild-cluster` needs neither command: 03c iterates the whole
inventory, control-plane nodes first, so a worker is brought up in the same pass. Adding a worker is not a
separate operation, it is another entry in the list.

**It joins schedulable, not cordoned.** A cordon would fight two things: `03g_rebalance_workloads.sh` refuses to
run while any node is cordoned, and during a bootstrap a cordoned worker packs the whole platform onto the Pis
and then needs a rebalance. Cordon by hand if you want to stage it.

## What a worker's config leaves out

A worker gets a strict subset. Not a separate script: the maintenance wait, the registries block, the volume
documents, the `HostnameConfig` apply and the reboot wait are the bulk of 03c and are identical either way.

| | control-plane | worker |
|---|---|---|
| `--output-types` | `controlplane,talosconfig` | `worker` |
| VIP and `machine.network.interfaces` | on `end0` | **omitted entirely** |
| `apiServer.certSANs` | the VIP plus every control-plane IP | n/a |
| `etcd.extraArgs`, `allowSchedulingOnControlPlanes` | yes | n/a |
| `cluster.network.cni`, `cluster.proxy` | yes | n/a, a worker reads neither |
| kubelet `extraMounts`, KubePrism, volumes | identical | identical |

Omitting the interfaces block is what keeps a NIC name we cannot predict out of the config. Talos DHCPs every
link by default and a worker carries no VIP, so nothing needs to name it. Interface naming on x86 is
firmware-dependent (`eno1` on many HP boxes, `enp0s31f6` when firmware omits the onboard index), and guessing
wrong is a node with no network.

`machine.install.image` and the instance-type label are per NODE, not per role, so they ride in their own patch
at apply time. That is what lets one `gen config` per role serve any mix of hardware types.

`talosctl config endpoint` stays control-plane-only: a worker cannot proxy the Talos API. `-n <worker-ip>` still
reaches it through a control-plane endpoint.

## Mixed architectures

Nothing in Kubernetes stops an arm64-only image landing on an amd64 node. The scheduler does not look at image
architecture, so the pod is placed and then `CrashLoopBackOff`s with `exec format error`.

```
make check-multiarch                # require every arch the cluster currently runs
ARCH=amd64 make check-multiarch     # require amd64 BEFORE any amd64 node exists
```

Run it with `ARCH=` before the first node of a new architecture joins. Without the override it checks only what
the cluster already is, which by definition cannot catch the image that is about to break.

It reads the LIVE pods, not `values.yaml`, because most images come from upstream charts and never appear in this
repo. It also catches a digest pin that resolves to a single platform rather than to the index, which reading the
values files cannot.

A failing image needs a multi-arch rebuild, or a `nodeAffinity` on `kubernetes.io/arch` in its chart so the
scheduler stops offering it nodes it cannot run on.

## Reset order: workers first, and finished

A worker holds no Talos CA key. Its `apid` gets a server certificate signed by `trustd`, which runs only on
control-plane nodes, on port 50001. So a worker's Talos API is alive only while at least one control-plane node
is.

So the reset order decides whether a worker survives, and getting it wrong is not recoverable over the network:

- reset everything in parallel, the (faster) control-plane nodes go down first
- the worker is still mid-sequence, its `apid` dies with `trustd` and cannot come back
- `talosctl` retries a node that will never answer, up to its 30-minute default
- the worker's reset never completes, so nothing on its disk is wiped
- every reboot from there parks at `task startAllServices (1/1): service "apid" to be "up"`, forever

At that point there is no API in, and Talos has no shell. The only way out is a physical reflash.

`DANGEROUS_reset_talos_cluster.sh` resets `WORKER_IPS` first, waits for each to answer the MAINTENANCE api
again, and only then resets `CP_IPS`. It waits for maintenance rather than just for the reset call to return,
because the guarantee needed is that the worker no longer depends on the control plane at all. If any
worker fails either check the script aborts with the control plane still up, so the node is still reachable
and you can retry.

Same reasoning orders `03e_talos_upgrade.sh` workers-first, though there the cost of getting it wrong is only
a lost quorum rather than a reflash.

## Two things that break with a non-Pi node

**Cilium L2 announcements.** `CiliumL2AnnouncementPolicy` picks the announcing node from `nodeSelector` alone,
and applies its `interfaces` regex afterwards, only to choose which links to program on the winner. So a node
that matches the selector but matches zero devices still takes the lease, programs no ARP responder, and every
LoadBalancer IP goes dark until the lease moves. A device-NAME regex like `^end0$` walks straight into that the
first time a non-Pi node joins.

The fix is to match the wired-ethernet CLASS instead, `^en`, which covers `end0` on a Pi and `eno1` or
`enp0s31f6` on x86 while still excluding `lo`, `bond`/`dummy`, the `cilium_*` virtuals and `wl*` wifi. Then no
node can match the policy and match zero devices, so `nodeSelector` can stay broad and neither field needs
editing when hardware changes.

That is sound here for one reason worth stating out loud: **every node has exactly one connected NIC.** Two on
the same segment would both answer for the LB IP with different MACs and it would flap between them, which is
the only thing a name-specific regex was protecting against. A disconnected second port is harmless (no frames
arrive, and Cilium would not select an address-less device anyway); a connected one is not.

Announcing is independent of both role and backend placement: the service is `externalTrafficPolicy: Cluster`,
so whichever node answers the ARP forwards through the eBPF datapath to Envoy wherever it runs. Measured on the
live cluster, the lease sat on `talos-cp2` while the only Envoy pod ran on `talos-cp3`, and the ingress served in
~100ms. So every node being a candidate is wanted: more of them means the lease survives more node losses. See
[04_networking.md](04_networking.md).

**Node-count literals in alerts.** `cilium-health` compared the agent count against a literal `3`, which stops
firing the moment a 4th node exists, because 3 of 4 agents up is still "at least 3". It now compares against
`count(kube_node_info)`. Worth grepping for other literals before adding a node; a silently disarmed alert is
worse than a noisy one.

## Scheduling: a bigger node takes a bigger share

`NodeResourcesFit` scores `(allocatable - requested) / allocatable`, a fraction, so nodes converge on the same
PERCENTAGE full, and a node with 4x the memory settles at roughly 4x the requests. Nothing balances raw pod
count: `pods` is not scorable by that plugin, and `PodTopologySpread` is always scoped to one workload's own
replicas, which does nothing for the ~30 single-replica Deployments here.

That is fine, and deliberately left alone. Two consequences to know rather than rediscover:

- The multi-arch check is not optional. Those single-replica pods are exactly what lands on a new node.
- Blast radius follows share. A node holding several times a Pi's requests cannot be absorbed by the Pis if it
  dies, and `cluster-memory-overcommit` is the alert that notices.

If that ever matters, the lever is to advertise less than the hardware has:

```yaml
machine:
  kubelet:
    extraConfig:
      systemReserved: {cpu: 8000m, memory: 23Gi}   # a 12-core/32Gi node scores like a 4-core/7.5Gi one
```

`enforceNodeAllocatable` defaults to `["pods"]`, so this changes what the scheduler sees and nothing else:
nothing is OOM-killed for it. Apply with `talosctl patch mc --mode no-reboot`; the kubelet restarts, the node
does not.

## x86 BIOS

Short, because the NVMe arrives pre-installed and there is no boot medium to prioritise.

1. Apply factory defaults, exit.
2. Boot order: the M.2 NVMe first, **UEFI** mode. Disable Fast Boot.
3. Secure Boot: off. Stock Talos images are not signed with a key OEM firmware trusts.
4. After power loss: **On**. A headless node has to come back by itself.
5. Leave TPM on. Inert unless you enable disk encryption.

**Boot UEFI, never legacy/CSM.** Talos 1.10 split bootloaders: systemd-boot with a UKI for UEFI, GRUB kept only
for legacy BIOS, and there is an open report of HP hardware failing to boot in legacy mode since
(siderolabs/talos#13224). A consequence of the UKI: `machine.install.extraKernelArgs` is ignored on a UEFI
install because the cmdline is baked in. Kernel args would need `customization.extraKernelArgs` in the
schematic; none are needed here.
