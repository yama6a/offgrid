{{/* ingress-edge.httproute — routes one host to its Service. SSO (if any) is applied centrally by the
     google-sso chart, which targetRefs this route by name. ctx: {cfg, ingress, host}. */}}
{{- define "ingress-edge.httproute" -}}
{{- $name := include "ingress-edge.hostName" . -}}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ $name }}
  namespace: {{ .cfg.gatewayNamespace }}
spec:
  parentRefs:
    - name: {{ $name }}                       # this host's own Gateway
      namespace: {{ .cfg.gatewayNamespace }}
      sectionName: {{ $name }}
  hostnames:
    - {{ include "ingress-edge.host" . | quote }}
  rules:
    - backendRefs:
        - name: {{ .host.targetService }}
          namespace: {{ include "ingress-edge.backendNs" . }}
          port: {{ .host.targetPort }}
{{- end -}}
