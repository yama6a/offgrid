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
