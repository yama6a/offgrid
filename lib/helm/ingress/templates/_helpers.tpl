
{{/* Hardcoded: owned by 03_gateway, not a per-consumer choice. */}}
{{- define "ingress.gatewayNamespace" -}}gateway{{- end -}}

{{/* Defaults to staging, so a new ingress cannot burn prod rate limits before it is verified. */}}
{{- define "ingress.defaultIssuer" -}}letsencrypt-staging{{- end -}}

{{/* Full host: subdomain joined to the ingress domain. "@" means the apex. */}}
{{- define "ingress.host" -}}
{{- if eq .host.subdomain "@" -}}{{ .ingress.domain }}{{- else -}}{{ printf "%s.%s" .host.subdomain .ingress.domain }}{{- end -}}
{{- end -}}

{{/* Per-host resource name: the full host with dots turned to dashes, unique in the gateway namespace. */}}
{{- define "ingress.hostName" -}}
{{- include "ingress.host" . | replace "." "-" -}}
{{- end -}}

{{/* Non-empty when the ingress's domain is served by a shared Cloudflare wildcard cert. */}}
{{- define "ingress.isCloudflare" -}}
{{- if has .ingress.domain (.cloudflareZones | default (list)) -}}true{{- end -}}
{{- end -}}

{{/* The ingress's shared TLS Secret: the central wildcard for a Cloudflare domain, else its own. */}}
{{- define "ingress.tlsSecret" -}}
{{- if include "ingress.isCloudflare" . -}}
{{- printf "wildcard-%s-tls" (.ingress.domain | replace "." "-") -}}
{{- else -}}
{{- printf "%s-tls" .ingress.name -}}
{{- end -}}
{{- end -}}

{{- define "ingress.issuer" -}}
{{- .ingress.issuer | default (include "ingress.defaultIssuer" .) -}}
{{- end -}}

{{- define "ingress.backendNs" -}}
{{- if .host.targetNamespace -}}{{ .host.targetNamespace }}{{- else -}}{{ .release.Namespace }}{{- end -}}
{{- end -}}
