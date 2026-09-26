{{/* google-sso.domains: the base domain plus extraDomains, one entry per SecurityPolicy. A define returns
     only a string, so read it back with `fromYamlArray (include "google-sso.domains" .)`. */}}
{{- define "google-sso.domains" -}}
{{- $out := list (dict
      "domain" (required "domain is required. 04_values.sh writes it from BASE_DOMAIN in .env" .Values.domain)
      "issuer" .Values.issuer
      "hosts" (.Values.hosts | default (list))
      "claimToHeaders" (.Values.claimToHeaders | default (list))) -}}
{{- range $d := (.Values.extraDomains | default (list)) -}}
{{- $out = append $out (dict
      "domain" ($d.domain | default "")
      "issuer" ($d.issuer | default $.Values.issuer)
      "hosts" ($d.hosts | default (list))
      "claimToHeaders" ($d.claimToHeaders | default (list))) -}}
{{- end -}}
{{- $out | toYaml -}}
{{- end -}}
