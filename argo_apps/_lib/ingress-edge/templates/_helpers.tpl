{{/*
ingress-edge helpers. Resource-name / TLS-secret / issuer derivations live here so the per-resource
templates stay declarative. Each helper takes a dict {cfg, ingress, host} (host omitted where unused).
*/}}

{{/* Short name for a host: explicit .host.name, else the first DNS label of .host.host (argocd.x.y -> argocd). */}}
{{- define "ingress-edge.hostName" -}}
{{- $h := .host -}}
{{- if $h.name -}}{{ $h.name }}{{- else -}}{{ splitList "." $h.host | first }}{{- end -}}
{{- end -}}

{{/*
The ingress's ONE shared TLS Secret: explicit .ingress.tlsSecretName, else <ingress.name>-tls. Every host's
Gateway listener references it, and the ingress's single SAN Certificate fills it. ctx needs {ingress}.
*/}}
{{- define "ingress-edge.tlsSecret" -}}
{{- .ingress.tlsSecretName | default (printf "%s-tls" .ingress.name) -}}
{{- end -}}

{{/* cert-manager ClusterIssuer for the ingress's SAN cert: .ingress.issuer, else ingressEdge.defaultIssuer. */}}
{{- define "ingress-edge.issuer" -}}
{{- .ingress.issuer | default .cfg.defaultIssuer -}}
{{- end -}}

{{/* True (non-empty) when this ingress is SSO-protected. */}}
{{- define "ingress-edge.ssoEnabled" -}}
{{- if and .ingress.sso .ingress.sso.enabled -}}true{{- end -}}
{{- end -}}

{{/*
Backend namespace for a host: explicit .host.backend.namespace, else the consumer's release namespace
(the usual case for a workload whose Service lives in its own release namespace). ctx must carry `release`.
*/}}
{{- define "ingress-edge.backendNs" -}}
{{- if .host.backend.namespace -}}{{ .host.backend.namespace }}{{- else -}}{{ .release.Namespace }}{{- end -}}
{{- end -}}
