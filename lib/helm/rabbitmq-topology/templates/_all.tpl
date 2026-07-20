{{/*
rabbitmq-topology.render — a workload's entry point (`{{ include "rabbitmq-topology.render" . }}`). Renders
this workload's messaging topology against the shared broker: exactly one User (generated creds), the
Exchanges/Queues/Bindings it owns, and ONE aggregated Permission for that user. Config lives under the
`rabbitmq-topology` values key (has a dash, so read via `index`). The command/event ownership model is in
11_messaging.md; the per-resource CRs are the sibling _*.tpl files.

Permission aggregation: `write` = every exchange this workload publishes to (publishEvents it owns +
sendCommands it targets); `read` = every queue it consumes (its command queues + its per-subscription event
queues). `configure` stays "" — the operator's admin user declares all topology, so the app user needs none.
Regex metachars (`.` in the auto queue names) are escaped so a name matches only itself.
*/}}
{{- define "rabbitmq-topology.render" -}}
{{- $cfg := index .Values "rabbitmq-topology" -}}
{{- /* Broker + vhost are platform invariants (03_rabbitmq_cluster: cluster `rabbitmq`/ns `rabbitmq`, vhost `apps`),
       identical for every consumer -> hardcoded, not a value. Reject an override so a stray key can't silently drift. */ -}}
{{- if or (hasKey $cfg "cluster") (hasKey $cfg "vhost") }}{{ fail "rabbitmq-topology: `cluster`/`vhost` are fixed platform invariants (broker `rabbitmq`/ns `rabbitmq`, vhost `apps`), not configurable; remove them" }}{{ end }}
{{- $user := $cfg.user | default .Release.Name -}}
{{- /* Dead-letter (DLQ) config: default ON; `default` can't be used (it swallows an explicit false), so key-check. */ -}}
{{- $deadLetter := true -}}{{- if hasKey $cfg "deadLetter" }}{{- $deadLetter = $cfg.deadLetter -}}{{- end -}}
{{- $deliveryLimit := $cfg.deliveryLimit | default 5 -}}
{{- $ctx := dict "user" $user "vhost" "apps" "clusterName" "rabbitmq" "clusterNs" "rabbitmq" "ns" .Release.Namespace "deadLetter" $deadLetter "deliveryLimit" $deliveryLimit -}}
{{- $writeSet := list -}}
{{- $readSet := list -}}
---
{{ include "rabbitmq-topology.user" (dict "ctx" $ctx) }}
{{- range $e := ($cfg.publishEvents | default list) }}
{{- if not $e.name }}{{ fail "rabbitmq-topology: every publishEvents entry needs a name (the event exchange this workload owns)" }}{{ end }}
{{- if not $e.type }}{{ fail "rabbitmq-topology: every publishEvents entry needs a type (topic | fanout | direct | headers)" }}{{ end }}
---
{{ include "rabbitmq-topology.exchange" (dict "ctx" $ctx "name" $e.name "type" $e.type) }}
{{- $writeSet = append $writeSet $e.name }}
{{- end }}
{{- range $c := ($cfg.consumeCommands | default list) }}
{{- if not $c.name }}{{ fail "rabbitmq-topology: every consumeCommands entry needs a name (the command exchange+queue this workload owns)" }}{{ end }}
{{- if hasKey $c "type" }}{{ fail "rabbitmq-topology: consumeCommands entries are always a direct exchange (command topics are point-to-point, N publishers : 1 consumer); remove `type`" }}{{ end }}
---
{{ include "rabbitmq-topology.exchange" (dict "ctx" $ctx "name" $c.name "type" "direct") }}
---
{{ include "rabbitmq-topology.queue" (dict "ctx" $ctx "name" $c.name "dlx" (ternary (printf "%s.dlx" $c.name) "" $ctx.deadLetter) "deliveryLimit" $ctx.deliveryLimit) }}
---
{{ include "rabbitmq-topology.binding" (dict "ctx" $ctx "source" $c.name "destination" $c.name "routingKey" ($c.routingKey | default $c.name)) }}
{{- if $ctx.deadLetter }}
{{ include "rabbitmq-topology.deadletter" (dict "ctx" $ctx "queue" $c.name) }}
{{- end }}
{{- $readSet = append $readSet $c.name }}
{{- end }}
{{- range $s := ($cfg.subscribeEvents | default list) }}
{{- if not $s.exchange }}{{ fail "rabbitmq-topology: every subscribeEvents entry needs an exchange (the event topic to subscribe to; its owner declares it)" }}{{ end }}
{{- $qname := printf "%s.%s" $user $s.exchange }}
---
{{ include "rabbitmq-topology.queue" (dict "ctx" $ctx "name" $qname "dlx" (ternary (printf "%s.dlx" $qname) "" $ctx.deadLetter) "deliveryLimit" $ctx.deliveryLimit) }}
---
{{ include "rabbitmq-topology.binding" (dict "ctx" $ctx "source" $s.exchange "destination" $qname "routingKey" ($s.routingKey | default "#")) }}
{{- if $ctx.deadLetter }}
{{ include "rabbitmq-topology.deadletter" (dict "ctx" $ctx "queue" $qname) }}
{{- end }}
{{- $readSet = append $readSet $qname }}
{{- end }}
{{- range $x := ($cfg.sendCommands | default list) }}
{{- $writeSet = append $writeSet $x }}
{{- end }}
{{- /* Build the aggregated permission regexes (metachars escaped). There is no configure field and no override
       hook: the operator's admin user declares ALL topology, so an app user is NEVER granted create/delete. */ -}}
{{- $writeEsc := list -}}{{- range $w := $writeSet }}{{ $writeEsc = append $writeEsc (replace "." "\\." $w) }}{{- end -}}
{{- $readEsc := list -}}{{- range $r := $readSet }}{{ $readEsc = append $readEsc (replace "." "\\." $r) }}{{- end -}}
{{- $write := ternary (printf "^(%s)$" (join "|" $writeEsc)) "" (gt (len $writeSet) 0) -}}
{{- $read := ternary (printf "^(%s)$" (join "|" $readEsc)) "" (gt (len $readSet) 0) -}}
{{- /* Emit ONLY the non-empty permission fields. RabbitMQ treats a missing field as "" (no access), and the
       topology operator drops empty strings from the stored object — so a pure event-consumer (write="") or a
       pure publisher (read="") that declared an empty field would leave ArgoCD owning a field the live object
       lacks, holding the Permission permanently OutOfSync. Omitting empties makes the manifest match what the
       operator stores. */ -}}
{{- $perms := dict -}}
{{- if $write }}{{ $perms = set $perms "write" $write }}{{ end -}}
{{- if $read }}{{ $perms = set $perms "read" $read }}{{ end }}
---
{{ include "rabbitmq-topology.permission" (dict "ctx" $ctx "permissions" $perms) }}
{{- end -}}
