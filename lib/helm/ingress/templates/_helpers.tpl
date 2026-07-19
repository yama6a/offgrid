{{/* ingress helpers — name/secret/issuer derivations + the hardcoded cluster-wiring constants. ctx per
     helper: {ingress, host} as noted (the wiring constants take no ctx). */}}

{{/* Gateway namespace: where every Gateway/Certificate/HTTPRoute lands. Hardcoded — owned by 03_gateway,
     not a per-consumer knob (ReferenceGrants go to the backend ns instead). */}}
{{- define "ingress.gatewayNamespace" -}}gateway{{- end -}}

{{/* Fallback ClusterIssuer when an ingress sets no issuer. Hardcoded to staging so a new ingress can't
     accidentally burn prod (publicly-trusted) rate limits; opt into prod per-ingress via .issuer. */}}
{{- define "ingress.defaultIssuer" -}}letsencrypt-staging{{- end -}}

{{/* Full host: subdomain joined to the ingress domain (argocd + example.com -> argocd.example.com); "@" = apex. ctx: {ingress, host}. */}}
{{- define "ingress.host" -}}
{{- if eq .host.subdomain "@" -}}{{ .ingress.domain }}{{- else -}}{{ printf "%s.%s" .host.subdomain .ingress.domain }}{{- end -}}
{{- end -}}

{{/* Per-host resource name: the FULL host, dots -> dashes (argocd.example.com -> argocd-example-com), so it's unique in the gateway ns. ctx: {ingress, host}. */}}
{{- define "ingress.hostName" -}}
{{- include "ingress.host" . | replace "." "-" -}}
{{- end -}}

{{/* True (non-empty) iff the ingress's domain is served by a shared Cloudflare wildcard cert (its domain is
     in the threaded cloudflareZones). ctx needs {ingress, cloudflareZones}. */}}
{{- define "ingress.isCloudflare" -}}
{{- if has .ingress.domain (.cloudflareZones | default (list)) -}}true{{- end -}}
{{- end -}}

{{/* The ingress's shared TLS Secret. Cloudflare domain -> the CENTRAL wildcard-<domain-dashed>-tls (minted by
     03_gateway, reused by every listener on that tier); otherwise the per-ingress <name>-tls (its own SAN cert
     fills it). ctx: {ingress, cloudflareZones}. */}}
{{- define "ingress.tlsSecret" -}}
{{- if include "ingress.isCloudflare" . -}}
{{- printf "wildcard-%s-tls" (.ingress.domain | replace "." "-") -}}
{{- else -}}
{{- printf "%s-tls" .ingress.name -}}
{{- end -}}
{{- end -}}

{{/* ClusterIssuer for the ingress's cert: .ingress.issuer, else the hardcoded default (ingress.defaultIssuer). ctx: {ingress}. */}}
{{- define "ingress.issuer" -}}
{{- .ingress.issuer | default (include "ingress.defaultIssuer" .) -}}
{{- end -}}

{{/* Backend namespace: explicit .host.targetNamespace, else the consumer's release namespace. ctx needs {release}. */}}
{{- define "ingress.backendNs" -}}
{{- if .host.targetNamespace -}}{{ .host.targetNamespace }}{{- else -}}{{ .release.Namespace }}{{- end -}}
{{- end -}}
