package main

import (
	"fmt"

	"github.com/crossplane/function-sdk-go/resource/composed"
	xtenant "github.com/rezakaramad/kubepave/src/crossplane/xr-types/tenant"
	"sigs.k8s.io/yaml"
)

func buildGitopsApplication(
	t TenantSpec,
	clusters []xtenant.Cluster,
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

	roles := []map[string]any{}

	for _, role := range t.Roles {
		instances := []map[string]any{}

		for _, cluster := range clusters {
			uuid := generateAppRoleUUID(t.GetName(), role.Name, cluster.Prefix)

			instances = append(instances, map[string]any{
				"cluster":           cluster.Name,
				"environmentPrefix": cluster.Prefix,
				"entraID": map[string]any{
					"appRoleUUID": uuid,
					"assignment": map[string]any{
						"principalObjectIdSelector": map[string]any{
							"enabled": false,
						},
						"principalObjectIds": []string{},
					},
				},
			})
		}

		roles = append(roles, map[string]any{
			"name":      role.Name,
			"instances": instances,
			"policies":  role.Policies,
		})
	}

	values := map[string]any{
		"azure": map[string]any{
			"freeTier": true,
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
			"rbac": map[string]any{
				"roles": roles,
			},
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
