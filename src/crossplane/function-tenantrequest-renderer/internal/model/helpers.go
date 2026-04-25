package model

import (
	"fmt"
	"strings"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func getRequiredString(u *unstructured.Unstructured, fields ...string) (string, error) {
	v, found, err := unstructured.NestedString(u.Object, fields...)
	if err != nil {
		return "", fmt.Errorf("invalid field %s: %w", fieldPath(fields...), err)
	}
	if !found || v == "" {
		return "", fmt.Errorf("required field missing: %s", fieldPath(fields...))
	}
	return v, nil
}

func getOptionalString(u *unstructured.Unstructured, fields ...string) (string, error) {
	v, _, err := unstructured.NestedString(u.Object, fields...)
	if err != nil {
		return "", fmt.Errorf("invalid field %s: %w", fieldPath(fields...), err)
	}
	return v, nil
}

func getRequiredStringSlice(u *unstructured.Unstructured, fields ...string) ([]string, error) {
	v, found, err := unstructured.NestedStringSlice(u.Object, fields...)
	if err != nil {
		return nil, fmt.Errorf("invalid field %s: %w", fieldPath(fields...), err)
	}
	if !found || len(v) == 0 {
		return nil, fmt.Errorf("required field missing: %s", fieldPath(fields...))
	}
	return v, nil
}

func fieldPath(fields ...string) string {
	return strings.Join(fields, ".")
}
