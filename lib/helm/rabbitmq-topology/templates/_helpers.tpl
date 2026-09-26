{{- define "rabbitmq-topology.user" -}}
{{- .Values.user | default .Release.Name -}}
{{- end -}}

{{- define "rabbitmq-topology.clusterRef" -}}
rabbitmqClusterReference:
  name: rabbitmq
  namespace: rabbitmq
{{- end -}}
