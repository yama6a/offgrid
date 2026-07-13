{{/* ingress.referencegrant — in the backend ns, lets the gateway-ns HTTPRoute reach its Service
     cross-namespace (one per host). ctx: {ingress, host}. */}}
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
