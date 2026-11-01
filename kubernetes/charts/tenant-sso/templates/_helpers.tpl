{{/*
The tenant name, lowercased.
*/}}
{{- define "tenant-sso.tenant" -}}
{{- required "tenant.name is required" .Values.tenant.name | lower -}}
{{- end -}}

{{/*
PascalCase of a dash-separated name, e.g. pillow-factory -> PillowFactory.
*/}}
{{- define "tenant-sso.pascal" -}}
{{- range $part := regexSplit "[-_ ]" . -1 -}}
{{- $part | lower | title -}}
{{- end -}}
{{- end -}}

{{/*
Name of the Group for an app. Takes a dict with "key" (the apps key) and "tenant".
Shared by the Group and by the RoleAssignment that refers to it.
*/}}
{{- define "tenant-sso.groupName" -}}
{{- printf "acl-plt-%s-tenant-%s" .key .tenant -}}
{{- end -}}

{{/*
Deterministic UUID for an app's role. Takes a dict with "key" and "tenant". The AppRole sets it and
the RoleAssignment refers to it, so both must call this with the same input.
*/}}
{{- define "tenant-sso.roleId" -}}
{{- $h := sha1sum (printf "%s-%s" .key .tenant) -}}
{{- printf "%s-%s-5%s-a%s-%s" (substr 0 8 $h) (substr 8 12 $h) (substr 13 16 $h) (substr 17 20 $h) (substr 20 32 $h) -}}
{{- end -}}
