{{/*
Common labels for every resource this chart renders (Redis CR, ext-config ConfigMap, ServiceMonitor). One source
so the set can't drift per template. alert-criticality is ALWAYS stamped (critical|warning) so the label is never
absent: OpsTree copies CR labels onto the StatefulSet + pods, and the alert-severity template keys on it (a
missing field would break that template). critical pages `critical`, else `warning`. See docs/09_monitoring.md.
*/}}
{{- define "redis-instance.labels" -}}
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: cache
alert-criticality: {{ if .Values.alertCritical }}critical{{ else }}warning{{ end }}
{{- end -}}

{{/*
Orphan-not-delete guard. Prune=false spares the resource when it leaves the rendered manifests (git edit);
Delete=false spares it from the Application's resources-finalizer cascade (whole workload removed from git). So a
GitOps prune ORPHANS the instance (keeps it serving off its PVC) instead of destroying it, and restoring the files
re-adopts it. The retained class's Retain is only a backstop: it saves the DATA, but the instance goes down and
needs a manual PV rebind. Goes on every resource the surviving instance needs. Cost: the app reports OutOfSync
forever (argo-cd#17188); that is the intended orphan signal, do NOT add compare-options IgnoreExtraneous.
See docs/12_redis.md.
*/}}
{{- define "redis-instance.protectAnnotations" -}}
{{- if .Values.deletionProtection -}}
argocd.argoproj.io/sync-options: Prune=false,Delete=false
{{- end -}}
{{- end -}}
