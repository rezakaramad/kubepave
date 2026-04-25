package github

import (
	"fmt"

	"github.com/crossplane/function-sdk-go/resource/composed"
)

type Config struct {
	Namespace          string
	ProviderConfigName string
	Repository         string
	Branch             string
	BasePath           string
	FileName           string
	CommitAuthor       string
	CommitEmail        string
}

func BuildRepositoryFile(
	name string,
	content string,
	cfg Config,
) (*composed.Unstructured, error) {

	filePath := fmt.Sprintf("%s/%s/%s", cfg.BasePath, name, cfg.FileName)

	r := composed.New()
	r.SetAPIVersion("repo.github.m.upbound.io/v1alpha1")
	r.SetKind("RepositoryFile")
	r.SetName(fmt.Sprintf("repo-file-%s", name))
	r.SetNamespace(cfg.Namespace)

	err := r.SetValue("spec", map[string]any{
		"forProvider": map[string]any{
			"repository":        cfg.Repository,
			"branch":            cfg.Branch,
			"file":              filePath,
			"content":           content,
			"autocreateBranch":  true,
			"overwriteOnCreate": true,
			"commitMessage":     fmt.Sprintf("Create/update %s", name),
			"commitAuthor":      cfg.CommitAuthor,
			"commitEmail":       cfg.CommitEmail,
		},
		"providerConfigRef": map[string]any{
			"name": cfg.ProviderConfigName,
			"kind": "ClusterProviderConfig",
		},
	})
	if err != nil {
		return nil, fmt.Errorf("set spec: %w", err)
	}

	return r, nil
}
