# Runbook: Intel iGPU

Why the iGPU is set up this way: [../14_igpu.md](../14_igpu.md).

## Verify

1. Check that the node advertises the GPU and the plugin runs:

   ```bash
   kubectl get node <amd64 node> -o jsonpath='{.status.allocatable}' | jq   # expect gpu.intel.com/i915
   kubectl -n inteldeviceplugins-system get pods -o wide                    # exactly one, on that node
   ```

   If the plugin DaemonSet stays at 0 desired, the node lacks the driver. Add `siderolabs/i915` to its
   schematic in your node tooling.

2. Prove that a pod gets a working device, not only a slot. The pod requests the resource and nothing else:

   ```bash
   kubectl run vaenc --rm -it --restart=Never --image=linuxserver/ffmpeg:latest \
     --overrides='{"spec":{"containers":[{"name":"vaenc","image":"linuxserver/ffmpeg:latest",
       "command":["sh","-c","ls -l /dev/dri && ffmpeg -hide_banner -init_hw_device vaapi=va:/dev/dri/renderD128 -filter_hw_device va -f lavfi -i testsrc=size=1920x1080:rate=30:duration=10 -vf format=nv12,hwupload -c:v h264_vaapi -f null -"],
       "resources":{"limits":{"gpu.intel.com/i915":"1"}}}]}}'
   ```

   Expected output:
   - `renderD128` listed as `crw-rw-rw-`
   - `speed=` well above `1x`. At `1x` or below, ffmpeg fell back to software.

3. To test the concurrency cap, start `sharedDevNum + 1` pods that each claim one GPU. The last one must report
   `Insufficient gpu.intel.com/i915`.

## Add the first consumer

The plugin and most transcoding images are amd64-only. `make check-multiarch` flags them, because it does not
know which nodes a pod can reach.

1. Add the amd64 pin to the consumer's chart.
2. Then add the image to `SKIP_IMAGES` at the top of `lib/shell/check_multiarch.sh`.

Keep this order. A skip entry without the pin hides a real `exec format error` until the pod lands on a Pi.
