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

	sorted := append([]model.Cluster(nil), destinationClusters...)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].Prefix < sorted[j].Prefix
	})

	var apps []*composed.Unstructured

	for _, c := range sorted {
		name := fmt.Sprintf("%s-baseline-%s", t.Name, c.Prefix)

		app := composed.New()
		app.SetAPIVersion("argoproj.io/v1alpha1")
		app.SetKind("Application")
		app.SetName(name)
		app.SetNamespace("argocd")

		app.SetLabels(map[string]string{
			"app.kubernetes.io/managed-by":  "crossplane",
			"platform.rezakara.demo/tenant": t.Name,
			"platform.rezakara.demo/prefix": c.Prefix,
		})

		err := app.SetValue("spec", map[string]any{
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
			"syncPolicy": map[string]any{
				"automated": map[string]any{
					"prune":    t.Prune,
					"selfHeal": t.SelfHeal,
				},
			},
		})
		if err != nil {
			return nil, fmt.Errorf("cannot build baseline app %s: %w", name, err)
		}

		apps = append(apps, app)
	}

	return apps, nil
}
