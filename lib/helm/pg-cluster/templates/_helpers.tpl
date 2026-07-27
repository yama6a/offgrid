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
Per-deployment backup facts (files/backup.yaml): bucket/region/retentionPolicy/archiveTimeout + sealed creds,
written by 14_cnpg_backup.sh. Callers pipe to `fromYaml`; a blank/absent file yields an empty map (nil-safe).
Chart-scoped, so both aliases read the SAME file: single source, no per-consumer wiring.
*/}}
{{- define "pg-cluster.backupConfig" -}}
{{- .Files.Get "files/backup.yaml" -}}
{{- end -}}

{{/*
The S3-creds Secret name for THIS instance: `<name>-backup-s3`. Per-instance (not a single shared name) so N
DBs in one namespace never collide on it, which is what lets each instance render its own SealedSecret with no
cross-instance coordination. The one cluster-wide-sealed ciphertext (files/backup.yaml) unseals into any name in
any namespace, so reusing it under a per-instance name is free. objectstore.yaml + backup-sealedsecret.yaml both
key off this.
*/}}
{{- define "pg-cluster.backupSecretName" -}}
{{- include "pg-cluster.name" . }}-backup-s3
{{- end -}}

{{/*
True when the Barman Cloud plugin backup path is active (drives the Cluster's .spec.plugins, the ObjectStore,
the ScheduledBackup, the SealedSecret, and the S3 netpol egress). Gated on the opt-OUT flag AND a populated
overlay: a blank files/backup.yaml (fresh clone, 14 not run) renders backups OFF even with enabled=true, so no
half-configured ObjectStore leaks out. Returns the string "true"/"false" (use `eq ... "true"`).
*/}}
{{- define "pg-cluster.backupsEnabled" -}}
{{- $b := include "pg-cluster.backupConfig" . | fromYaml -}}
{{- if and .Values.backupsEnabled $b.bucket -}}true{{- else -}}false{{- end -}}
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
