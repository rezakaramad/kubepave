package render

import (
	"bytes"
	"fmt"

	"github.com/crossplane/function-sdk-go/resource/composed"
	"sigs.k8s.io/yaml"
)

// BundleYAML serializes one or more rendered Kubernetes resources into a single multi-document YAML string.
func BundleYAML(resources ...*composed.Unstructured) (string, error) {
	// resource 1 → write to buffer
	// resource 2 → append to buffer
	// resource 3 → append to buffer
	// → final YAML string
	// Use bytes.Buffer to efficiently and incrementally build the final YAML output.
	// It avoids repeated string allocations and provides a clean way to append multiple YAML documents.
	var buf bytes.Buffer

	// This is a flag to track: am I writing the first YAML document or not?
	// We only want to write the document separator `---` before the second and subsequent documents, not before the first one.
	first := true

	for _, resource := range resources {
		if resource == nil {
			continue
		}

		// Marshal the resource's Object field to YAML. This converts the Kubernetes resource into its YAML representation.
		b, err := yaml.Marshal(resource.Object)
		if err != nil {
			// If there is an error during marshaling, we return an error with context about which resource failed to marshal.
			// cannot marshal resource Application/gitops-payment: yaml: unsupported type
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

	if buf.Len() == 0 {
		return "", fmt.Errorf("no resources to bundle")
	}

	return buf.String(), nil
}
