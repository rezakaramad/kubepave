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
	"github.com/crossplane/function-sdk-go/response"

	"github.com/crossplane/function-tenantrequest-renderer/internal/approval"
	"github.com/crossplane/function-tenantrequest-renderer/internal/github"
	"github.com/crossplane/function-tenantrequest-renderer/internal/model"
	"github.com/crossplane/function-tenantrequest-renderer/internal/pdns"
	"github.com/crossplane/function-tenantrequest-renderer/internal/render"
	"github.com/crossplane/function-tenantrequest-renderer/internal/status"
	"github.com/crossplane/function-tenantrequest-renderer/internal/validation"

	ctrlclient "sigs.k8s.io/controller-runtime/pkg/client"
)

type Function struct {
	fnv1.UnimplementedFunctionRunnerServiceServer
	log logging.Logger

	exportRepoURL      string
	exportRepoBranch   string
	exportRepoBasePath string

	crossplaneNamespace string

	workloadClusters []model.Cluster

	kube ctrlclient.Client
	pdns pdns.Client

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
	// Load XR
	// ---------------------------------------------------------------------
	xr, err := request.GetObservedCompositeResource(req)
	if err != nil {
		return fatal(rsp, err, "cannot get observed TenantRequest")
	}

	// ---------------------------------------------------------------------
	// Parse model
	// ---------------------------------------------------------------------
	tenantRequest, err := model.FromObservedXR(xr)
	if err != nil {
		return fail(rsp, xr, status.PhaseFailed, err, "cannot parse TenantRequest")
	}

	log = log.WithValues("tenant", tenantRequest.Name)

	// ---------------------------------------------------------------------
	// Validation
	// ---------------------------------------------------------------------
	status.SetPhase(xr, status.PhaseValidating)

	if verr := validation.Validate(ctx, xr, validation.Deps{
		Kube:       f.kube,
		PDNS:       f.pdns,
		BaseDomain: f.dnsBaseDomain,
	}); verr != nil {

		if verr.Retryable {
			status.SetPhase(xr, status.PhaseValidating)
		} else {
			status.SetPhase(xr, status.PhaseFailed)
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
	// Approval
	// ---------------------------------------------------------------------
	if !approval.IsApproved(xr) {
		status.SetPhase(xr, status.PhasePendingApproval)

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
	// Desired resources
	// ---------------------------------------------------------------------
	desired, err := request.GetDesiredComposedResources(req)
	if err != nil {
		return fail(rsp, xr, status.PhaseFailed, err, "cannot get desired composed resources")
	}

	// Build tenant object
	tenantObj := render.BuildTenantObject(tenantRequest)

	// Bundle YAML
	content, err := render.BundleYAML(tenantObj)
	if err != nil {
		return fail(rsp, xr, status.PhaseFailed, err, "cannot bundle YAML")
	}

	// Build RepositoryFile
	repoFile, err := github.BuildRepositoryFile(
		tenantRequest.Name,
		content,
		github.Config{
			Namespace:          f.crossplaneNamespace,
			ProviderConfigName: "github-rezakaramad",
			Repository:         f.exportRepoURL,
			Branch:             f.exportRepoBranch,
			BasePath:           f.exportRepoBasePath,
			FileName:           "request.yaml",
			CommitAuthor:       "crossplane",
			CommitEmail:        "platform@rezakara.demo",
		},
	)
	if err != nil {
		return fail(rsp, xr, status.PhaseFailed, err, "cannot build RepositoryFile")
	}

	desired[resource.Name("tenant-file")] = &resource.DesiredComposed{
		Resource: repoFile,
	}

	// ---------------------------------------------------------------------
	// Final status
	// ---------------------------------------------------------------------
	status.SetPhase(xr, status.PhaseReady)

	response.ConditionTrue(rsp, "Ready", "GitWritten").
		WithMessage("Tenant configuration written to Git").
		TargetCompositeAndClaim()

	response.ConditionTrue(rsp, "Synced", "GitWritten").
		WithMessage("Tenant config available in Git").
		TargetCompositeAndClaim()

	log.Info("Reconciliation finished", "duration", time.Since(start))

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
	status.SetPhase(xr, phase)
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

	_ = response.SetDesiredCompositeResource(rsp, xr)
	_ = response.SetDesiredComposedResources(rsp, desired)

	response.Normal(rsp, fmt.Sprintf("Rendered TenantRequest %q to Git", name))

	return rsp, nil
}
