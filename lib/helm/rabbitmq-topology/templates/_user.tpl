{{/* rabbitmq-topology.user — this workload's single User. ctx: {user, ns, clusterName, clusterNs}. */}}
{{- define "rabbitmq-topology.user" -}}
{{- $ctx := .ctx -}}
apiVersion: rabbitmq.com/v1beta1
kind: User
metadata:
  name: {{ $ctx.user }}
  namespace: {{ $ctx.ns }}
spec:
  # No tags -> a plain application user (no management-UI / admin rights; it uses AMQP, not the UI).
  # importCredentialsSecret is OMITTED, so the operator GENERATES a random username + password into the Secret
  # `{{ $ctx.user }}-user-credentials` in this namespace (keys `username`/`password`); the workload pod mounts
  # it. Nothing secret is committed to git — same model as CNPG's `<db>-app`. See 11_messaging.md / 06_secrets.md.
  rabbitmqClusterReference:
    name: {{ $ctx.clusterName }}
    namespace: {{ $ctx.clusterNs }}
{{- end -}}
