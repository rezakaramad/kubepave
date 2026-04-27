package render

import (
	"fmt"
	"sort"

	"github.com/crossplane/function-sdk-go/resource/composed"
	"github.com/crossplane/function-tenant-renderer/internal/model"
)

func BuildBaselineApplications(
	t model.TenantSpec,
	destinationClusters []model.Cluster,
	repo string,
	branch string,
	basePath string,
) ([]*composed.Unstructured, error) {

	if len(destinationClusters) == 0 {
		return nil, nil
	}

	// Ensure deterministic ordering (important for stable Git diffs)
	sorted := append([]model.Cluster(nil), destinationClusters...)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].Prefix < sorted[j].Prefix
	})

	var apps []*composed.Unstructured

	for _, c := range sorted {
		name := fmt.Sprintf("baseline-%s-%s", t.Name, c.Prefix)

		app := composed.New()
		app.SetAPIVersion("argoproj.io/v1alpha1")
		app.SetKind("Application")
		app.SetName(name)
		app.SetNamespace("argocd")

		// Extra safety for unstructured handling
		_ = app.SetValue("metadata.namespace", "argocd")

		app.SetLabels(map[string]string{
			"app.kubernetes.io/managed-by":  "crossplane",
			"platform.rezakara.demo/tenant": t.Name,
			"platform.rezakara.demo/prefix": c.Prefix,
		})

		spec := map[string]any{
			"project": "default",
			"source": map[string]any{
				"repoURL":        repo,
				"targetRevision": branch,
				"path":           basePath,
			},
			"destination": map[string]any{
				"name":      c.Name,
				"namespace": t.Name,
			},
		}

		if t.AutomatedSync {
			spec["syncPolicy"] = map[string]any{
				"automated": map[string]any{
					"prune":    t.Prune,
					"selfHeal": t.SelfHeal,
				},
			}
		}

		// Apply spec to resource (critical step)
		if err := app.SetValue("spec", spec); err != nil {
			return nil, fmt.Errorf("cannot build baseline app %s: %w", name, err)
		}

		apps = append(apps, app)
	}

	return apps, nil
}
