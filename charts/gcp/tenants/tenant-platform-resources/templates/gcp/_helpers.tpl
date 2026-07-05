{{/*
Generate a short, GCP-safe project ID: plt-<name>-<prefix>, truncated to fit length limits.
*/}}
{{- define "tpr.gcp.projectId" }}
{{- printf "plt-%s-%s" (.name | trunc 16) (.prefix | replace " " "-" | lower | trunc 9)}}
{{- end }}

{{/*
Generate a human-readable display name by title-casing name and prefix.
*/}}
{{- define "tpr.gcp.projectDisplayName" -}}
{{- printf "%s %s"
    (.name   | replace "-" " " | title)
    (.prefix | replace "-" " " | title)
-}}
{{- end -}}

{{/*
Validate tenant/project name length (3–20 chars); fail template rendering if invalid.
*/}}
{{- define "tpr.gcp.tenant.validateName" -}}
{{- if gt (len .) 20 -}}
{{- fail (printf "Project name '%s' is too long. Maximum allowed is 20 characters." .) -}}
{{- end -}}
{{- if lt (len .) 3 -}}
{{- fail (printf "Project name '%s' is too short. Minimum required is 3 characters." .) -}}
{{- end -}}
{{- end -}}

