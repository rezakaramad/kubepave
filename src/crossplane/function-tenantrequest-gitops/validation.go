package main

import (
	"context"

	"github.com/crossplane/function-sdk-go/resource"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	ctrlclient "sigs.k8s.io/controller-runtime/pkg/client"
)

// Validation enforces correctness and consistency of TenantRequest.
//
// It operates in two modes:
//
// 1. Pre-provision:
//   - Required fields
//   - Name & DNS uniqueness
//   - DNS availability (PowerDNS)
//
// 2. Post-provision:
//   - Drift detection for immutable fields
type ValidationError struct {
	Reason    string
	Message   string
	Retryable bool
}

func (f *Function) validate(ctx context.Context, xr *resource.Composite) *ValidationError {

	// 1. Required fields: Before doing anything fancy, make sure the required input exists.
	if err := validateRequiredFields(xr); err != nil {
		return err
	}

	// Gets the Kubernetes name of the XR itself (e.g. tenantrequest-sample-12345) so we can use it for ownership detection and uniqueness checks.
	name := xr.Resource.GetName()
	dnsName, _ := xr.Resource.GetString("spec.dnsName")
	envPrefix, _ := xr.Resource.GetString("spec.environmentPrefix")

	// Detect if tenant already exists and is owned by this request
	ownedTenant, err := f.getTenant(ctx, name)
	if err != nil {
		return &ValidationError{"ValidationError", err.Error(), true}
	}

	// Is there already a Tenant in the cluster owned by this XR?
	// If no Tenant is found for this XR, we are in pre-provision phase.
	// If a Tenant exists, we are in post-provision phase.
	isPostProvision := ownedTenant != nil

	// Phase 1: Pre-provision
	if !isPostProvision {

		// This combines pieces like: dnsName, environmentPrefix, and base domain into something like: foo.dev.rezakara.demo.
		fqdn := buildFQDN(dnsName, envPrefix, f.dnsBaseDomain)

		// This asks PowerDNS: “Does this DNS already exist?”
		result, err := f.pdns.CheckDNSAvailable(ctx, fqdn)
		if err != nil {
			return &ValidationError{"DnsCheckFailed", err.Error(), isRetryable(err)}
		}

		if !result.Available {
			return &ValidationError{"DnsNameTaken", result.Reason, false}
		}

		return nil
	}

	// Phase 2: Post-provision
	//
	// Once the tenant already exists, we are no longer asking "is this name unique?" or "is this DNS available?"
	// Those questions are only relevant at creation time.
	// Validate consistency only

	// Immutable fields: name and dnsName.
	// If the existing Kubernetes Tenant name does not match the XR spec anymore, that is drift and should be rejected.
	if ownedTenant.GetName() != name {
		return &ValidationError{"DriftDetected", "tenant name mismatch", false}
	}

	// If the existing Tenant DNS name does not match the XR spec anymore, that is drift and should be rejected.
	existingDNS, _, _ := unstructured.NestedString(ownedTenant.Object, "spec", "dnsName")
	if existingDNS != dnsName {
		return &ValidationError{"DriftDetected", "dns mismatch", false}
	}

	return nil
}

// ---------------------------------------------------------------------
// Ownership detection
// ---------------------------------------------------------------------
func (f *Function) getTenant(ctx context.Context, name string) (*unstructured.Unstructured, error) {
	// In Kubernetes, if you have "kind: Tenant", Kubernetes automatically creates a corresponding "kind: TenantList" that represents a list of those objects.
	// To find the Tenant that belongs to this XR, we can list all Tenants and look for the one with a label that matches our XR name.
	tenant := &unstructured.Unstructured{}
	tenant.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   "idp.rezakara.demo",
		Version: "v1alpha1",
		Kind:    "Tenant",
	})

	// Query the Kubernetes API to list all Tenant resources (TenantList) into `list`.
	// If the API call fails, return the error since we cannot proceed without cluster state.
	err := f.kube.Get(ctx, ctrlclient.ObjectKey{Name: name}, tenant)
	if err != nil {
		if ctrlclient.IgnoreNotFound(err) == nil {
			return nil, nil
		}
		return nil, err
	}

	return tenant, nil
}

func validateRequiredFields(xr *resource.Composite) *ValidationError {
	// Check that 'name' is present in the XR spec, and return a ValidationError if any are missing.
	name := xr.Resource.GetName()
	if name == "" {
		return &ValidationError{"InvalidSpec", "metadata.name is required", false}
	}

	// Check that 'dnsName' is present in the XR spec, and return a ValidationError if any are missing.
	dnsName, _ := xr.Resource.GetString("spec.dnsName")
	if dnsName == "" {
		return &ValidationError{"InvalidSpec", "spec.dnsName is required", false}
	}

	// Check that 'envPrefix' is present in the XR spec, and return a ValidationError if any are missing.
	envPrefix, _ := xr.Resource.GetString("spec.environmentPrefix")
	if envPrefix == "" {
		return &ValidationError{"InvalidSpec", "spec.environmentPrefix is required", false}
	}

	// Check that 'team' is present in the XR spec, and return a ValidationError if any are missing.
	team, _ := xr.Resource.GetString("spec.owner.team")
	if team == "" {
		return &ValidationError{"InvalidSpec", "spec.owner.team is required", false}
	}

	// Check that 'repos' is present in the XR spec, and return a ValidationError if any are missing.
	repos, err := xr.Resource.GetValue("spec.argocd.syncRepos")
	if err != nil || repos == nil {
		return &ValidationError{"InvalidSpec", "spec.argocd.syncRepos is required", false}
	}

	// Check that 'repos' is a non-empty list, and return a ValidationError if it is not.
	reposList, ok := repos.([]any)
	if !ok || len(reposList) == 0 {
		return &ValidationError{"InvalidSpec", "spec.argocd.syncRepos must not be empty", false}
	}

	return nil
}
