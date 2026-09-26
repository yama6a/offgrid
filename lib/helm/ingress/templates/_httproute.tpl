{{/* ingress.httproute: routes one host to its Service, or redirects it to another host with a 301. The
     google-sso chart applies SSO where it is on, and targets this route by name.
     Argument: the per-host dict from ingress.renderIngress. */}}
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
    # A redirect has no backendRefs. Envoy answers at the edge and no pod is involved. The path and query
    # carry over, because requestRedirect changes only the fields it names.
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
      # Applies to the request to the backend only, never the response. Envoy does not send
      # x-forwarded-port, so a framework that builds absolute URLs from it needs it set here.
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
        request: {{ . | quote }}          # "0s" is off. For backends that hold a response open past Envoy's 15s cutoff
{{- end }}
{{- end }}
{{- end -}}
