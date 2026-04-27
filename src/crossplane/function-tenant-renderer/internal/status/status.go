package status

import (
	"fmt"

	fnv1 "github.com/crossplane/function-sdk-go/proto/v1"
	"github.com/crossplane/function-sdk-go/resource"
	"github.com/crossplane/function-sdk-go/response"
	"github.com/crossplane/function-tenant-renderer/internal/model"
)

type RenderSummary struct {
	Resources int
}

// SetXRRendered updates the Tenant XR status with render-only state.
// This does not represent live cluster health; it only confirms that manifests were rendered and exported.
func SetXRRendered(
	rsp *fnv1.RunFunctionResponse,
	observedXR *resource.Composite,
	t model.TenantSpec,
	summary RenderSummary,
) error {
	if err := observedXR.Resource.SetValue("status.phase", "Ready"); err != nil {
		return fmt.Errorf("cannot set status.phase: %w", err)
	}

	if err := observedXR.Resource.SetValue("status.rendered.resources", summary.Resources); err != nil {
		return fmt.Errorf("cannot set status.rendered.resources: %w", err)
	}

	if err := observedXR.Resource.SetValue("status.rendered.message",
		fmt.Sprintf("Tenant %q manifests rendered successfully", t.Name),
	); err != nil {
		return fmt.Errorf("cannot set status.rendered.message: %w", err)
	}

	response.Normal(rsp, fmt.Sprintf("Rendered tenant %q manifests successfully", t.Name))
	return nil
}
