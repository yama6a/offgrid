{{/* ingress.httproute: routes one host to its Service, or 301s it to another host. SSO (if any) is
     applied centrally by the google-sso chart, which targetRefs this route by name. ctx: {ingress, host}. */}}
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
{{- if .host.redirectTo }}
    # Redirect-only, so no backendRefs: Envoy answers at the edge and no pod is involved. The path and
    # query carry over untouched, since requestRedirect rewrites nothing it is not told to.
    - filters:
        - type: RequestRedirect
          requestRedirect:
            hostname: {{ .host.redirectTo | quote }}
            statusCode: 301
{{- else }}
    - backendRefs:
        - name: {{ .host.targetService }}
          namespace: {{ include "ingress.backendNs" . }}
          port: {{ .host.targetPort }}
{{- with .host.requestTimeout }}
      timeouts:
        request: {{ . | quote }}          # "0s" = off; for backends that hold a response open (Envoy cuts at 15s -> 504)
{{- end }}
{{- end }}
{{- end -}}
