{{/* ingress.referencegrant: one per host, in the backend namespace. It lets the HTTPRoute in the gateway
     namespace reach its Service. Argument: the per-host dict from ingress.renderIngress. */}}
{{- define "ingress.referencegrant" -}}
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: gateway-routes-to-{{ include "ingress.hostName" . }}
  namespace: {{ include "ingress.backendNs" . }}
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: {{ include "ingress.gatewayNamespace" . }}
  to:
    - group: ""
      kind: Service
      name: {{ .host.targetService }}
{{- end -}}
