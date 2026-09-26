# The Intel iGPU, and how a pod gets at it

Video transcoding is the most CPU-expensive work this cluster could get. The amd64 worker has an Intel iGPU
that does it in fixed-function hardware instead. A pod needs two pieces in two repos to reach that hardware.
Neither piece works without the other.

## What the hardware can do

Coffee Lake-S GT2, UHD Graphics 630, with Gen9.5 QuickSync:

| Codec | Decode | Encode |
|---|---|---|
| H.264 8-bit | yes | yes |
| HEVC 8-bit and 10-bit | yes | yes |
| VP9 | yes | no |
| AV1 | no | no |

- Capacity: about 2 to 4 concurrent 1080p transcodes before quality drops.
- AV1 sources: still transcode, but in software. This is the one case where the GPU gives nothing.

## Two pieces, two repos

### The driver

The driver lives outside this repo. Talos builds `i915` as a kernel module. The base image ships neither
the module nor its firmware. So the node has no `/dev/dri` until the machine's schematic includes
`siderolabs/i915`. The tooling that builds your nodes owns that schematic.

- Symptom when the driver is missing: this chart's DaemonSet stays at 0 desired. No node carries the label it
  selects on, so it has nowhere to run.

### The device plugin

The device plugin is this repo's half: `argo_apps/platform/charts/02_intel_gpu_plugin`, wave 2. The
scheduler knows about hardware only when something reports it. Without the plugin, a pod that asks for a GPU
lands on any node and finds no device.

A kubelet device plugin is a pod that reports node hardware to the kubelet as an allocatable resource. This
one finds the render nodes under `/dev/dri`. The scheduler then treats `gpu.intel.com/i915` like CPU or
memory. A pod that requests it gets placed on the machine that has it.

```yaml
resources:
  limits:
    gpu.intel.com/i915: "1"   # the request alone places the pod, no nodeSelector needed
```

## `sharedDevNum` is a contention cap

`sharedDevNum: 2` in `values.yaml` makes the node advertise 2 units of a GPU it has 1 of.

- Both holders get the whole GPU and time-slice against each other.
- There is no isolation and no fair share.
- The number sets a ceiling on how many pods use the GPU at once.
- A third claimant stays `Pending` with `Insufficient gpu.intel.com/i915`. It does not join an unmanaged queue.

| Value | Effect |
|---|---|
| higher than 2 | no pod goes `Pending`, but no pod is protected from contention |
| 1 | one workload locks the GPU against all others |

## Common setup steps this cluster skips

### No node-feature-discovery

Node-feature-discovery (NFD) is a controller that labels nodes by their hardware. Most guides install NFD
plus a set of Intel `NodeFeatureRule` CRs to get a label for "this machine has an Intel GPU". Talos already writes `extensions.talos.dev/i915` on each node that booted the extension.
That is the same fact from a more reliable source. So the DaemonSet selects on that label, and NFD and the
rules are not needed.

- The selector must be a `nodeAffinity` with `Exists`, not a `nodeSelector`.
- The label's value is a firmware date that changes with every extension bump.
- A `nodeSelector` cannot match on a key alone.

### No `supplementalGroups` on consumers

The usual failure elsewhere is a container that sees `/dev/dri/renderD128` but cannot open it. The usual fix is to find the host's `render` group id and add it to
every pod. On Talos this is not needed:

- A Talos udev rule sets render nodes to mode `0666`.
- Talos has no `/etc/group`, so `render` does not resolve and the group stays 0.
- The device is world-writable, so any uid can open it. Leave the pods alone.

`card0` stays `0600` and owned by root, because the `video` group does not resolve either. Transcoding only
uses the render node, so this has no effect.

## Why the device plugin and not DRA

Dynamic Resource Allocation (DRA) is the newer Kubernetes API for claiming devices. The cluster is new enough
for it, and Intel ships a DRA driver that could replace this chart. This repo stays on the device plugin for
two reasons:

- The DRA driver needs containerd's CDI spec directories on writable paths. That is a machine-config change on
  every node, and the node tooling has no per-node hook for it.
- Integer slots fit transcoding better than attribute-based selection. The cluster has one GPU with no
  attributes worth selecting on. The need is a cap on concurrent users, and `sharedDevNum` is that cap.

Revisit this if a second, different GPU joins the cluster. The plugin models that case badly and DRA models it
well.

## Verify

```
kubectl get node <amd64 node> -o jsonpath='{.status.allocatable}' | jq   # expect gpu.intel.com/i915
kubectl -n inteldeviceplugins-system get pods -o wide                    # exactly one, on that node
```

Then prove that a pod gets a working device, not only a scheduling slot. Request the resource and nothing
else: no nodeSelector, no `/dev/dri` mount. If the pod lands on the right node and finds the device, both
pieces work.

```
kubectl run vaenc --rm -it --restart=Never --image=linuxserver/ffmpeg:latest \
  --overrides='{"spec":{"containers":[{"name":"vaenc","image":"linuxserver/ffmpeg:latest",
    "command":["sh","-c","ls -l /dev/dri && ffmpeg -hide_banner -init_hw_device vaapi=va:/dev/dri/renderD128 -filter_hw_device va -f lavfi -i testsrc=size=1920x1080:rate=30:duration=10 -vf format=nv12,hwupload -c:v h264_vaapi -f null -"],
    "resources":{"limits":{"gpu.intel.com/i915":"1"}}}]}}'
```

Expected output:

- `renderD128` listed as `crw-rw-rw-`.
- `speed=` well above `1x`. At `1x` or below, ffmpeg fell back to software.

The image has no `vainfo`, only `ffmpeg` and `ffprobe`. A real encode is the better test anyway. A VAAPI
device can initialise and still fail at the codec.

To test the concurrency cap, start `sharedDevNum + 1` pods that each claim one GPU. The last one must report
`Insufficient gpu.intel.com/i915`.

## Before you add the first consumer

`intel/intel-gpu-plugin` is published for amd64 only, and so are most transcoding images. `make
check-multiarch` reads live pods and does not know which nodes a pod can reach, so it flags all of them.
`SKIP_IMAGES` at the top of `lib/shell/check_multiarch.sh` exempts an image.

1. Add the amd64 pin to the consumer's chart.
2. Then add the image to `SKIP_IMAGES`.

Do not reverse the order. A skip entry for an image without the pin hides a real `exec format error` until the
pod lands on a Pi.
