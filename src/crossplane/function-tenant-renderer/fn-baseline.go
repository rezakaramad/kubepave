package main

import (
	"fmt"
	"sort"

	"github.com/crossplane/function-sdk-go/resource/composed"
	xtenant "github.com/rezakaramad/kubepave/src/crossplane/xr-types/tenant"
	"sigs.k8s.io/yaml"
)

func buildBaselineApplications(
	t TenantSpec,
	destinationClusters []xtenant.Cluster,
	repo string,
	branch string,
	basePath string,
) ([]*composed.Unstructured, error) {

	if len(destinationClusters) == 0 {
		return nil, nil
	}

	// Ensure deterministic ordering (important for stable Git diffs)
	sorted := append([]xtenant.Cluster(nil), destinationClusters...)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].Prefix < sorted[j].Prefix
	})

	var apps []*composed.Unstructured

	for _, c := range sorted {
		name := fmt.Sprintf("baseline-%s-%s", t.GetName(), c.Prefix)

		app := composed.New()
		app.SetAPIVersion("argoproj.io/v1alpha1")
		app.SetKind("Application")
		app.SetName(name)
		app.SetNamespace("argocd")
		_ = app.SetValue("metadata.namespace", "argocd")

		app.SetLabels(map[string]string{
			"app.kubernetes.io/managed-by":  "crossplane",
			"platform.rezakara.demo/tenant": t.GetName(),
			"platform.rezakara.demo/prefix": c.Prefix,
		})

		values := map[string]any{
			"tenant": map[string]any{
				"name":    t.GetName(),
				"dnsName": t.Spec.DNSName,
				"owner": map[string]any{
					"team":  t.Spec.Owner.Team,
					"email": t.Spec.Owner.Email,
				},
			},
			"environmentPrefix": c.Prefix,
		}

		valuesYaml, err := yaml.Marshal(values)
		if err != nil {
			return nil, fmt.Errorf("cannot marshal baseline values: %w", err)
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
				"name":      c.Name,
				"namespace": t.GetName(),
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
			return nil, fmt.Errorf("cannot build baseline app %s: %w", name, err)
		}

		apps = append(apps, app)
	}

	return apps, nil
}
