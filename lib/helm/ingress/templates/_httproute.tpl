{{/* google-sso targets this route by name. Argument: the per-host dict. */}}
{{- define "ingress.httproute" -}}
{{- $name := include "ingress.hostName" . -}}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ $name }}
  namespace: {{ include "ingress.gatewayNamespace" . }}
spec:
  parentRefs:
    - name: {{ $name }}
      namespace: {{ include "ingress.gatewayNamespace" . }}
      sectionName: {{ $name }}
  hostnames:
    - {{ include "ingress.host" . | quote }}
  rules:
{{- if .host.redirectTo }}
    # requestRedirect changes only the fields it names, so path and query carry over.
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
{{- with .host.requestHeaders }}
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            set:
{{- range $name, $value := . }}
              - name: {{ $name | quote }}
                value: {{ $value | quote }}
{{- end }}
{{- end }}
{{- with .host.requestTimeout }}
      timeouts:
        request: {{ . | quote }}
{{- end }}
{{- end }}
{{- end -}}
