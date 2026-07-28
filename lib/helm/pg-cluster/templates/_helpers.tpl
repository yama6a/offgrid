{{- define "pg-cluster.name" -}}
{{- .Values.name -}}
{{- end -}}

{{/*
Resolve postgresVersion (a major, e.g. "18") to the pinned image (tag@digest) from files/postgres-images.yaml.
*/}}
{{- define "pg-cluster.image" -}}
{{- $images := .Files.Get "files/postgres-images.yaml" | fromYaml -}}
{{- $v := .Values.postgresVersion | toString -}}
{{- $img := index $images $v -}}
{{- if not $img -}}
{{- fail (printf "pg-cluster: postgresVersion %q is not a supported major; files/postgres-images.yaml has: %s" $v (keys $images | sortAlpha | join ", ")) -}}
{{- end -}}
{{- $img -}}
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

{{/*
Enabled if backupsEnabled is true and the backup.yaml has a bucket defined (not empty).
*/}}
{{- define "pg-cluster.backupsEnabled" -}}
{{- $b := .Files.Get "files/backup.yaml" | fromYaml -}}
{{- if and .Values.backupsEnabled $b.bucket -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{/*
Setting these labels prevents ArgoCD from pruning/deleting the resources.
*/}}
{{- define "pg-cluster.protectAnnotations" -}}
{{- if .Values.deletionProtection -}}
argocd.argoproj.io/sync-options: Prune=false,Delete=false
{{- end -}}
{{- end -}}
