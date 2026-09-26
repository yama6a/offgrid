{{/* HTTP-01 runs through the :80 listener of 03_gateway. Argument: a dict with ingress and cloudflareZones. */}}
{{- define "ingress.certificate" -}}
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {{ .ingress.name }}
  namespace: {{ include "ingress.gatewayNamespace" . }}
spec:
  secretName: {{ include "ingress.tlsSecret" . | quote }}
  dnsNames:
    {{- $ing := .ingress }}
    {{- range $h := .ingress.hosts }}
    - {{ include "ingress.host" (dict "ingress" $ing "host" $h) | quote }}
    {{- end }}
  issuerRef:
    name: {{ include "ingress.issuer" . | quote }}
    kind: ClusterIssuer
{{- end -}}
