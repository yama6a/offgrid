{{/* rabbitmq-topology.queue — a queue this workload owns + consumes. ctx + {name}. */}}
{{- define "rabbitmq-topology.queue" -}}
{{- $ctx := .ctx -}}
apiVersion: rabbitmq.com/v1beta1
kind: Queue
metadata:
  name: {{ .name }}
  namespace: {{ $ctx.ns }}
spec:
  name: {{ .name }}
  type: quorum           # durable, Raft-replicated across the broker nodes; the modern default (classic
                         # mirrored queues are gone in RabbitMQ 4.x). Quorum queues are always durable.
  durable: true
  autoDelete: false
  vhost: {{ $ctx.vhost }}
  rabbitmqClusterReference:
    name: {{ $ctx.clusterName }}
    namespace: {{ $ctx.clusterNs }}
{{- end -}}
