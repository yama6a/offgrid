{{- define "pg-cluster.name" -}}
{{- .Values.name -}}
{{- end -}}

{{/*
Maps postgresVersion, a major such as "18", to its pinned image tag@digest in files/postgres-images.yaml.
*/}}
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
The barman archive prefix under the ObjectStore's destinationPath. It carries the major, because pg_upgrade
resets the timeline to 1 and creates a new system ID. With one prefix per major, new WAL cannot overwrite old
segments of the same name. Such an overwrite would make every base backup from before the upgrade
unrestorable. A version change starts a new catalog, and restore.serverName can still read the old one.
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

{{/*
true when backupsEnabled is true and files/backup.yaml has a bucket.
*/}}
{{- define "pg-cluster.backupsEnabled" -}}
{{- $b := .Files.Get "files/backup.yaml" | fromYaml -}}
{{- if and .Values.backupsEnabled $b.bucket -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{/*
These annotations stop Argo CD from pruning or deleting the resources.
*/}}
{{- define "pg-cluster.protectAnnotations" -}}
{{- if .Values.deletionProtection -}}
argocd.argoproj.io/sync-options: Prune=false,Delete=false
{{- end -}}
{{- end -}}
