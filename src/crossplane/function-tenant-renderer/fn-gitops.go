package main

import (
	"fmt"
	"sort"

	"github.com/crossplane/function-sdk-go/resource/composed"
	inputv1beta1 "github.com/crossplane/function-tenant-renderer/input/v1beta1"
	"sigs.k8s.io/yaml"
)

func policiesForRole(role string) ([]map[string]any, error) {
	switch role {
	case "admin":
		return []map[string]any{
			{
				"resource": "applications",
				"actions":  []string{"get", "update", "delete", "sync", "action/apps/Deployment/pause", "action/apps/Deployment/resume", "action/apps/Deployment/restart", "action/batch/CronJob/create-job"},
			},
			{
				"resource": "logs",
				"actions":  []string{"get"},
			},
		}, nil
	case "viewer":
		return []map[string]any{
			{
				"resource": "applications",
				"actions":  []string{"get"},
			},
			{
				"resource": "logs",
				"actions":  []string{"get"},
			},
		}, nil
	default:
		return nil, fmt.Errorf("unsupported role %q", role)
	}
}

func renderedRoles(bindings []ResolvedBinding) ([]map[string]any, error) {
	seen := map[string]struct{}{}
	roles := make([]string, 0, len(bindings))
	for _, binding := range bindings {
		if _, ok := seen[binding.Role]; ok {
			continue
		}
		seen[binding.Role] = struct{}{}
		roles = append(roles, binding.Role)
	}
	sort.Strings(roles)

	out := make([]map[string]any, 0, len(roles))
	for _, role := range roles {
		policies, err := policiesForRole(role)
		if err != nil {
			return nil, err
		}
		out = append(out, map[string]any{
			"name":     role,
			"policies": policies,
		})
	}

	return out, nil
}

func buildGitopsApplication(
	t TenantSpec,
	bindings []ResolvedBinding,
	azure inputv1beta1.AzureInput,
	repo string,
	branch string,
	basePath string,
) (*composed.Unstructured, error) {

	name := fmt.Sprintf("gitops-%s", t.GetName())

	app := composed.New()
	app.SetAPIVersion("argoproj.io/v1alpha1")
	app.SetKind("Application")
	app.SetName(name)
	app.SetNamespace("argocd")
	_ = app.SetValue("metadata.namespace", "argocd")

	app.SetLabels(commonLabels(t))

	roles, err := renderedRoles(bindings)
	if err != nil {
		return nil, fmt.Errorf("cannot render tenant roles: %w", err)
	}

	renderedBindings := make([]map[string]any, 0, len(bindings))
	for _, binding := range bindings {
		renderedBindings = append(renderedBindings, map[string]any{
			"role":              binding.Role,
			"cluster":           binding.Cluster,
			"environmentPrefix": binding.EnvironmentPrefix,
			"entraID": map[string]any{
				"appRoleUUID": generateAppRoleUUID(t.GetName(), binding.Role, binding.EnvironmentPrefix),
				"assignment": map[string]any{
					"principalObjectId": binding.PrincipalObjectID,
				},
			},
		})
	}

	values := map[string]any{
		"azure": map[string]any{
			"principalType": azure.PrincipalType,
		},
		"tenant": map[string]any{
			"name":    t.GetName(),
			"dnsName": t.Spec.DNSName,
			"owner": map[string]any{
				"team":  t.Spec.Owner.Team,
				"email": t.Spec.Owner.Email,
			},
			"argocd": map[string]any{
				"syncRepos": t.SyncRepos,
			},
			"roles":    roles,
			"bindings": renderedBindings,
		},
	}

	valuesYaml, err := yaml.Marshal(values)
	if err != nil {
		return nil, fmt.Errorf("cannot marshal gitops values: %w", err)
	}

	spec := map[string]any{
		"project": "default",
		"source": map[string]any{
			"repoURL":        repo,
			"targetRevision": branch,
			"path":           basePath,
			"helm": map[string]any{
				"values": string(valuesYaml),
			},
		},
		"destination": map[string]any{
			"name":      "in-cluster",
			"namespace": fmt.Sprintf("gitops-%s", t.GetName()),
		},
	}

	if t.Spec.ArgoCD.SyncPolicy.AutomatedSync {
		spec["syncPolicy"] = map[string]any{
			"automated": map[string]any{
				"prune":    t.Spec.ArgoCD.SyncPolicy.Prune,
				"selfHeal": t.Spec.ArgoCD.SyncPolicy.SelfHeal,
			},
		}
	}

	if err := app.SetValue("spec", spec); err != nil {
		return nil, fmt.Errorf("cannot build gitops application %s: %w", name, err)
	}

	return app, nil
}
