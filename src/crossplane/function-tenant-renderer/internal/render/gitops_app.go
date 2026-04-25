package render

import (
	"fmt"

	"github.com/crossplane/function-sdk-go/resource/composed"
	"github.com/crossplane/function-tenant-renderer/internal/model"
)

func BuildGitopsApplication(
	t model.TenantSpec,
	repo string,
	branch string,
	basePath string,
) (*composed.Unstructured, error) {

	name := fmt.Sprintf("gitops-%s", t.Name)

	app := composed.New()
	app.SetAPIVersion("argoproj.io/v1alpha1")
	app.SetKind("Application")
	app.SetName(name)
	app.SetNamespace("argocd")

	app.SetLabels(map[string]string{
		"app.kubernetes.io/managed-by":  "crossplane",
		"platform.rezakara.demo/tenant": t.Name,
	})

	spec := map[string]any{
		"project": "default",

		"source": map[string]any{
			"repoURL":        repo,
			"targetRevision": branch,
			"path":           basePath,
		},

		"destination": map[string]any{
			"name":      "in-cluster",
			"namespace": fmt.Sprintf("gitops-%s", t.Name),
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

	if err := app.SetValue("spec", spec); err != nil {
		return nil, fmt.Errorf("cannot build gitops application %s: %w", name, err)
	}

	return app, nil
}
