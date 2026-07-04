{{/* ingress-edge.renderIngress — emit ONE ingress's edge: per host a Gateway + HTTPRoute (+ cross-ns
     ReferenceGrant), one SAN Certificate. SSO is NOT here — it's applied centrally per domain by the
     google-sso chart. ctx: {cfg, ingress, release}. */}}
{{- define "ingress-edge.renderIngress" -}}
{{- $cfg := .cfg -}}
{{- $ing := .ingress -}}
{{- $release := .release -}}
{{- /* Guard: issuer must be a ClusterIssuer 03_gateway ships, else the cert silently never issues. */}}
{{- $issuer := $ing.issuer | default $cfg.defaultIssuer -}}
{{- if not (has $issuer (list "letsencrypt-staging" "letsencrypt-prod")) }}
{{- fail (printf "ingress-edge: ingress %q uses issuer %q, but only letsencrypt-staging / letsencrypt-prod are allowed (the ClusterIssuers 03_gateway ships)" $ing.name $issuer) }}
{{- end }}
{{- range $h := $ing.hosts }}
{{- $ctx := dict "cfg" $cfg "ingress" $ing "host" $h "release" $release }}
---
{{ include "ingress-edge.gateway" $ctx }}
---
{{ include "ingress-edge.httproute" $ctx }}
{{- /* ReferenceGrant only for a cross-namespace backend; skip same-ns. */}}
{{- if ne (include "ingress-edge.backendNs" $ctx) $cfg.gatewayNamespace }}
---
{{ include "ingress-edge.referencegrant" $ctx }}
{{- end }}
{{- end }}
---
{{ include "ingress-edge.certificate" (dict "cfg" $cfg "ingress" $ing) }}
{{- end -}}

{{/* ingress-edge.render — a consumer's entry point (`{{ include "ingress-edge.render" . }}`): validate +
     render each ingress in the consumer's `ingresses[]`. ctx: `.`. */}}
{{- define "ingress-edge.render" -}}
{{- $le := index .Values "ingress-edge" -}}
{{- $cfg := $le.ingressEdge -}}
{{- range $ing := $le.ingresses }}
{{- /* Guard: every ingress has one domain; hosts are subdomains under it. */}}
{{- if not $ing.domain }}
{{- fail (printf "ingress-edge: ingress %q has no domain (every ingress must set exactly one registrable domain; hosts give a subdomain under it)" $ing.name) }}
{{- end }}
{{- /* Guard: each host needs a subdomain ("@" = apex); one ending in the domain is a pasted full host. */}}
{{- range $h := $ing.hosts }}
{{- if not $h.subdomain }}
{{- fail (printf "ingress-edge: ingress %q has a host with no subdomain — set one (or \"@\" for the apex %q)" $ing.name $ing.domain) }}
{{- end }}
{{- if or (eq $h.subdomain $ing.domain) (hasSuffix (printf ".%s" $ing.domain) $h.subdomain) }}
{{- fail (printf "ingress-edge: ingress %q host subdomain %q looks like a full hostname — give just the subdomain under %q (e.g. \"argocd\"), or \"@\" for the apex" $ing.name $h.subdomain $ing.domain) }}
{{- end }}
{{- end }}
{{ include "ingress-edge.renderIngress" (dict "cfg" $cfg "ingress" $ing "release" $.Release) }}
{{- end }}
{{- end -}}
