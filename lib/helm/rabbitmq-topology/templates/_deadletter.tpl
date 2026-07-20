{{/*
rabbitmq-topology.deadletter — the dead-letter companions for one consumer queue: a fanout DLX `<queue>.dlx`
+ a quorum DLQ `<queue>.dlq` + the binding between them. The source queue (declared elsewhere) points its
x-dead-letter-exchange at `<queue>.dlx`. The DLQ is rendered WITHOUT a dlx of its own (no dead-letter loop) and
has no consumer — it's a holding queue you alert on (rabbitmq-dlq-not-empty). ctx + {queue}. See 11_messaging.md.
*/}}
{{- define "rabbitmq-topology.deadletter" -}}
{{- $ctx := .ctx -}}
{{- $dlx := printf "%s.dlx" .queue -}}
{{- $dlq := printf "%s.dlq" .queue -}}
---
{{ include "rabbitmq-topology.exchange" (dict "ctx" $ctx "name" $dlx "type" "fanout") }}
---
{{ include "rabbitmq-topology.queue" (dict "ctx" $ctx "name" $dlq) }}
---
{{ include "rabbitmq-topology.binding" (dict "ctx" $ctx "source" $dlx "destination" $dlq "routingKey" "") }}
{{- end -}}
