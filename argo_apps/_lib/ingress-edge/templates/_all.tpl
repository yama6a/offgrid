{{/*
ingress-edge.render — the one entry point a consumer calls: `{{ include "ingress-edge.render" . }}`.

Reads EVERYTHING from the `ingress-edge:` block of the consumer's values (`.Values["ingress-edge"]`).
Helm coalesces this library's own values.yaml under that same dependency-name key, so the shared
`ingressEdge:` config (clientID, cookie, TTLs, ...) flows to every consumer from ONE place (the library
values.yaml) while each consumer supplies its own `ingresses:` list under `ingress-edge:` — the repo's
usual "config nested under the dependency name" convention (cf. grafana:/cluster:).

Per host it emits Gateway + Certificate + HTTPRoute + ReferenceGrant; per SSO-enabled ingress ONE
SecurityPolicy (after its hosts, so the routes it targets already exist in the same manifest).
ctx: the root `.`.
*/}}
{{- define "ingress-edge.render" -}}
{{- $le := index .Values "ingress-edge" -}}
{{- $cfg := $le.ingressEdge -}}
{{- range $ing := $le.ingresses }}
{{- /* Guard: an SSO ingress is single-registrable-domain by construction — cookieDomain and the shared
       google-sso.<domain> callback are per registrable domain, so a session issued for one domain is
       useless on another. Reject an SSO ingress that names a domain but whose hosts aren't all under it,
       rather than silently shipping hosts that can never authenticate. (Open ingresses may span domains.) */}}
{{- if and $ing.sso $ing.sso.enabled }}
{{- $domain := $ing.sso.domain | default "" }}
{{- if not $domain }}
{{- fail (printf "ingress-edge: SSO ingress %q has sso.enabled but no sso.domain" $ing.name) }}
{{- end }}
{{- $suffix := printf ".%s" $domain }}
{{- range $h := $ing.hosts }}
{{- if not (or (eq $h.host $domain) (hasSuffix $suffix $h.host)) }}
{{- fail (printf "ingress-edge: SSO ingress %q sets sso.domain=%q but host %q is not under it; an SSO ingress can't span registrable domains (cookieDomain + the shared callback host are per domain). Split it into one ingress per domain, or drop the sso block to leave it open." $ing.name $domain $h.host) }}
{{- end }}
{{- end }}
{{- end }}
{{- range $h := $ing.hosts }}
{{- $ctx := dict "cfg" $cfg "ingress" $ing "host" $h "release" $.Release }}
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
{{- end }}
{{- end -}}
