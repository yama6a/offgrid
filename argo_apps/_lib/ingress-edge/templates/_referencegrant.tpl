{{/*
ingress-edge.referencegrant — lets this host's HTTPRoute (in the gateway namespace) reference its Service
in the backend namespace. Cross-namespace backendRefs require a ReferenceGrant in the BACKEND's namespace.
One per host (named for the host); several hosts in the same backend ns each get their own grant, which is
fine (multiple grants coexist). ctx: {cfg, ingress, host}.
*/}}
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
      name: {{ .host.backend.name }}
{{- end -}}
