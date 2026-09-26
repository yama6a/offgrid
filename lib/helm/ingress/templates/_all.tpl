{{/* Argument: a dict with ingress, release and cloudflareZones. SSO comes from google-sso, once per domain. */}}
{{- define "ingress.renderIngress" -}}
{{- $ing := .ingress -}}
{{- $release := .release -}}
{{- $zones := .cloudflareZones | default (list) -}}
{{- $issuer := $ing.issuer | default (include "ingress.defaultIssuer" .) -}}
{{- if not (has $issuer (list "letsencrypt-staging" "letsencrypt-prod")) }}
{{- fail (printf "ingress: ingress %q uses issuer %q. Only letsencrypt-staging and letsencrypt-prod exist, the two ClusterIssuers that 03_gateway ships" $ing.name $issuer) }}
{{- end }}
{{- range $h := $ing.hosts }}
{{- $ctx := dict "ingress" $ing "host" $h "release" $release "cloudflareZones" $zones }}
---
{{ include "ingress.gateway" $ctx }}
---
{{ include "ingress.httproute" $ctx }}
{{- /* Only a backend in another namespace needs a ReferenceGrant. A redirect has no backend. */}}
{{- if and (not $h.redirectTo) (ne (include "ingress.backendNs" $ctx) (include "ingress.gatewayNamespace" $ctx)) }}
---
{{ include "ingress.referencegrant" $ctx }}
{{- end }}
{{- end }}
{{- /* A Cloudflare domain uses the shared wildcard cert from 03_gateway, so it gets no Certificate of its own. */}}
{{- if not (include "ingress.isCloudflare" (dict "ingress" $ing "cloudflareZones" $zones)) }}
---
{{ include "ingress.certificate" (dict "ingress" $ing "cloudflareZones" $zones) }}
{{- end }}
{{- end -}}

{{- define "ingress.render" -}}
{{- $zones := .Values.cloudflareZones | default (list) -}}
{{- range $ing := .Values.ingresses }}
{{- if not $ing.domain }}
{{- fail (printf "ingress: ingress %q has no domain. Every ingress sets exactly one registrable domain, and each host gives a subdomain under it" $ing.name) }}
{{- end }}
{{- range $h := $ing.hosts }}
{{- if not $h.subdomain }}
{{- fail (printf "ingress: ingress %q has a host with no subdomain. Set one, or \"@\" for the apex %q" $ing.name $ing.domain) }}
{{- end }}
{{- if or (eq $h.subdomain $ing.domain) (hasSuffix (printf ".%s" $ing.domain) $h.subdomain) }}
{{- fail (printf "ingress: ingress %q host subdomain %q looks like a full hostname. Give only the subdomain under %q, for example \"argocd\", or \"@\" for the apex" $ing.name $h.subdomain $ing.domain) }}
{{- end }}
{{- if and $h.redirectTo $h.targetService }}
{{- fail (printf "ingress: ingress %q host %q sets both redirectTo and targetService. A redirect host answers at the edge and has no backend. Set only one" $ing.name $h.subdomain) }}
{{- end }}
{{- if not (or $h.redirectTo $h.targetService) }}
{{- fail (printf "ingress: ingress %q host %q sets neither targetService nor redirectTo, so nothing would answer it" $ing.name $h.subdomain) }}
{{- end }}
{{- if and $h.targetService (not $h.targetPort) }}
{{- fail (printf "ingress: ingress %q host %q has a targetService but no targetPort" $ing.name $h.subdomain) }}
{{- end }}
{{- if and $h.redirectTo $h.requestHeaders }}
{{- fail (printf "ingress: ingress %q host %q sets requestHeaders on a redirect host. A redirect forwards nothing to a backend, so the headers would go nowhere" $ing.name $h.subdomain) }}
{{- end }}
{{- end }}
{{ include "ingress.renderIngress" (dict "ingress" $ing "release" $.Release "cloudflareZones" $zones) }}
{{- end }}
{{- end -}}
