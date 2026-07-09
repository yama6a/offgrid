{{/* rabbitmq-topology.binding — binds a queue to an exchange. ctx + {source, destination, routingKey}. Named
     after the destination queue (each queue is bound exactly once in this model, so that's unique). */}}
{{- define "rabbitmq-topology.binding" -}}
{{- $ctx := .ctx -}}
apiVersion: rabbitmq.com/v1beta1
kind: Binding
metadata:
  name: {{ .destination }}
  namespace: {{ $ctx.ns }}
spec:
  source: {{ .source }}            # the exchange
  destination: {{ .destination }}  # the queue
  destinationType: queue
  routingKey: {{ .routingKey | quote }}
  vhost: {{ $ctx.vhost }}
  rabbitmqClusterReference:
    name: {{ $ctx.clusterName }}
    namespace: {{ $ctx.clusterNs }}
{{- end -}}
