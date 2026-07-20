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
  {{- if .dlx }}
  # Dead-letter poison messages: after x-delivery-limit failed redeliveries the broker routes the message to
  # this queue's DLX ({{ .dlx }} -> <queue>.dlq) instead of dropping it (at-most-once, RabbitMQ's default).
  # IMMUTABLE — changing these needs the queue recreated. DLQs themselves are rendered WITHOUT a dlx (no loop).
  arguments:
    x-dead-letter-exchange: {{ .dlx | quote }}
    x-delivery-limit: {{ .deliveryLimit }}
  {{- end }}
  rabbitmqClusterReference:
    name: {{ $ctx.clusterName }}
    namespace: {{ $ctx.clusterNs }}
{{- end -}}
