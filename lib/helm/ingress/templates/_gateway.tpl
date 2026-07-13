{{/* ingress.gateway — one host's Gateway: a single :443 HTTPS listener terminating TLS with the
     ingress's shared cert (merged onto the one Envoy via mergeGateways). ctx: {ingress, host}. */}}
{{- define "ingress.gateway" -}}
{{- $name := include "ingress.hostName" . -}}
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: {{ $name }}
  namespace: {{ include "ingress.gatewayNamespace" . }}
spec:
  {{- /* gatewayClassName hardcoded (used only here): the Envoy Gateway class from 01_envoy_gateway (mergeGateways -> one LB IP); the cluster has exactly one. */}}
  gatewayClassName: eg
  listeners:
    - name: {{ $name }}
      protocol: HTTPS
      port: 443
      hostname: {{ include "ingress.host" . | quote }}
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: {{ include "ingress.tlsSecret" . | quote }}
      allowedRoutes:
        namespaces:
          from: Same
{{- end -}}
