package main

import (
	"fmt"

	fnv1 "github.com/crossplane/function-sdk-go/proto/v1"
	"github.com/crossplane/function-sdk-go/resource"
	"github.com/crossplane/function-sdk-go/response"
)

// setXRRendered updates the Tenant XR status to Ready and records render metrics.
func setXRRendered(
	rsp *fnv1.RunFunctionResponse,
	observedXR *resource.Composite,
	t TenantSpec,
	resourceCount int,
) error {
	if err := observedXR.Resource.SetValue("status.phase", "Ready"); err != nil {
		return fmt.Errorf("cannot set status.phase: %w", err)
	}
	if err := observedXR.Resource.SetValue("status.rendered.resources", resourceCount); err != nil {
		return fmt.Errorf("cannot set status.rendered.resources: %w", err)
	}
	if err := observedXR.Resource.SetValue("status.rendered.message",
		fmt.Sprintf("Tenant %q manifests rendered successfully", t.GetName()),
	); err != nil {
		return fmt.Errorf("cannot set status.rendered.message: %w", err)
	}

	observedXR.Resource.SetManagedFields(nil)

	if err := response.SetDesiredCompositeResource(rsp, observedXR); err != nil {
		return fmt.Errorf("cannot set desired composite resource: %w", err)
	}

	response.Normal(rsp, fmt.Sprintf("Rendered tenant %q manifests successfully", t.GetName()))
	return nil
}
