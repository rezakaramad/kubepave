package main

import (
	"bytes"
	"fmt"

	"github.com/crossplane/function-sdk-go/resource/composed"
	"github.com/google/uuid"
	"sigs.k8s.io/yaml"
)

// bundleYAML serializes one or more rendered Kubernetes resources into a single multi-document YAML string.
func bundleYAML(resources ...*composed.Unstructured) (string, error) {
	var buf bytes.Buffer
	first := true

	for _, resource := range resources {
		if resource == nil {
			continue
		}

		b, err := yaml.Marshal(resource.Object)
		if err != nil {
			return "", fmt.Errorf("cannot marshal resource %s/%s: %w",
				resource.GetKind(),
				resource.GetName(),
				err,
			)
		}

		if !first {
			buf.WriteString("---\n")
		}
		first = false

		buf.Write(b)
		if !bytes.HasSuffix(b, []byte("\n")) {
			buf.WriteString("\n")
		}
	}

	return buf.String(), nil
}

// generateAppRoleUUID produces a deterministic UUID for an ArgoCD app role instance
// scoped to (tenant, role, environment).
func generateAppRoleUUID(tenant, role, env string) string {
	seed := fmt.Sprintf("%s-%s-%s", tenant, role, env)
	return uuid.NewSHA1(uuid.NameSpaceDNS, []byte(seed)).String()
}
