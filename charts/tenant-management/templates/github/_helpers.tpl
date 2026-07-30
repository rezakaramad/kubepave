{{/* Returns the GitHub organization where tenant deploy repositories are created */}}
{{- define "tenantDeployRepo.githubOrg" -}}
talktorubberduckdev
{{- end -}}

{{/* Builds the repository name for a tenant (platform-deploy-<tenant>) */}}
{{- define "tenantDeployRepo.repoName" -}}
platform-deploy-{{ . | lower }}
{{- end -}}
