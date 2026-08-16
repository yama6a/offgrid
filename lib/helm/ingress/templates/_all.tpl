{{/* ingress.renderIngress: emit ONE ingress's edge, per host a Gateway + HTTPRoute (+ cross-ns
     ReferenceGrant), plus one SAN Certificate. Renders no SSO, that is central per domain in google-sso.
     ctx: {ingress, release}. */}}
{{- define "ingress.renderIngress" -}}
{{- $ing := .ingress -}}
{{- $release := .release -}}
{{- $zones := .cloudflareZones | default (list) -}}
{{- $issuer := $ing.issuer | default (include "ingress.defaultIssuer" .) -}}
{{- if not (has $issuer (list "letsencrypt-staging" "letsencrypt-prod")) }}
{{- fail (printf "ingress: ingress %q uses issuer %q, but only letsencrypt-staging / letsencrypt-prod are allowed (the ClusterIssuers 03_gateway ships)" $ing.name $issuer) }}
{{- end }}
{{- range $h := $ing.hosts }}
{{- $ctx := dict "ingress" $ing "host" $h "release" $release "cloudflareZones" $zones }}
---
{{ include "ingress.gateway" $ctx }}
---
{{ include "ingress.httproute" $ctx }}
{{- /* A ReferenceGrant is only needed for a cross-namespace backend, and a redirect has no backend. */}}
{{- if and (not $h.redirectTo) (ne (include "ingress.backendNs" $ctx) (include "ingress.gatewayNamespace" $ctx)) }}
---
{{ include "ingress.referencegrant" $ctx }}
{{- end }}
{{- end }}
{{- /* Cloudflare domains reuse the shared wildcard cert 03_gateway mints, so they skip their own. */}}
{{- if not (include "ingress.isCloudflare" (dict "ingress" $ing "cloudflareZones" $zones)) }}
---
{{ include "ingress.certificate" (dict "ingress" $ing "cloudflareZones" $zones) }}
{{- end }}
{{- end -}}

{{/* ingress.render: the entry point templates/edge.yaml calls. */}}
{{- define "ingress.render" -}}
{{- $zones := .Values.cloudflareZones | default (list) -}}
{{- range $ing := .Values.ingresses }}
{{- if not $ing.domain }}
{{- fail (printf "ingress: ingress %q has no domain (every ingress must set exactly one registrable domain; hosts give a subdomain under it)" $ing.name) }}
{{- end }}
{{- range $h := $ing.hosts }}
{{- if not $h.subdomain }}
{{- fail (printf "ingress: ingress %q has a host with no subdomain. Set one, or \"@\" for the apex %q" $ing.name $ing.domain) }}
{{- end }}
{{- if or (eq $h.subdomain $ing.domain) (hasSuffix (printf ".%s" $ing.domain) $h.subdomain) }}
{{- fail (printf "ingress: ingress %q host subdomain %q looks like a full hostname. Give just the subdomain under %q (e.g. \"argocd\"), or \"@\" for the apex" $ing.name $h.subdomain $ing.domain) }}
{{- end }}
{{- if and $h.redirectTo $h.targetService }}
{{- fail (printf "ingress: ingress %q host %q sets both redirectTo and targetService. A redirect host answers at the edge and has no backend, so pick one" $ing.name $h.subdomain) }}
{{- end }}
{{- if not (or $h.redirectTo $h.targetService) }}
{{- fail (printf "ingress: ingress %q host %q sets neither targetService nor redirectTo, so nothing would answer it" $ing.name $h.subdomain) }}
{{- end }}
{{- if and $h.targetService (not $h.targetPort) }}
{{- fail (printf "ingress: ingress %q host %q has a targetService but no targetPort" $ing.name $h.subdomain) }}
{{- end }}
{{- end }}
{{ include "ingress.renderIngress" (dict "ingress" $ing "release" $.Release "cloudflareZones" $zones) }}
{{- end }}
{{- end -}}
