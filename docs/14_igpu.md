# The Intel iGPU

Video transcoding is the most CPU-expensive work this cluster could get. The amd64 worker has an Intel iGPU that
does it in fixed-function hardware instead. Setup and checks are in [runbooks/14_igpu.md](runbooks/14_igpu.md).

Coffee Lake-S GT2, UHD Graphics 630, Gen9.5 QuickSync. It handles about 2 to 4 concurrent 1080p transcodes:

| Codec | Decode | Encode |
|---|---|---|
| H.264 8-bit | yes | yes |
| HEVC 8-bit and 10-bit | yes | yes |
| VP9 | yes | no |
| AV1 | no | no |

## Two pieces in two repos

A pod needs both. Neither works alone.

| Piece | Where | Does |
|---|---|---|
| `i915` driver | the node tooling's Talos schematic, `siderolabs/i915` | creates `/dev/dri` on the node |
| device plugin | `argo_apps/platform/charts/02_intel_gpu_plugin`, wave 2 | reports the GPU as the resource `gpu.intel.com/i915` |

A pod requests the resource and nothing else. The scheduler places it on the GPU node, with no nodeSelector.

```yaml
resources:
  limits:
    gpu.intel.com/i915: "1"
```

## Decisions

- **`sharedDevNum: 2`.** The node advertises 2 slots of its 1 GPU. Both holders time-slice with no isolation.
  A third waits `Pending`. A higher value protects no pod from contention. 1 lets one workload lock the GPU.
- **No node-feature-discovery.** Talos already labels each node that booted the extension. That is the same fact
  from a more reliable source, so NFD and its Intel rules add nothing.
- **No `supplementalGroups` on consumers.** Talos sets render nodes to mode `0666`, so any uid opens them.
- **The device plugin, not DRA.** Intel's DRA driver needs containerd's CDI spec directories on writable paths.
  That is a machine-config change on every node, and the node tooling has no per-node hook for it. The need is
  a cap on concurrent users of one GPU, and `sharedDevNum` is that cap. Revisit when a second, different GPU
  joins the cluster. DRA models that case well.
