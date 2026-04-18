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

// buildTenantYAML constructs a Kubernetes manifest for a custom Tenant resource based on the provided parameters.
func buildTenantYAML(
	name string,
	dnsName string,
	envPrefix string,
	displayName string,
	team string,
	email string,
	syncRepos any,
) string {
	obj := map[string]any{
		"apiVersion": "idp.rezakara.demo/v1alpha1",
		"kind":       "Tenant",
		"metadata": map[string]any{
			"name": name,
		},
		"spec": map[string]any{
			"dnsName":           dnsName,
			"environmentPrefix": envPrefix,
			"displayName":       displayName,
			"owner": map[string]any{
				"team":  team,
				"email": email,
			},
			"argocd": map[string]any{
				"syncRepos": syncRepos,
			},
		},
	}

	out, err := yaml.Marshal(obj)
	if err != nil {
		return ""
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
