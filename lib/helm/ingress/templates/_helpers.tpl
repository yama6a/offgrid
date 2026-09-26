
{{/* 03_gateway owns this namespace. It is not a per-consumer choice. */}}
{{- define "ingress.gatewayNamespace" -}}gateway{{- end -}}

{{/* Staging is the default, so a new ingress cannot use up the prod rate limits before someone checks it. */}}
{{- define "ingress.defaultIssuer" -}}letsencrypt-staging{{- end -}}

{{/* "@" is the apex. */}}
{{- define "ingress.host" -}}
{{- if eq .host.subdomain "@" -}}{{ .ingress.domain }}{{- else -}}{{ printf "%s.%s" .host.subdomain .ingress.domain }}{{- end -}}
{{- end -}}

{{- define "ingress.hostName" -}}
{{- include "ingress.host" . | replace "." "-" -}}
{{- end -}}

{{- define "ingress.isCloudflare" -}}
{{- if has .ingress.domain (.cloudflareZones | default (list)) -}}true{{- end -}}
{{- end -}}

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
