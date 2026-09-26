{{- define "pg-cluster.name" -}}
{{- .Values.name -}}
{{- end -}}

{{- define "pg-cluster.image" -}}
{{- $images := .Files.Get "files/postgres-images.yaml" | fromYaml -}}
{{- $v := .Values.postgresVersion | toString -}}
{{- $img := index $images $v -}}
{{- if not $img -}}
{{- fail (printf "pg-cluster: postgresVersion %q is not a supported major. files/postgres-images.yaml has: %s" $v (keys $images | sortAlpha | join ", ")) -}}
{{- end -}}
{{- $img -}}
{{- end -}}

{{/*
Carries the major, because pg_upgrade resets the timeline and new WAL would overwrite old segments of the same
name. That would make every earlier base backup unrestorable.
*/}}
{{- define "pg-cluster.serverName" -}}
{{- printf "%s-pg%s" (include "pg-cluster.name" .) (.Values.postgresVersion | toString) -}}
{{- end -}}

{{- define "pg-cluster.labels" -}}
app.kubernetes.io/name: pg-cluster
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: cloudnative-pg
alert-criticality: {{ if .Values.alertCritical }}critical{{ else }}warning{{ end }}
{{- end -}}

{{- define "pg-cluster.backupSecretName" -}}
{{- include "pg-cluster.name" . }}-backup-s3
{{- end -}}

{{- define "pg-cluster.backupsEnabled" -}}
{{- $b := .Files.Get "files/backup.yaml" | fromYaml -}}
{{- if and .Values.backupsEnabled $b.bucket -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{- define "pg-cluster.protectAnnotations" -}}
{{- if .Values.deletionProtection -}}
argocd.argoproj.io/sync-options: Prune=false,Delete=false
{{- end -}}
{{- end -}}
