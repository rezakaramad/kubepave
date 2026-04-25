package render

import "sigs.k8s.io/yaml"

func BundleYAML(objs ...map[string]any) (string, error) {
	var out []byte

	for i, obj := range objs {
		b, err := yaml.Marshal(obj)
		if err != nil {
			return "", err
		}

		if i > 0 {
			out = append(out, []byte("---\n")...)
		}

		out = append(out, b...)
	}

	return string(out), nil
}
