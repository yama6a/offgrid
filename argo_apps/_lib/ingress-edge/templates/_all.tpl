{{/*
ingress-edge.renderIngress — emit the resources for ONE ingress (already-resolved dict {cfg, ingress,
release}): per host a Gateway + HTTPRoute (+ a cross-namespace ReferenceGrant), ONE multi-SAN Certificate,
and — when SSO is enabled — ONE SecurityPolicy. Shared by both entry points (render + callbacks) so the
edge is built in exactly one place. Validates the cert issuer here (applies to every ingress, callbacks
included); the SSO-domain guards live in `render` (they don't apply to the callback hosts themselves).
*/}}
{{- define "ingress-edge.renderIngress" -}}
{{- $cfg := .cfg -}}
{{- $ing := .ingress -}}
{{- $release := .release -}}
{{- /* Guard: the cert issuer must be one of the two Let's Encrypt ClusterIssuers 03_gateway ships. A typo
       would leave the Certificate's issuerRef pointing at a nonexistent ClusterIssuer — never issuing,
       never erroring loudly. Catch it at render instead. */}}
{{- $issuer := $ing.issuer | default $cfg.defaultIssuer -}}
{{- $validIssuers := list "letsencrypt-staging" "letsencrypt-prod" -}}
{{- if not (has $issuer $validIssuers) }}
{{- fail (printf "ingress-edge: ingress %q uses issuer %q, but only %s are allowed (the ClusterIssuers 03_gateway ships)" $ing.name $issuer (join " / " $validIssuers)) }}
{{- end }}
{{- range $h := $ing.hosts }}
{{- $ctx := dict "cfg" $cfg "ingress" $ing "host" $h "release" $release }}
---
{{ include "ingress-edge.gateway" $ctx }}
---
{{ include "ingress-edge.httproute" $ctx }}
{{- /* A ReferenceGrant is only needed for a CROSS-namespace backendRef; skip it when the backend Service
       sits in the same namespace as the route (e.g. the shared callback whoami in the gateway ns). */}}
{{- if ne (include "ingress-edge.backendNs" $ctx) $cfg.gatewayNamespace }}
---
{{ include "ingress-edge.referencegrant" $ctx }}
{{- end }}
{{- end }}
---
{{ include "ingress-edge.certificate" (dict "cfg" $cfg "ingress" $ing) }}
{{- if and $ing.sso $ing.sso.enabled }}
---
{{ include "ingress-edge.securitypolicy" (dict "cfg" $cfg "ingress" $ing) }}
{{- end }}
{{- end -}}

{{/*
ingress-edge.render — the entry point a consumer calls: `{{ include "ingress-edge.render" . }}`. Reads the
`ingress-edge:` block of the consumer's values (the library's own defaults merge under that same key), then
validates + renders each of the consumer's `ingresses[]`. ctx: the root `.`.
*/}}
{{- define "ingress-edge.render" -}}
{{- $le := index .Values "ingress-edge" -}}
{{- $cfg := $le.ingressEdge -}}
{{- /* The domains that have a shared OIDC callback host (04_google_sso stands one up per entry). */}}
{{- $callbackDomains := list -}}
{{- range $cfg.callbackDomains }}{{- $callbackDomains = append $callbackDomains .domain -}}{{- end -}}
{{- range $ing := $le.ingresses }}
{{- /* Guard: every ingress declares exactly ONE registrable domain; each host is a `subdomain` under it
       (so a host is under its domain by construction — no cross-domain check needed). */}}
{{- if not $ing.domain }}
{{- fail (printf "ingress-edge: ingress %q has no domain (every ingress must set exactly one registrable domain; hosts give a subdomain under it)" $ing.name) }}
{{- end }}
{{- /* Guard: each host needs a non-empty subdomain. Use "@" for the apex (the domain itself). A subdomain
       that already ends with the domain is the classic "I put the full host here" mistake. */}}
{{- range $h := $ing.hosts }}
{{- if not $h.subdomain }}
{{- fail (printf "ingress-edge: ingress %q has a host with no subdomain — set one (or \"@\" for the apex %q)" $ing.name $ing.domain) }}
{{- end }}
{{- if or (eq $h.subdomain $ing.domain) (hasSuffix (printf ".%s" $ing.domain) $h.subdomain) }}
{{- fail (printf "ingress-edge: ingress %q host subdomain %q looks like a full hostname — give just the subdomain under %q (e.g. \"argocd\"), or \"@\" for the apex" $ing.name $h.subdomain $ing.domain) }}
{{- end }}
{{- end }}
{{- if and $ing.sso $ing.sso.enabled }}
{{- /* Guard: an SSO ingress's domain must have a callback host, or login redirects to a google-sso.<domain>
       that doesn't exist and the OAuth exchange can never complete (a silent, login-time break). */}}
{{- if not (has $ing.domain $callbackDomains) }}
{{- fail (printf "ingress-edge: SSO ingress %q uses domain=%q, which has no OIDC callback host. Add it to ingressEdge.callbackDomains (07_sso_domains.sh, and register its redirect URI in Google — see 'Adding an SSO domain' in 07_ingress.md), or logins will bounce to a callback that doesn't exist. Known domains: %s" $ing.name $ing.domain (join ", " $callbackDomains)) }}
{{- end }}
{{- /* Guard: an empty allowlist would Deny every login — surely a mistake on a user-facing ingress. */}}
{{- if not $ing.sso.allowlist }}
{{- fail (printf "ingress-edge: SSO ingress %q has an empty allowlist — every login would be denied. Add at least one email, or drop the sso block to leave it open." $ing.name) }}
{{- end }}
{{- end }}
{{ include "ingress-edge.renderIngress" (dict "cfg" $cfg "ingress" $ing "release" $.Release) }}
{{- end }}
{{- end -}}
