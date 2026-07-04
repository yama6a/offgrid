{{/*
ingress-edge.callbacks — render the shared OIDC callback host google-sso.<domain> for every entry in
ingressEdge.callbackDomains. Only 04_google_sso calls this (`{{ include "ingress-edge.callbacks" . }}`); it
ships the matching whoami backend + the sealed OAuth secret. Each callback is just an SSO ingress whose one
host IS google-sso.<domain> and whose redirectURL therefore derives to itself — so its SecurityPolicy is
what completes the OAuth token exchange and sets the domain-scoped session cookie. No allowlist (the whoami
is deny-all except the intercepted /oauth2/callback path). ctx: the root `.`.
*/}}
{{- define "ingress-edge.callbacks" -}}
{{- $le := index .Values "ingress-edge" -}}
{{- $cfg := $le.ingressEdge -}}
{{- range $cd := $cfg.callbackDomains }}
{{- $slug := $cd.domain | replace "." "-" -}}
{{- /* Host is authSubdomain.<domain> (e.g. google-sso.example.com); backend is the shared whoami Service
       04_google_sso ships (name fixed by that chart), same namespace. No allowlist -> deny-all. */}}
{{- $ing := dict
      "name" (printf "google-sso-%s" $slug)
      "domain" $cd.domain
      "issuer" $cd.issuer
      "sso" (dict "enabled" true)
      "hosts" (list (dict "subdomain" $cfg.oidc.authSubdomain "backend" (dict "name" "gateway-sso-callback" "namespace" $cfg.gatewayNamespace "port" 80))) -}}
{{ include "ingress-edge.renderIngress" (dict "cfg" $cfg "ingress" $ing "release" $.Release) }}
{{- end }}
{{- end -}}
