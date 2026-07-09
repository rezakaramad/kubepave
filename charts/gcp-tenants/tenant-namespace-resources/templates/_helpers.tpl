{{/*
Generate a short, GCP-safe project ID: plt-<name>-<prefix>, truncated to fit length limits.
*/}}
{{- define "tnr.projectId" -}}
{{- printf "plt-%s-%s" (.name | lower | trunc 16) (.prefix | replace " " "-" | lower | trunc 9) -}}
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
platform.jysk.tech/part-of: idp
platform.jysk.tech/component: tenant-foundation
{{- end -}}
