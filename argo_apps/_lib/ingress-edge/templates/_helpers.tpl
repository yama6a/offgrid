{{/*
ingress-edge helpers. Resource-name / TLS-secret / issuer derivations live here so the per-resource
templates stay declarative. Each helper takes a dict {cfg, ingress, host} (host omitted where unused).
*/}}

{{/*
Full hostname for a host: the host's `subdomain` joined onto the ingress `domain` with a dot
(argocd + example.com -> argocd.example.com). The sentinel `subdomain: "@"` means the apex (the domain
itself), the DNS-registrar convention. ctx: {ingress, host}.
*/}}
{{- define "ingress-edge.host" -}}
{{- if eq .host.subdomain "@" -}}{{ .ingress.domain }}{{- else -}}{{ printf "%s.%s" .host.subdomain .ingress.domain }}{{- end -}}
{{- end -}}

{{/*
Per-host resource name (Gateway / listener / HTTPRoute / ReferenceGrant), the full hostname with dots ->
dashes: argocd.example.com -> argocd-example-com. The FULL host is used (not just the subdomain) so hosts
that share a subdomain across domains stay unique in the shared gateway namespace (google-sso.example.com
-> google-sso-example-com vs google-sso.yama.casa -> google-sso-yama-casa). ctx: {ingress, host}.
*/}}
{{- define "ingress-edge.hostName" -}}
{{- include "ingress-edge.host" . | replace "." "-" -}}
{{- end -}}

{{/*
The ingress's ONE shared TLS Secret: <ingress.name>-tls. Every host's Gateway listener references it, and
the ingress's single SAN Certificate fills it. ctx needs {ingress}.
*/}}
{{- define "ingress-edge.tlsSecret" -}}
{{- printf "%s-tls" .ingress.name -}}
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
