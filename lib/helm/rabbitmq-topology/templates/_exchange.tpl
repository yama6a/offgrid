{{/* rabbitmq-topology.exchange — an exchange this workload owns. ctx + {name, type}. */}}
{{- define "rabbitmq-topology.exchange" -}}
{{- $ctx := .ctx -}}
apiVersion: rabbitmq.com/v1beta1
kind: Exchange
metadata:
  name: {{ .name }}
  namespace: {{ $ctx.ns }}
spec:
  name: {{ .name }}
  type: {{ .type }}
  durable: true          # survives broker restart
  autoDelete: false      # never auto-removed when the last binding/queue detaches
  vhost: {{ $ctx.vhost }}
  rabbitmqClusterReference:
    name: {{ $ctx.clusterName }}
    namespace: {{ $ctx.clusterNs }}
{{- end -}}
