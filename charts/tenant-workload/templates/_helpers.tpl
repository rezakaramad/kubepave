{{/*
Generate a short, GCP-safe project ID: <name>-<prefix>, truncated to fit length limits.
*/}}
{{- define "tn.projectId" -}}
{{- printf "%s-%s" (.name | lower | trunc 16) (.prefix | replace " " "-" | lower | trunc 9) -}}
{{- end -}}

{{/*
Generate a human-readable display name by title-casing name and prefix.
*/}}
{{- define "tn.projectDisplayName" -}}
{{- printf "%s %s"
    (.name   | replace "-" " " | title)
    (.prefix | replace "-" " " | title)
-}}
{{- end -}}

{{/*
Common labels for all resources in this chart
*/}}
{{- define "tn.labels" -}}
platform.rezakara.demo/part-of: idp
platform.rezakara.demo/component: tenant-foundation
{{- end -}}

{{/*
Fully-qualified base hostname for a tenant's gateway:
  <tenantShortName>.<environmentPrefix>.rezakara.demo   e.g. pil.wl.rezakara.demo
Callers wildcard it as *.<hostname>. Expects a dict: {name, environmentPrefix}.
*/}}
{{- define "tn.gateway.hostname" -}}
{{- printf "%s.%s.rezakara.demo" (.name | lower) (.environmentPrefix | lower) -}}
{{- end -}}

{{/*
DNS-1123-safe resource name derived from a hostname (dots -> hyphens),
e.g. pil.wl.rezakara.demo -> pil-wl-rezakara-demo. Expects the hostname string as the context.
*/}}
{{- define "tn.gateway.certificateName" -}}
{{- . | lower | replace "." "-" -}}
{{- end -}}
