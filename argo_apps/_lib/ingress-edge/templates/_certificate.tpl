{{/*
ingress-edge.certificate — ONE cert-manager Certificate for the whole ingress: a single multi-SAN cert
listing every host, issued (HTTP-01 via the shared :80 listener from 03_gateway) into the ONE shared Secret
all of this ingress's Gateway listeners reference. In the gateway namespace. Issuer is STAGING by default;
flip the ingress's `issuer` to letsencrypt-prod once it issues (browser-facing hosts want a trusted cert).
ctx: {cfg, ingress}.
*/}}
{{- define "ingress-edge.certificate" -}}
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {{ .ingress.name }}
  namespace: {{ .cfg.gatewayNamespace }}
spec:
  secretName: {{ include "ingress-edge.tlsSecret" . | quote }}
  dnsNames:
    {{- range .ingress.hosts }}
    - {{ .host | quote }}
    {{- end }}
  issuerRef:
    name: {{ include "ingress-edge.issuer" . | quote }}
    kind: ClusterIssuer
{{- end -}}
