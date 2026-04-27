package github

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"

	"github.com/crossplane/function-tenant-renderer/internal/model"

	"github.com/crossplane/function-sdk-go/resource/composed"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// Config provides all external settings required to build a RepositoryFile resource
type Config struct {
	Namespace          string
	ProviderConfigName string
	Repository         string
	Branch             string
	BasePath           string
	CommitAuthor       string
	CommitEmail        string
}

// BuildRepositoryFile constructs a Crossplane RepositoryFile resource from a TenantSpec and rendered content
func BuildRepositoryFile(t model.TenantSpec, content string, cfg Config) *composed.Unstructured {
	// Build a deterministic file path for the tenant by combining the base path and tenant name,
	// ensuring no duplicate slashes regardless of how BasePath is configured.
	path := fmt.Sprintf("%s/%s/bundle.yaml",
		strings.TrimSuffix(cfg.BasePath, "/"),
		t.Name,
	)

	// Compute a short hash of the content to make commit messages deterministic and traceable.
	hash := sha256.Sum256([]byte(content))
	shortHash := hex.EncodeToString(hash[:])[:8]

	// Initialize an unstructured RepositoryFile resource and set its identity (apiVersion, kind, name)
	// so Crossplane can recognize and manage it correctly.
	u := &unstructured.Unstructured{}
	u.SetAPIVersion("repo.github.m.upbound.io/v1alpha1")
	u.SetKind("RepositoryFile")
	u.SetName(fmt.Sprintf("%s-bundle", t.Name))

	// Determine the target namespace for the RepositoryFile, falling back to a default
	// control-plane namespace if none is provided in the configuration.
	ns := cfg.Namespace
	if ns == "" {
		ns = "crossplane"
	}
	u.SetNamespace(ns)

	// Add labels to the resource for easier identification and management, including the tenant name
	u.SetLabels(map[string]string{
		"app.kubernetes.io/managed-by":  "crossplane",
		"platform.rezakara.demo/tenant": t.Name,
	})

	// Populate the spec of the RepositoryFile with the necessary information to create or update
	u.Object["spec"] = map[string]any{
		"forProvider": map[string]any{
			"repository":        cfg.Repository,
			"branch":            cfg.Branch,
			"file":              path,
			"content":           content,
			"commitAuthor":      cfg.CommitAuthor,
			"commitEmail":       cfg.CommitEmail,
			"commitMessage":     fmt.Sprintf("Render tenant %s manifests (%s)", t.Name, shortHash),
			"overwriteOnCreate": true,
		},
		"providerConfigRef": map[string]any{
			"name": cfg.ProviderConfigName,
			"kind": "ClusterProviderConfig",
		},
	}

	// Return the constructed RepositoryFile wrapped in a composed.Unstructured, which is the expected format for Crossplane composed resources.
	return &composed.Unstructured{
		Unstructured: *u,
	}
}
