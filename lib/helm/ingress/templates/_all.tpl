{{/* ingress.renderIngress — emit ONE ingress's edge: per host a Gateway + HTTPRoute (+ cross-ns
     ReferenceGrant), one SAN Certificate. SSO is NOT here — it's applied centrally per domain by the
     google-sso chart. ctx: {ingress, release}. */}}
{{- define "ingress.renderIngress" -}}
{{- $ing := .ingress -}}
{{- $release := .release -}}
{{- $zones := .cloudflareZones | default (list) -}}
{{- /* Guard: issuer must be a ClusterIssuer 03_gateway ships, else the cert silently never issues. */}}
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
{{- /* ReferenceGrant only for a cross-namespace backend; skip same-ns. */}}
{{- if ne (include "ingress.backendNs" $ctx) (include "ingress.gatewayNamespace" $ctx) }}
---
{{ include "ingress.referencegrant" $ctx }}
{{- end }}
{{- end }}
{{- /* Cloudflare domains reuse the shared wildcard cert minted centrally by 03_gateway; skip the per-ingress
       Certificate. Any other domain keeps its own per-host multi-SAN cert (HTTP-01). */}}
{{- if not (include "ingress.isCloudflare" (dict "ingress" $ing "cloudflareZones" $zones)) }}
---
{{ include "ingress.certificate" (dict "ingress" $ing "cloudflareZones" $zones) }}
{{- end }}
{{- end -}}

{{/* ingress.render — a consumer's entry point (`{{ include "ingress.render" . }}`): validate +
     render each ingress in the consumer's `ingresses[]`. ctx: `.`. */}}
{{- define "ingress.render" -}}
{{- $zones := .Values.ingress.cloudflareZones | default (list) -}}
{{- range $ing := .Values.ingress.ingresses }}
{{- /* Guard: every ingress has one domain; hosts are subdomains under it. */}}
{{- if not $ing.domain }}
{{- fail (printf "ingress: ingress %q has no domain (every ingress must set exactly one registrable domain; hosts give a subdomain under it)" $ing.name) }}
{{- end }}
{{- /* Guard: each host needs a subdomain ("@" = apex); one ending in the domain is a pasted full host. */}}
{{- range $h := $ing.hosts }}
{{- if not $h.subdomain }}
{{- fail (printf "ingress: ingress %q has a host with no subdomain — set one (or \"@\" for the apex %q)" $ing.name $ing.domain) }}
{{- end }}
{{- if or (eq $h.subdomain $ing.domain) (hasSuffix (printf ".%s" $ing.domain) $h.subdomain) }}
{{- fail (printf "ingress: ingress %q host subdomain %q looks like a full hostname — give just the subdomain under %q (e.g. \"argocd\"), or \"@\" for the apex" $ing.name $h.subdomain $ing.domain) }}
{{- end }}
{{- end }}
{{ include "ingress.renderIngress" (dict "ingress" $ing "release" $.Release "cloudflareZones" $zones) }}
{{- end }}
{{- end -}}
