
{{/* PVs are cluster-scoped, so the namespace prefix keeps two namespaces' claims apart. */}}
{{- define "nfs-volume.pvName" -}}
{{- printf "%s-%s" .namespace .volume.name -}}
{{- end -}}
