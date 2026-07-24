{{- define "managed-cluster.fullname" -}}
{{- required "cluster.name is required" .Values.cluster.name -}}
{{- end -}}
