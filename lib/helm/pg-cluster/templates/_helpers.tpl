{{/*
Instance name: the consumer's explicit fullnameOverride (validated non-empty). Used VERBATIM as the Cluster
name and stamped on the cnpg.io/cluster label the operator copies onto the pods — no release derivation, so it
stays unique when a workload aliases this wrapper more than once.
*/}}
{{- define "pg-cluster.name" -}}
{{- .Values.cluster.fullnameOverride -}}
{{- end -}}

{{/*
Common labels. additionalLabels (e.g. alert-criticality) is merged in because the CNPG operator's
INHERITED_LABELS (02_cnpg_operator) copies matching labels off the Cluster onto the Postgres pods, which the
monitoring alerts key on. See docs/09_monitoring.md.
*/}}
{{- define "pg-cluster.labels" -}}
app.kubernetes.io/name: pg-cluster
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: cloudnative-pg
{{- with .Values.cluster.cluster.additionalLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
True when the Barman Cloud plugin backup path is active (drives the Cluster's .spec.plugins, the ObjectStore,
and the ScheduledBackup). Returns the string "true"/"false" (use `eq ... "true"`).
*/}}
{{- define "pg-cluster.backupsEnabled" -}}
{{- and .Values.cluster.backups.enabled (eq .Values.cluster.backups.method "plugin") -}}
{{- end -}}
