{{/* rabbitmq-topology.permission — the ONE per-user permission on the vhost (RabbitMQ has a single
     configure/write/read triple per user+vhost). References the User CR by name via userReference, because
     the username is operator-GENERATED (not known at render time). ctx + {permissions} — a map of ONLY the
     non-empty fields (see _all.tpl for why empties are omitted). toYaml handles quoting/escaping of the
     regex strings. */}}
{{- define "rabbitmq-topology.permission" -}}
{{- $ctx := .ctx -}}
apiVersion: rabbitmq.com/v1beta1
kind: Permission
metadata:
  name: {{ $ctx.user }}
  namespace: {{ $ctx.ns }}
spec:
  vhost: {{ $ctx.vhost }}
  userReference:
    name: {{ $ctx.user }}
  permissions:
    {{- toYaml .permissions | nindent 4 }}
  rabbitmqClusterReference:
    name: {{ $ctx.clusterName }}
    namespace: {{ $ctx.clusterNs }}
{{- end -}}
