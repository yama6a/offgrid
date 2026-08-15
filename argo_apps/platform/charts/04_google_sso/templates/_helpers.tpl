{{/* google-sso.domains: base domain + extraDomains, one entry per SecurityPolicy. Read back with
     `fromYamlArray (include "google-sso.domains" .)`, since a define can only return a string. */}}
{{- define "google-sso.domains" -}}
{{- $out := list (dict
      "domain" (required "domain is required (04_values.sh writes it from .env BASE_DOMAIN)" .Values.domain)
      "issuer" .Values.issuer
      "hosts" (.Values.hosts | default (list))) -}}
{{- range $d := (.Values.extraDomains | default (list)) -}}
{{- $out = append $out (dict
      "domain" ($d.domain | default "")
      "issuer" ($d.issuer | default $.Values.issuer)
      "hosts" ($d.hosts | default (list))) -}}
{{- end -}}
{{- $out | toYaml -}}
{{- end -}}
