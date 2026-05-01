package main

import (
	"context"
	"time"

	xperrors "github.com/crossplane/crossplane-runtime/v2/pkg/errors"
	"github.com/crossplane/function-sdk-go/logging"
	fnv1 "github.com/crossplane/function-sdk-go/proto/v1"
	"github.com/crossplane/function-sdk-go/request"
	"github.com/crossplane/function-sdk-go/resource"
	"github.com/crossplane/function-sdk-go/response"
	inputv1beta1 "github.com/crossplane/function-tenant-validator/input/v1beta1"
	"github.com/crossplane/function-tenant-validator/model"

	xtenant "github.com/rezakaramad/kubepave/src/crossplane/xr-types/tenant"

	ctrlclient "sigs.k8s.io/controller-runtime/pkg/client"
)

type Function struct {
	fnv1.UnimplementedFunctionRunnerServiceServer
	log logging.Logger

	kube ctrlclient.Client
	pdns PDNSClient
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
	log.Info("Running function-tenant-validator")

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

	log = log.WithValues("tenant", tenantRequest.GetName())

	var input inputv1beta1.Input
	if err := request.GetInput(req, &input); err != nil {
		return fail(rsp, xr, PhaseFailed, err, "cannot parse function input")
	}
	if input.DNS.BaseDomain == "" {
		return fail(rsp, xr, PhaseFailed, xperrors.New("dns.baseDomain is required"), "cannot parse function input")
	}
	if len(input.Clusters) == 0 {
		return fail(rsp, xr, PhaseFailed, xperrors.New("clusters is required"), "cannot parse function input")
	}

	workloadClusters := make([]xtenant.Cluster, 0, len(input.Clusters))
	for _, cluster := range input.Clusters {
		if cluster.Name == "" || cluster.Prefix == "" {
			return fail(rsp, xr, PhaseFailed, xperrors.New("clusters entries require name and prefix"), "cannot parse function input")
		}
		workloadClusters = append(workloadClusters, xtenant.Cluster{
			Name:   cluster.Name,
			Prefix: cluster.Prefix,
		})
	}

	// ---------------------------------------------------------------------
	// 3. Validation
	// ---------------------------------------------------------------------
	SetPhase(xr, PhaseValidating)

	if verr := Validate(ctx, tenantRequest, Deps{
		Kube:             f.kube,
		PDNSClient:       f.pdns,
		BaseDomain:       input.DNS.BaseDomain,
		WorkloadClusters: workloadClusters,
	}); verr != nil {

		if verr.Retryable {
			SetPhase(xr, PhaseValidating)
		} else {
			SetPhase(xr, PhaseFailed)
		}

		response.ConditionFalse(rsp, "Valid", verr.Reason).
			WithMessage(verr.Message).
			TargetComposite()

		response.ConditionFalse(rsp, "Ready", "ValidationFailed").
			WithMessage("TenantRequest is not valid").
			TargetComposite()

		log.Info("Validation failed", "reason", verr.Reason)

		return done(rsp, xr)
	}

	response.ConditionTrue(rsp, "Valid", "ValidationPassed").
		TargetComposite()

	// ---------------------------------------------------------------------
	// 4. Approval
	// ---------------------------------------------------------------------
	if !IsApproved(tenantRequest) {
		SetPhase(xr, PhasePendingApproval)

		response.ConditionFalse(rsp, "Approved", "WaitingForApproval").
			TargetComposite()

		response.ConditionFalse(rsp, "Ready", "WaitingForApproval").
			TargetComposite()

		log.Info("Waiting for approval")

		return done(rsp, xr)
	}

	response.ConditionTrue(rsp, "Approved", "Approved").
		TargetComposite()

	// ---------------------------------------------------------------------
	// 5. Status — approved, hand off to next pipeline step
	// ---------------------------------------------------------------------
	SetPhase(xr, PhaseProvisioning)

	response.ConditionTrue(rsp, "Ready", "Provisioning").
		WithMessage("Tenant approved, provisioning in progress").
		TargetComposite()

	log.Info("Reconciliation finished",
		"tenant", tenantRequest.GetName(),
		"duration", time.Since(start),
	)

	return done(rsp, xr)
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
