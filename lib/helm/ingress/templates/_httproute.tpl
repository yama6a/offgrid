{{/* ingress.httproute — routes one host to its Service. SSO (if any) is applied centrally by the
     google-sso chart, which targetRefs this route by name. ctx: {ingress, host}. */}}
{{- define "ingress.httproute" -}}
{{- $name := include "ingress.hostName" . -}}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ $name }}
  namespace: {{ include "ingress.gatewayNamespace" . }}
spec:
  parentRefs:
    - name: {{ $name }}                       # this host's own Gateway
      namespace: {{ include "ingress.gatewayNamespace" . }}
      sectionName: {{ $name }}
  hostnames:
    - {{ include "ingress.host" . | quote }}
  rules:
    - backendRefs:
        - name: {{ .host.targetService }}
          namespace: {{ include "ingress.backendNs" . }}
          port: {{ .host.targetPort }}
{{- end -}}
