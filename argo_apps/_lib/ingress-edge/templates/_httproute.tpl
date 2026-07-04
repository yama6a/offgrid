{{/*
ingress-edge.httproute — routes this host to its in-cluster Service (cross-namespace, via the
ReferenceGrant template). In the gateway namespace so this ingress's SecurityPolicy (also gateway ns)
selects it by the group label. When the ingress is SSO-enabled the route is stamped
`<groupLabelKey>: <ingress.name>`, which is the ONLY thing that opts it into that ingress's Google gate;
an open ingress carries no such label and no policy. ctx: {cfg, ingress, host}.
*/}}
{{- define "ingress-edge.httproute" -}}
{{- $name := include "ingress-edge.hostName" . -}}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ $name }}
  namespace: {{ .cfg.gatewayNamespace }}
  {{- if include "ingress-edge.ssoEnabled" . }}
  labels:
    {{ .cfg.groupLabelKey }}: {{ .ingress.name | quote }}
  {{- end }}
spec:
  parentRefs:
    - name: {{ $name }}                       # this host's own Gateway
      namespace: {{ .cfg.gatewayNamespace }}
      sectionName: {{ $name }}
  hostnames:
    - {{ include "ingress-edge.host" . | quote }}
  rules:
    - backendRefs:
        - name: {{ .host.backend.name }}
          namespace: {{ include "ingress-edge.backendNs" . }}
          port: {{ .host.backend.port }}
{{- end -}}
