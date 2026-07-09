{{/* rabbitmq-topology.permission — the ONE per-user permission on the vhost (RabbitMQ has a single
     configure/write/read triple per user+vhost). References the User CR by name via userReference, because
     the username is operator-GENERATED (not known at render time). ctx + {configure, write, read}.
     squote (single quotes) so the escaped-regex backslashes stay literal (YAML double-quotes reject `\.`). */}}
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
    configure: {{ .configure | squote }}
    write: {{ .write | squote }}
    read: {{ .read | squote }}
  rabbitmqClusterReference:
    name: {{ $ctx.clusterName }}
    namespace: {{ $ctx.clusterNs }}
{{- end -}}
