{{/* ingress-edge.certificate — ONE multi-SAN Certificate per ingress (a dnsName per host) into the shared
     <name>-tls Secret, issued HTTP-01 via 03_gateway's :80 listener. ctx: {cfg, ingress}. */}}
{{- define "ingress-edge.certificate" -}}
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: {{ .ingress.name }}
  namespace: {{ .cfg.gatewayNamespace }}
spec:
  secretName: {{ include "ingress-edge.tlsSecret" . | quote }}
  dnsNames:
    {{- $ing := .ingress }}
    {{- range $h := .ingress.hosts }}
    - {{ include "ingress-edge.host" (dict "ingress" $ing "host" $h) | quote }}
    {{- end }}
  issuerRef:
    name: {{ include "ingress-edge.issuer" . | quote }}
    kind: ClusterIssuer
{{- end -}}
