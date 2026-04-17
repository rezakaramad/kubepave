package main

import (
	"fmt"
	"strings"

	"github.com/crossplane/function-sdk-go/resource"
	"sigs.k8s.io/yaml"
)

// isApproved checks whether the Composite Resource has been approved
// by looking for an Approved=True condition in status.conditions.
// If the condition is not present or the status cannot be read, the request is considered not approved.
func isApproved(xr *resource.Composite) bool {
	conditions, err := xr.Resource.GetValue("status.conditions")
	if err != nil {
		return false
	}

	conds, ok := conditions.([]any)
	if !ok {
		return false
	}

	for _, c := range conds {
		cond, ok := c.(map[string]any)
		if !ok {
			continue
		}

		if cond["type"] == "Approved" && cond["status"] == "True" {
			return true
		}
	}

	return false
}

// buildTenantValuesYAML converts TenantRequest spec into a YAML document
// that is stored in Git and consumed by Argo CD + Helm.
//
// The output is NOT a Kubernetes resource.
// It is a values file used for templating downstream resources.
//
// This function must produce stable, deterministic output to avoid unnecessary Git diffs.
func buildTenantValuesYAML(
	name string,
	dnsName string,
	env string,
	displayName string,
	team string,
	email string,
	repos any,
) string {

	data := map[string]any{
		"tenantName":  name,
		"dnsName":     dnsName,
		"environment": env,
		"displayName": displayName,
		"owner": map[string]any{
			"team":  team,
			"email": email,
		},
		"argocd": map[string]any{
			"syncRepos": repos,
		},
	}

	out, err := yaml.Marshal(data)
	if err != nil {
		return fmt.Sprintf("# ERROR: failed to render tenant YAML: %v", err)
	}

	return string(out)
}

// buildFQDN combines dnsName, environmentPrefix, and base domain into a fully qualified domain name like: foo.dev.rezakara.demo.
func buildFQDN(dnsName, env, base string) string {
	base = strings.TrimSuffix(base, ".")
	return fmt.Sprintf("%s.%s.%s.", dnsName, env, base)
}

// isRetryable determines whether an error is retryable based on its message content.
func isRetryable(err error) bool {
	return strings.Contains(err.Error(), "timeout") ||
		strings.Contains(err.Error(), "connection") ||
		strings.Contains(err.Error(), "refused")
}
