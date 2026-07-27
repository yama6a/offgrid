{{/*
Instance name: the consumer's explicit `name` (validated non-empty). Used VERBATIM as the Cluster name and
stamped on the cnpg.io/cluster label the operator copies onto the pods. No release derivation, so it stays
unique when a workload aliases this wrapper more than once.
*/}}
{{- define "pg-cluster.name" -}}
{{- .Values.name -}}
{{- end -}}

{{/*
Common labels. alert-criticality is ALWAYS stamped (critical|warning) so the label is never absent: the CNPG
operator's INHERITED_LABELS (02_cnpg_operator) copies it onto the pods, and the alert-severity template keys on
it (a missing field would break that template). See docs/09_monitoring.md.
*/}}
{{- define "pg-cluster.labels" -}}
app.kubernetes.io/name: pg-cluster
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: cloudnative-pg
alert-criticality: {{ if .Values.alertCritical }}critical{{ else }}warning{{ end }}
{{- end -}}

{{/*
True when the Barman Cloud plugin backup path is active (drives the Cluster's .spec.plugins, the ObjectStore,
and the ScheduledBackup). Returns the string "true"/"false" (use `eq ... "true"`).
*/}}
{{- define "pg-cluster.backupsEnabled" -}}
{{- and .Values.backups.enabled (eq .Values.backups.method "plugin") -}}
{{- end -}}

{{/*
Orphan-not-delete guard. Prune=false spares the resource when it leaves the rendered manifests (git edit);
Delete=false spares it from the Application's resources-finalizer cascade (whole workload removed from git). So a
GitOps prune ORPHANS the DB unit (keeps it running on its PVCs) instead of destroying it, and restoring the files
re-adopts the live resource. local-path reclaim is Delete, so this is the ONLY data-safety mechanism: it goes on
every resource the surviving Cluster needs. Cost: the app reports OutOfSync forever (argo-cd#17188); that is the
intended orphan signal, do NOT add compare-options IgnoreExtraneous. See docs/13_backups.md.
*/}}
{{- define "pg-cluster.protectAnnotations" -}}
{{- if .Values.protectFromPrune -}}
argocd.argoproj.io/sync-options: Prune=false,Delete=false
{{- end -}}
{{- end -}}
