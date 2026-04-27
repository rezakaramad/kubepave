package model

import (
	"fmt"
	"strings"

	"github.com/crossplane/function-sdk-go/resource"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

type TenantRequest struct {
	Name        string
	DisplayName string

	Owner Owner
	DNS   DNS

	ArgoCD ArgoCD
}

type Owner struct {
	Team  string
	Email string
}

type DNS struct {
	Name string
}

type ArgoCD struct {
	SyncRepos []string
}

// FromObservedXR extracts a strongly-typed TenantRequest from XR
func FromObservedXR(xr *resource.Composite) (TenantRequest, error) {

	var out TenantRequest

	u := &unstructured.Unstructured{
		Object: xr.Resource.Object,
	}
	// ---------------------------------------------------------------------
	// Name
	// ---------------------------------------------------------------------
	out.Name = u.GetName()
	if out.Name == "" {
		return out, fmt.Errorf("metadata.name is required")
	}

	// ---------------------------------------------------------------------
	// DNS
	// ---------------------------------------------------------------------
	dns, err := getRequiredString(u, "spec", "dnsName")
	if err != nil {
		return out, err
	}
	dns = strings.ToLower(strings.TrimSpace(dns))
	out.DNS = DNS{
		Name: dns,
	}

	// ---------------------------------------------------------------------
	// Display Name
	// ---------------------------------------------------------------------
	display, _ := getOptionalString(u, "spec", "displayName")
	if display == "" {
		display = out.Name
	}
	out.DisplayName = strings.TrimSpace(display)

	// ---------------------------------------------------------------------
	// Owner
	// ---------------------------------------------------------------------
	team, err := getRequiredString(u, "spec", "owner", "team")
	if err != nil {
		return out, err
	}

	email, _ := getOptionalString(u, "spec", "owner", "email")

	out.Owner = Owner{
		Team:  strings.TrimSpace(team),
		Email: strings.TrimSpace(email),
	}

	// ---------------------------------------------------------------------
	// ArgoCD
	// ---------------------------------------------------------------------
	repos, err := getRequiredStringSlice(u, "spec", "argocd", "syncRepos")
	if err != nil {
		return out, err
	}

	out.ArgoCD = ArgoCD{
		SyncRepos: repos,
	}

	return out, nil
}

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

func getRequiredString(u *unstructured.Unstructured, fields ...string) (string, error) {
	v, found, err := unstructured.NestedString(u.Object, fields...)
	if err != nil {
		return "", fmt.Errorf("invalid field %s: %w", fieldPath(fields...), err)
	}
	if !found || strings.TrimSpace(v) == "" {
		return "", fmt.Errorf("required field missing: %s", fieldPath(fields...))
	}
	return v, nil
}

func getOptionalString(u *unstructured.Unstructured, fields ...string) (string, error) {
	v, found, err := unstructured.NestedString(u.Object, fields...)
	if err != nil {
		return "", fmt.Errorf("invalid field %s: %w", fieldPath(fields...), err)
	}
	if !found {
		return "", nil
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
