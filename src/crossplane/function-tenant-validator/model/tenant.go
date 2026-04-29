package model

import (
	"fmt"
	"strings"

	"github.com/crossplane/function-sdk-go/resource"
	xtenant "github.com/rezakaramad/kubepave/xr-types/tenant"
	"k8s.io/apimachinery/pkg/runtime"
)

// FromObservedXR extracts a strongly-typed Tenant from the observed XR.
// Uses runtime.DefaultUnstructuredConverter (the canonical Kubernetes way)
// to convert the unstructured map directly into the typed Tenant struct.
func FromObservedXR(xr *resource.Composite) (xtenant.Tenant, error) {
	var t xtenant.Tenant
	if err := runtime.DefaultUnstructuredConverter.FromUnstructured(
		xr.Resource.UnstructuredContent(), &t,
	); err != nil {
		return xtenant.Tenant{}, fmt.Errorf("cannot convert XR to Tenant: %w", err)
	}

	if t.GetName() == "" {
		return t, fmt.Errorf("metadata.name is required")
	}
	if strings.TrimSpace(t.Spec.DNSName) == "" {
		return t, fmt.Errorf("required field missing: spec.dnsName")
	}
	if strings.TrimSpace(t.Spec.Owner.Team) == "" {
		return t, fmt.Errorf("required field missing: spec.owner.team")
	}

	return t, nil
}
