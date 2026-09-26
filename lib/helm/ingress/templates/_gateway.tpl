{{/* ingress.gateway: one Gateway per host, with a single HTTPS listener on :443. It terminates TLS with the
     ingress's shared cert. mergeGateways puts every Gateway on the one Envoy.
     Argument: the per-host dict from ingress.renderIngress. */}}
{{- define "ingress.gateway" -}}
{{- $name := include "ingress.hostName" . -}}
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: {{ $name }}
  namespace: {{ include "ingress.gatewayNamespace" . }}
spec:
  {{- /* The one gateway class in the cluster, from 01_envoy_gateway. mergeGateways gives it one LB IP. */}}
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
