# 03_barman_cloud_plugin

Vendors the [CloudNativePG Barman Cloud CNPG-I plugin](https://github.com/cloudnative-pg/plugin-barman-cloud)
release manifest (there is no upstream Helm chart yet, so we can't pin it as a dependency — see Chart.yaml).

`templates/plugin-barman-cloud.yaml` is the upstream `manifest.yaml` **verbatim** (it contains no Go-template
braces, so Helm renders it unchanged). It installs into `cnpg-system` the `ObjectStore` CRD, the plugin
Deployment/Service/RBAC, and its cert-manager Issuer + Certificates.

## Bump the pinned version

```sh
VER=v0.13.0   # <- set the new release tag
{
  printf '# Vendored VERBATIM from the plugin-barman-cloud %s release — DO NOT EDIT BY HAND.\n' "$VER"
  printf '# Source: https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/%s/manifest.yaml\n' "$VER"
  printf '# Re-vendor via this chart README; bump appVersion in Chart.yaml to match. See docs/13_backups.md.\n---\n'
  curl -fsSL "https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/${VER}/manifest.yaml"
} > templates/plugin-barman-cloud.yaml
```

Then set `appVersion` in `Chart.yaml` to the same tag, commit + push. Requires CNPG ≥ 1.26 (we run 1.29.x)
and cert-manager (platform wave 2), which is why this app is wave 3.
