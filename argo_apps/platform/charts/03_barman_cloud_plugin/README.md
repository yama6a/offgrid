# 03_barman_cloud_plugin

`templates/plugin-barman-cloud.yaml` is the upstream release `manifest.yaml`, vendored without changes.

- Never edit it by hand. Re-vendor it with the recipe below.
- It holds no Go-template braces, so Helm passes it through as is.
- Its header names no version. So a version bump only changes `appVersion` in `Chart.yaml`.

## Bump the pinned version

```sh
VER=vX.Y.Z   # the new release tag. The current pin is appVersion in Chart.yaml
{
  printf '# Vendored VERBATIM from the plugin-barman-cloud release pinned in Chart.yaml appVersion. DO NOT EDIT BY HAND.\n'
  printf '# Source: https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/<appVersion>/manifest.yaml\n'
  printf '# Re-vendor via this chart README; bump appVersion in Chart.yaml to match. See docs/10_backups.md.\n---\n'
  curl -fsSL "https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/${VER}/manifest.yaml"
} > templates/plugin-barman-cloud.yaml
```

Then set `appVersion` in `Chart.yaml` to the same tag, and push.

The plugin needs CNPG 1.26 or later and cert-manager, so it is in wave 3.
