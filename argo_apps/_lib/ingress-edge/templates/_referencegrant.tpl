{{/* ingress-edge.referencegrant — in the backend ns, lets the gateway-ns HTTPRoute reach its Service
     cross-namespace (one per host). ctx: {cfg, ingress, host}. */}}
{{- define "ingress-edge.referencegrant" -}}
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: gateway-routes-to-{{ include "ingress-edge.hostName" . }}
  namespace: {{ include "ingress-edge.backendNs" . }}
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: {{ .cfg.gatewayNamespace }}
  to:
    - group: ""
      kind: Service
      name: {{ .host.targetService }}
{{- end -}}
