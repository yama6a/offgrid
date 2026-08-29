# The Intel iGPU, and how a pod gets at it

Video transcoding on a CPU is the most expensive thing this cluster could be asked to do. The amd64 worker has
an Intel iGPU that does it in fixed-function silicon instead. Getting a pod onto that silicon takes two pieces
in two repos, and neither works without the other.

## What the hardware can actually do

Coffee Lake-S GT2, UHD Graphics 630. Gen9.5 QuickSync, so:

| | decode | encode |
|---|---|---|
| H.264 8-bit | yes | yes |
| HEVC 8-bit and 10-bit | yes | yes |
| VP9 | yes | no |
| AV1 | no | no |

Roughly 2-4 concurrent 1080p transcodes before quality suffers. An AV1 source still transcodes, just in
software, and that is the one case where the GPU buys nothing.

## Two pieces, two repos

**The driver is not here.** Talos builds `i915` as a module and ships neither the module nor its firmware in
the base image, so the node has no `/dev/dri` at all until `siderolabs/i915` is in the machine's schematic.
That lives with whatever tooling builds your nodes. Symptom when it is missing: this chart's DaemonSet has
nowhere to run and stays at 0 desired, because nothing carries the label it selects on.

**This repo supplies the other half.** `argo_apps/platform/charts/02_intel_gpu_plugin`, wave 2. The scheduler
does not know hardware exists unless something tells it, so a pod asking for a GPU would otherwise land
anywhere and find no device. The plugin is a kubelet device plugin: it finds the render nodes under `/dev/dri`,
reports them to the kubelet as an allocatable resource, and the scheduler then treats `gpu.intel.com/i915` like
CPU or memory. Ask for it and you get placed on the machine that has it.

```yaml
resources:
  limits:
    gpu.intel.com/i915: "1"   # no nodeSelector needed; the request IS the placement
```

## `sharedDevNum` is a contention cap, not a partition

`sharedDevNum: 2` in `values.yaml` makes the node advertise 2 of a resource it physically has 1 of. Both
holders get the whole GPU and time-slice against each other; there is no isolation and no fair share. What the
number really buys is a ceiling on how many things can be fighting at once. A third claimant stays `Pending` on
`Insufficient gpu.intel.com/i915` rather than joining a queue nobody is managing.

Raise it and nothing goes Pending, but nothing is protected either. Lower it to 1 and one workload locks the
GPU against every other.

## Two things that are usually a fight here, and are not

**No node-feature-discovery.** Every guide on this installs NFD plus a set of Intel `NodeFeatureRule` CRs, to
end up with a label saying the machine has an Intel GPU. Talos already writes `extensions.talos.dev/i915` on
any node that booted the extension, which is the same fact from a more reliable source, so the DaemonSet
selects on that and two components disappear. It has to be a `nodeAffinity` with `Exists`, not a
`nodeSelector`: the label's value is a firmware date that changes on every extension bump, and `nodeSelector`
cannot match on a key alone.

**No `supplementalGroups` on consumers.** The usual failure is a container that can see `/dev/dri/renderD128`
and not open it, fixed by hunting down the host's `render` group id and pasting it into every pod. Talos ships
a udev rule that makes render nodes mode `0666`, and has no `/etc/group` for `render` to resolve against, so
the device is world-writable with group 0. Any uid can open it. Leave the pods alone.

`card0` stays `0600` root-owned, because the `video` group cannot resolve either, but transcoding only ever
touches the render node.

## Why the device plugin and not DRA

Dynamic Resource Allocation is the direction Kubernetes is going and the cluster is new enough for it. Intel
ships a resource driver that would replace this chart. Two reasons it is not that today:

- It needs containerd's CDI spec directories pointed at writable paths, which is a machine-config change on
  every node, and the node tooling has no per-node hook for one.
- The integer-slot model is a better fit for transcoding than attribute-based selection. There is one GPU with
  no attributes worth selecting on; what we want is a cap on concurrent users, and that is what
  `sharedDevNum` is.

Revisit if a second, different GPU ever joins the cluster. That is the case the plugin models badly and DRA
models well.

## Verifying

```
kubectl get node <amd64 node> -o jsonpath='{.status.allocatable}' | jq   # expect gpu.intel.com/i915
kubectl -n inteldeviceplugins-system get pods -o wide                    # exactly one, on that node
```

Then prove a pod gets a working device, not just a scheduling slot. `linuxserver/ffmpeg` carries the iHD driver
and `vainfo`:

```
kubectl run vainfo --rm -it --restart=Never --image=linuxserver/ffmpeg:latest \
  --overrides='{"spec":{"containers":[{"name":"vainfo","image":"linuxserver/ffmpeg:latest",
    "command":["sh","-c","ls -l /dev/dri && vainfo --display drm --device /dev/dri/renderD128"],
    "resources":{"limits":{"gpu.intel.com/i915":"1"}}}]}}'
```

Want `VAProfileH264*` and `VAProfileHEVCMain10` with both `VAEntrypointVLD` (decode) and `VAEntrypointEncSlice`
(encode). No `VAProfileAV1*`: expected, not a fault.

## The gotcha for whoever adds the first consumer

`intel/intel-gpu-plugin` is published amd64-only, and so are most transcoding images. `make check-multiarch`
reads live pods with no idea which node a pod can reach, so it flags any of them. `SKIP_IMAGES` at the top of
`lib/shell/check_multiarch.sh` exempts them. Add the arch pin to the chart FIRST and the skip second: an entry
there for an unpinned image hides a real `exec format error` until it reaches a Pi.
