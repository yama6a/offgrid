{{- define "redis-instance.labels" -}}
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: cache
alert-criticality: {{ if .Values.alertCritical }}critical{{ else }}warning{{ end }}
{{- end -}}

{{/* Setting these annotations prevents ArgoCD from pruning/deleting the resources. */}}
{{- define "redis-instance.protectAnnotations" -}}
{{- if .Values.deletionProtection -}}
argocd.argoproj.io/sync-options: Prune=false,Delete=false
{{- end -}}
{{- end -}}
