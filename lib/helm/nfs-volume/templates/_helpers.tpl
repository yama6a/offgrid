
{{/* A PV is cluster-scoped and a PVC is not. Without the namespace prefix, two namespaces that both claim
     `media-library` would collide on one PV. The PVC keeps the short name. */}}
{{- define "nfs-volume.pvName" -}}
{{- printf "%s-%s" .namespace .volume.name -}}
{{- end -}}
