{{/* ingress-edge helpers — name/secret/issuer derivations. ctx per helper: {cfg, ingress, host} as noted. */}}

{{/* Full host: subdomain joined to the ingress domain (argocd + example.com -> argocd.example.com); "@" = apex. ctx: {ingress, host}. */}}
{{- define "ingress-edge.host" -}}
{{- if eq .host.subdomain "@" -}}{{ .ingress.domain }}{{- else -}}{{ printf "%s.%s" .host.subdomain .ingress.domain }}{{- end -}}
{{- end -}}

{{/* Per-host resource name: the FULL host, dots -> dashes (argocd.example.com -> argocd-example-com), so it's unique in the gateway ns. ctx: {ingress, host}. */}}
{{- define "ingress-edge.hostName" -}}
{{- include "ingress-edge.host" . | replace "." "-" -}}
{{- end -}}

{{/* The ingress's one shared TLS Secret (its SAN cert fills it, every listener references it). ctx: {ingress}. */}}
{{- define "ingress-edge.tlsSecret" -}}
{{- printf "%s-tls" .ingress.name -}}
{{- end -}}

{{/* ClusterIssuer for the ingress's cert: .ingress.issuer, else ingressEdge.defaultIssuer. */}}
{{- define "ingress-edge.issuer" -}}
{{- .ingress.issuer | default .cfg.defaultIssuer -}}
{{- end -}}

{{/* Backend namespace: explicit .host.targetNamespace, else the consumer's release namespace. ctx needs {release}. */}}
{{- define "ingress-edge.backendNs" -}}
{{- if .host.targetNamespace -}}{{ .host.targetNamespace }}{{- else -}}{{ .release.Namespace }}{{- end -}}
{{- end -}}
