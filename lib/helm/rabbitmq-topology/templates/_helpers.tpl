{{/* rabbitmq-topology.user resolves this workload's single user name, defaulting to the release name. */}}
{{- define "rabbitmq-topology.user" -}}
{{- .Values.user | default .Release.Name -}}
{{- end -}}

{{/* rabbitmq-topology.clusterRef renders the shared-broker reference every CR carries: cluster `rabbitmq`
     in ns `rabbitmq`, a platform invariant (03_rabbitmq_cluster), identical for every consumer. */}}
{{- define "rabbitmq-topology.clusterRef" -}}
rabbitmqClusterReference:
  name: rabbitmq
  namespace: rabbitmq
{{- end -}}
