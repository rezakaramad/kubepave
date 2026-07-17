{{/*
Generate a short, GCP-safe project ID: <name>-<prefix>, truncated to fit length limits.
*/}}
{{- define "tnr.projectId" -}}
{{- printf "%s-%s" (.name | lower | trunc 16) (.prefix | replace " " "-" | lower | trunc 9) -}}
{{- end -}}

{{/*
Generate a human-readable display name by title-casing name and prefix.
*/}}
{{- define "tnr.projectDisplayName" -}}
{{- printf "%s %s"
    (.name   | replace "-" " " | title)
    (.prefix | replace "-" " " | title)
-}}
{{- end -}}

{{/*
Common labels for all resources in this chart
*/}}
{{- define "tnr.labels" -}}
platform.rezakara.demo/part-of: idp
platform.rezakara.demo/component: tenant-foundation
{{- end -}}
