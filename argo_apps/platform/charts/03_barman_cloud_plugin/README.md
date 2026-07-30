# 03_barman_cloud_plugin

`templates/plugin-barman-cloud.yaml` is the upstream release `manifest.yaml`, vendored verbatim.

- Never hand-edit it. Re-vendor instead, with the recipe below.
- It carries no Go-template braces, so Helm passes it through untouched.
- The header names no version, so a bump only touches `appVersion` in `Chart.yaml`.

## Bump the pinned version

```sh
VER=vX.Y.Z   # the new release tag; the current pin is appVersion in Chart.yaml
{
  printf '# Vendored VERBATIM from the plugin-barman-cloud release pinned in Chart.yaml appVersion. DO NOT EDIT BY HAND.\n'
  printf '# Source: https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/<appVersion>/manifest.yaml\n'
  printf '# Re-vendor via this chart README; bump appVersion in Chart.yaml to match. See docs/13_backups.md.\n---\n'
  curl -fsSL "https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/${VER}/manifest.yaml"
} > templates/plugin-barman-cloud.yaml
```

Then set `appVersion` in `Chart.yaml` to the same tag and push.

Needs CNPG >= 1.26 and cert-manager, hence wave 3.
