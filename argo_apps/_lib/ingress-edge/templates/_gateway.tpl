{{/*
ingress-edge.gateway — this host's own Gateway: a single :443 HTTPS listener terminating TLS for the host
with the cert the certificate template mints. Folded onto the cluster's one Envoy + LB IP by mergeGateways
(01_envoy_gateway), so it shares the single ingress point without its own LoadBalancer. In the gateway
namespace so the HTTPRoute (same ns) attaches same-namespace and this ingress's SecurityPolicy selects it
by label. The listener is not-Ready only until cert-manager issues its cert; under merge one host's missing
cert never blocks another. ctx: {cfg, ingress, host}.
*/}}
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
