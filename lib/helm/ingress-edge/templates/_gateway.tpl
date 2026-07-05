{{/* ingress-edge.gateway — one host's Gateway: a single :443 HTTPS listener terminating TLS with the
     ingress's shared cert (merged onto the one Envoy via mergeGateways). ctx: {cfg, ingress, host}. */}}
{{- define "ingress-edge.gateway" -}}
{{- $name := include "ingress-edge.hostName" . -}}
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: {{ $name }}
  namespace: {{ .cfg.gatewayNamespace }}
spec:
  gatewayClassName: {{ .cfg.gatewayClassName }}
  listeners:
    - name: {{ $name }}
      protocol: HTTPS
      port: 443
      hostname: {{ include "ingress-edge.host" . | quote }}
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: {{ include "ingress-edge.tlsSecret" . | quote }}
      allowedRoutes:
        namespaces:
          from: Same
{{- end -}}
