{{- define "rabbitmq-topology.user" -}}
{{- .Values.user | default .Release.Name -}}
{{- end -}}

{{/* The shared-broker reference every CR carries. A platform invariant, identical for every consumer. */}}
{{- define "rabbitmq-topology.clusterRef" -}}
rabbitmqClusterReference:
  name: rabbitmq
  namespace: rabbitmq
{{- end -}}
