package main

import (
	"context"
	"fmt"
	"time"

	xperrors "github.com/crossplane/crossplane-runtime/v2/pkg/errors"
	"github.com/crossplane/function-sdk-go/logging"
	fnv1 "github.com/crossplane/function-sdk-go/proto/v1"
	"github.com/crossplane/function-sdk-go/request"
	"github.com/crossplane/function-sdk-go/resource"
	"github.com/crossplane/function-sdk-go/resource/composed"
	"github.com/crossplane/function-sdk-go/response"

	"github.com/crossplane/function-tenantrequest-renderer/model"

	ctrlclient "sigs.k8s.io/controller-runtime/pkg/client"
)

type Function struct {
	fnv1.UnimplementedFunctionRunnerServiceServer
	log logging.Logger

	crossplaneNamespace string
	workloadClusters    []model.Cluster

	kube ctrlclient.Client
	pdns PDNSClient

	dnsBaseDomain string
}

func NewFunction(l logging.Logger) *Function {
	return &Function{log: l}
}

func (f *Function) RunFunction(
	ctx context.Context,
	req *fnv1.RunFunctionRequest,
) (*fnv1.RunFunctionResponse, error) {

	start := time.Now()

	log := f.log.WithValues("tag", req.GetMeta().GetTag())
	log.Info("Running function-tenantrequest-renderer")

	rsp := response.To(req, response.DefaultTTL)

	// ---------------------------------------------------------------------
	// 1. Load XR
	// ---------------------------------------------------------------------
	xr, err := request.GetObservedCompositeResource(req)
	if err != nil {
		return fatal(rsp, err, "cannot get observed TenantRequest")
	}

	// ---------------------------------------------------------------------
	// 2. Parse model
	// ---------------------------------------------------------------------
	tenantRequest, err := model.FromObservedXR(xr)
	if err != nil {
		return fail(rsp, xr, PhaseFailed, err, "cannot parse TenantRequest")
	}

	log = log.WithValues("tenant", tenantRequest.Name)

	// ---------------------------------------------------------------------
	// 3. Validation
	// ---------------------------------------------------------------------
	SetPhase(xr, PhaseValidating)

	if verr := Validate(ctx, tenantRequest, Deps{
		Kube:             f.kube,
		PDNSClient:       f.pdns,
		BaseDomain:       f.dnsBaseDomain,
		WorkloadClusters: f.workloadClusters,
	}); verr != nil {

		if verr.Retryable {
			SetPhase(xr, PhaseValidating)
		} else {
			SetPhase(xr, PhaseFailed)
		}

		response.ConditionFalse(rsp, "Valid", verr.Reason).
			WithMessage(verr.Message).
			TargetCompositeAndClaim()

		response.ConditionFalse(rsp, "Ready", "ValidationFailed").
			WithMessage("TenantRequest is not valid").
			TargetCompositeAndClaim()

		log.Info("Validation failed", "reason", verr.Reason)

		return done(rsp, xr)
	}

	response.ConditionTrue(rsp, "Valid", "ValidationPassed").
		TargetCompositeAndClaim()

	// ---------------------------------------------------------------------
	// 4. Approval
	// ---------------------------------------------------------------------
	if !IsApproved(xr) {
		SetPhase(xr, PhasePendingApproval)

		response.ConditionFalse(rsp, "Approved", "WaitingForApproval").
			TargetCompositeAndClaim()

		response.ConditionFalse(rsp, "Ready", "WaitingForApproval").
			TargetCompositeAndClaim()

		log.Info("Waiting for approval")

		return done(rsp, xr)
	}

	response.ConditionTrue(rsp, "Approved", "Approved").
		TargetCompositeAndClaim()

	// ---------------------------------------------------------------------
	// 5. Desired resources
	// ---------------------------------------------------------------------
	desired, err := request.GetDesiredComposedResources(req)
	if err != nil {
		return fail(rsp, xr, PhaseFailed, err, "cannot get desired composed resources")
	}

	// ✅ CORRECT: use composed.New()
	tenant := composed.New()

	tenant.SetAPIVersion("idp.rezakara.demo/v1alpha1")
	tenant.SetKind("Tenant")
	tenant.SetName(tenantRequest.Name)

	if err := tenant.SetValue("spec", map[string]any{
		"dnsName":     tenantRequest.DNS.Name,
		"displayName": tenantRequest.DisplayName,
		"owner": map[string]any{
			"team":  tenantRequest.Owner.Team,
			"email": tenantRequest.Owner.Email,
		},
		"argocd": map[string]any{
			"syncRepos": tenantRequest.ArgoCD.SyncRepos,
		},
	}); err != nil {
		return fail(rsp, xr, PhaseFailed, err, "cannot build tenant spec")
	}

	desired[resource.Name("tenant")] = &resource.DesiredComposed{
		Resource: tenant,
		Ready:    resource.ReadyTrue,
	}

	// ---------------------------------------------------------------------
	// 6. Status
	// ---------------------------------------------------------------------
	SetPhase(xr, PhaseReady)

	response.ConditionTrue(rsp, "Ready", "Submitted").
		WithMessage("Tenant resource submitted to Crossplane").
		TargetCompositeAndClaim()

	response.ConditionTrue(rsp, "Synced", "TenantCreated").
		WithMessage("Tenant resource is managed by Crossplane").
		TargetCompositeAndClaim()

	log.Info("Reconciliation finished",
		"tenant", tenantRequest.Name,
		"duration", time.Since(start),
	)

	return finalize(rsp, xr, desired, tenantRequest.Name)
}

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

func fatal(rsp *fnv1.RunFunctionResponse, err error, msg string) (*fnv1.RunFunctionResponse, error) {
	response.Fatal(rsp, xperrors.Wrap(err, msg))
	return rsp, nil
}

func fail(rsp *fnv1.RunFunctionResponse, xr *resource.Composite, phase string, err error, msg string) (*fnv1.RunFunctionResponse, error) {
	SetPhase(xr, phase)
	response.Fatal(rsp, xperrors.Wrap(err, msg))
	return done(rsp, xr)
}

func done(rsp *fnv1.RunFunctionResponse, xr *resource.Composite) (*fnv1.RunFunctionResponse, error) {
	xr.Resource.SetManagedFields(nil)
	_ = response.SetDesiredCompositeResource(rsp, xr)
	return rsp, nil
}

func finalize(
	rsp *fnv1.RunFunctionResponse,
	xr *resource.Composite,
	desired map[resource.Name]*resource.DesiredComposed,
	name string,
) (*fnv1.RunFunctionResponse, error) {

	xr.Resource.SetManagedFields(nil)

	if err := response.SetDesiredCompositeResource(rsp, xr); err != nil {
		response.Fatal(rsp, xperrors.Wrap(err, "cannot set desired composite resource"))
		return rsp, nil
	}

	if err := response.SetDesiredComposedResources(rsp, desired); err != nil {
		response.Fatal(rsp, xperrors.Wrap(err, "cannot set desired composed resources"))
		return rsp, nil
	}

	response.Normal(rsp, fmt.Sprintf("Tenant %q created", name))

	return rsp, nil
}
