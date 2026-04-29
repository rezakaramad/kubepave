package main

import (
	inputv1beta1 "github.com/crossplane/function-tenant-renderer/input/v1beta1"
	xtenant "github.com/rezakaramad/kubepave/src/crossplane/xr-types/tenant"
)

// TenantSpec is the renderer's internal view of a Tenant.
// It embeds xtenant.Tenant (the shared wire-format type) so XR fields are not
// duplicated here, and adds renderer-only fields that have no representation
// in the XR schema.
type TenantSpec struct {
	xtenant.Tenant

	// SyncRepos is derived at render time, not read from the XR.
	SyncRepos []string
	// Roles are passed directly from the Composition input.
	Roles []inputv1beta1.RoleInput
}

func commonLabels(t TenantSpec) map[string]string {
	return map[string]string{
		"app.kubernetes.io/managed-by":  "crossplane",
		"platform.rezakara.demo/tenant": t.GetName(),
	}
}
