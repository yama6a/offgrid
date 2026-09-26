{{- define "rabbitmq-topology.user" -}}
{{- .Values.user | default .Release.Name -}}
{{- end -}}

{{/* The shared broker that every CR references. It is the same for every consumer. */}}
{{- define "rabbitmq-topology.clusterRef" -}}
rabbitmqClusterReference:
  name: rabbitmq
  namespace: rabbitmq
{{- end -}}
