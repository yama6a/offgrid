{{/* ingress.certificate — ONE multi-SAN Certificate per ingress (a dnsName per host) into the shared
     <name>-tls Secret, issued HTTP-01 via 03_gateway's :80 listener. ctx: {ingress}. */}}
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
