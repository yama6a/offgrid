
{{/* A PV is cluster-scoped and a PVC is not, so two namespaces both claiming `media-library` would otherwise
     collide on one PV. The PVC keeps the short name; only the PV carries the prefix. */}}
{{- define "nfs-volume.pvName" -}}
{{- printf "%s-%s" .namespace .volume.name -}}
{{- end -}}
