// Package main implements a Crossplane Composition Function for TenantRequest.
//
// -----------------------------------------------------------------------------
// Overview
// -----------------------------------------------------------------------------
//
// This function processes TenantRequest resources and performs:
//
//  1. Validation (input correctness, uniqueness, DNS availability)
//  2. Approval gating (manual or automated approval via status.conditions)
//  3. GitOps publication (writes tenant configuration to Git)
//
// The function does NOT provision infrastructure directly.
// Instead, it follows a GitOps model:
//
//	TenantRequest → Crossplane Function → Git (RepositoryFile)
//	              → Argo CD → Helm → Infrastructure
//
// -----------------------------------------------------------------------------
// Responsibilities
// -----------------------------------------------------------------------------
//
// ✔ Validate tenant input (name, DNS, ownership, repos)
// ✔ Enforce uniqueness across existing tenants
// ✔ Check DNS availability via PowerDNS
// ✔ Gate provisioning on approval
// ✔ Generate tenant configuration as YAML
// ✔ Push configuration to Git via RepositoryFile
//
// -----------------------------------------------------------------------------
// Non-Responsibilities
// -----------------------------------------------------------------------------
//
// ✘ Does NOT create Tenant resources directly
// ✘ Does NOT wait for infrastructure readiness
// ✘ Does NOT reconcile downstream resources (Argo CD does)
//
// -----------------------------------------------------------------------------
// Phases (status.phase)
// -----------------------------------------------------------------------------
//
//	Validating      → Input validation in progress
//	PendingApproval → Waiting for approval
//	Ready           → Configuration committed to Git
//	Failed          → Validation failed (non-retryable)
//
// Note: "Provisioning" phase is retained for backward compatibility but is not
// used in GitOps mode.
//
// -----------------------------------------------------------------------------
// Conditions
// -----------------------------------------------------------------------------
//
//	Valid    → Input validation result
//	Approved → Approval gate
//	Ready    → Git commit prepared
//	Synced   → Desired Git state matches XR spec
package main

import (
	"context"
	"fmt"
	"time"

	"github.com/crossplane/crossplane-runtime/v2/pkg/errors"
	"github.com/crossplane/function-sdk-go/logging"
	fnv1 "github.com/crossplane/function-sdk-go/proto/v1"
	"github.com/crossplane/function-sdk-go/request"
	"github.com/crossplane/function-sdk-go/resource"
	"github.com/crossplane/function-sdk-go/resource/composed"
	"github.com/crossplane/function-sdk-go/response"
	ctrlclient "sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	PhaseValidating      = "Validating"
	PhasePendingApproval = "PendingApproval"
	PhaseReady           = "Ready"
	PhaseFailed          = "Failed"
)

// Function is this service's implementation of the Crossplane Function gRPC server.
// The important requirement is not the struct name itself, but that it provides
// a RunFunction(...) method with the expected signature so Crossplane can call it.

// Embedding UnimplementedFunctionRunnerServiceServer helps satisfy the generated
// gRPC service interface and is the normal Go pattern used by the SDK examples.
// The remaining fields are this function's own dependencies, such as logging,
// Kubernetes access, PowerDNS access, and local config needed by RunFunction(...).
type Function struct {
	fnv1.UnimplementedFunctionRunnerServiceServer
	log logging.Logger

	kube ctrlclient.Client
	pdns PDNSClient

	dnsBaseDomain string

	// Git configuration
	gitRepository string
	gitBranch     string
	gitBasePath   string
}

// RunFunction is the method Crossplane calls to execute this function (tenantrequest).
// It takes the incoming request, performs the function's logic,
// and returns the response Crossplane should use next.
// RunFunction executes reconciliation logic for TenantRequest.
func (f *Function) RunFunction(ctx context.Context, req *fnv1.RunFunctionRequest) (*fnv1.RunFunctionResponse, error) {

	// Record when this reconciliation started so we can measure and log
	// the total time taken at the end with time.Since(start).
	start := time.Now()

	// Log start of function execution with a request tag for tracing this run.
	f.log.Info(
		"Running function",
		"tag",
		req.GetMeta().GetTag(),
	)

	// This is the object Crossplane expects the function to return.
	// It copies metadata from the request so Crossplane can correlate the response with the correct pipeline execution.
	// TTL says how long this response should remain (1 minute by default) valid before the function should be called again.
	rsp := response.To(req, response.DefaultTTL)

	// Load the TenantRequest (Composite Resource)
	xr, err := request.GetObservedCompositeResource(req)
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot get XR"))
		return rsp, nil
	}

	// xr.Resource is the unstructured Kubernetes object representing the XR.
	// Conceptually:
	// xr
	//  └── Resource
	//       ├── metadata
	//       ├── spec
	//       └── status
	name, err := xr.Resource.GetString("spec.name")
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot read spec.name"))
		return rsp, nil
	}

	dnsName, err := xr.Resource.GetString("spec.dnsName")
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot read spec.dnsName"))
		return rsp, nil
	}

	envPrefix, err := xr.Resource.GetString("spec.environmentPrefix")
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot read spec.environmentPrefix"))
		return rsp, nil
	}

	displayName, err := xr.Resource.GetString("spec.displayName")
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot read spec.displayName"))
		return rsp, nil
	}

	team, err := xr.Resource.GetString("spec.owner.team")
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot read spec.owner.team"))
		return rsp, nil
	}

	email, err := xr.Resource.GetString("spec.owner.email")
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot read spec.owner.email"))
		return rsp, nil
	}

	syncRepos, err := xr.Resource.GetValue("spec.argocd.syncRepos")
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot read spec.argocd.syncRepos"))
		return rsp, nil
	}

	f.log.Info(
		"Reconciling tenant",
		"tenant", name,
		"dnsName", dnsName,
		"team", team,
	)

	// ---------------------------------------------------------------------
	// Validation
	// ---------------------------------------------------------------------
	// This function follows a GitOps-driven state machine.
	//
	// It does NOT wait for infrastructure readiness.
	// Its responsibility ends once the desired state is written to Git.
	//
	// Flow Overview:
	//
	// START
	//   ↓
	// Validating
	//   ↓ (validation fails, non-retryable)
	// Failed
	//   ↓ (validation fails, retryable)
	// Validating (retry)
	//   ↓ (validation passes)
	// PendingApproval
	//   ↓ (not approved)
	// PendingApproval (loop)
	//   ↓ (approved)
	// Publishing (Git desired state is generated)
	//   ↓
	// Ready
	//
	// Notes:
	// - "Ready" means the tenant configuration has been handed off for Git publication
	// - Argo CD is responsible for applying and reconciling actual infrastructure
	_ = xr.Resource.SetValue("status.phase", PhaseValidating)

	// Call the Function's validation logic to validate the XR.
	if validationError := f.validate(ctx, xr); validationError != nil {
		f.log.Info(
			"TenantRequest validation failed",
			"reason", validationError.Reason,
			"message", validationError.Message,
		)

		// Retryability is decided explicitly when returning ValidationError:
		// system/temporary errors are marked retryable,
		// while user/config errors are marked non-retryable.
		if validationError.Retryable {
			_ = xr.Resource.SetValue("status.phase", PhaseValidating)
		} else {
			_ = xr.Resource.SetValue("status.phase", PhaseFailed)
		}

		// Set Valid=false with reason on the XR.
		// This is what the user will see when they kubectl describe the XR or claim, and it should explain why validation failed.
		// status:
		//   conditions:
		//     - lastTransitionTime: "2026-04-02T19:57:07Z"
		//       message: dns 'pay' already in use
		//       reason: DnsNameTaken
		//       status: "False"
		//       type: Valid
		response.ConditionFalse(rsp, "Valid", validationError.Reason).
			WithMessage(validationError.Message).
			TargetCompositeAndClaim()

		// Also mark Ready=false because invalid input blocks provisioning,
		// even though the specific issue is captured by the Valid condition.
		response.ConditionFalse(rsp, "Ready", "ValidationFailed").
			WithMessage("TenantRequest is not valid, provisioning is blocked").
			TargetCompositeAndClaim()

		// Remove Kubernetes internal metadata and return the updated XR
		// so Crossplane applies the new status/conditions.
		xr.Resource.SetManagedFields(nil)

		// Return the updated XR as desired state:
		// observed = what currently exists
		// desired = what should exist
		// Apply these updates to the XR so the new status and conditions are written back to Kubernetes.
		_ = response.SetDesiredCompositeResource(rsp, xr)

		return rsp, nil
	}

	// Mark the resource as valid (Valid=true) after successful validation
	// and apply this condition to both the Composite Resource and its claim.
	response.ConditionTrue(rsp, "Valid", "ValidationPassed").
		TargetCompositeAndClaim()

	// ---------------------------------------------------------------------
	// Approval gate
	// ---------------------------------------------------------------------
	// If the TenantRequest has not been approved yet, reconciliation pauses here.
	// The resource phase is set to PendingApproval and the Approved/Ready
	// conditions are marked as false with the reason WaitingForApproval.
	// No further processing happens until approval is granted.
	if !isApproved(xr) {
		f.log.Info("TenantRequest waiting for approval", "name", name)

		// status:
		//   phase: PendingApproval
		_ = xr.Resource.SetValue("status.phase", PhasePendingApproval)

		// Mark the request as not approved yet.
		// status:
		//   conditions:
		//   - lastTransitionTime: "2026-04-03T22:26:14Z"
		//     reason: WaitingForApproval
		//     status: "False"
		//     type: Approved
		response.ConditionFalse(rsp, "Approved", "WaitingForApproval").
			TargetCompositeAndClaim()

		// The resource cannot report Ready while approval is pending.
		// Note: Ready is also managed by Crossplane and may be overridden.
		// This is informational; use Approved/phase for actual control logic.
		response.ConditionFalse(rsp, "Ready", "WaitingForApproval").
			TargetCompositeAndClaim()

		// Remove Kubernetes internal metadata and return the updated XR
		// so Crossplane applies the new status/conditions.
		xr.Resource.SetManagedFields(nil)

		// Apply these updates to the XR so the new status and conditions are written back to Kubernetes.
		_ = response.SetDesiredCompositeResource(rsp, xr)

		return rsp, nil
	}

	// The approval gate has been satisfied; mark the request as approved.
	response.ConditionTrue(rsp, "Approved", "Approved").
		TargetCompositeAndClaim()

	// GitOps flow:
	//   1. Generate tenant input data (values.yaml)
	//   2. Commit it to Git via RepositoryFile
	//   3. Argo CD consumes it and deploys resources
	desired, err := request.GetDesiredComposedResources(req)
	if err != nil {
		response.Fatal(rsp, err)
		return rsp, nil
	}

	// Create the desired RepositoryFile that publishes tenant metadata to Git (only after Valid + Approved)
	repoFile := composed.New()
	repoFile.SetAPIVersion("github.crossplane.io/v1alpha1")
	repoFile.SetKind("RepositoryFile")
	repoFile.SetName(fmt.Sprintf("tenant-metadata-%s", name))

	content := buildTenantValuesYAML(
		name,
		dnsName,
		envPrefix,
		displayName,
		team,
		email,
		syncRepos,
	)

	// Stop reconciliation if tenant metadata cannot be rendered to YAML.
	if content == "" {
		response.Fatal(rsp, fmt.Errorf("failed to generate tenant YAML"))
		return rsp, nil
	}

	filePath := fmt.Sprintf("%s/%s/values.yaml", f.gitBasePath, name)

	f.log.Info(
		"Publishing tenant configuration",
		"tenant", name,
		"repository", f.gitRepository,
		"branch", f.gitBranch,
		"path", filePath,
	)

	if err := repoFile.SetValue("spec.forProvider", map[string]any{
		"repository": f.gitRepository,
		"branch":     f.gitBranch,
		"file":       filePath,
		"content":    content,
	}); err != nil {
		response.Fatal(rsp, err)
		return rsp, nil
	}

	desired[resource.Name("tenant-file")] = &resource.DesiredComposed{
		Resource: repoFile,
		Ready:    resource.ReadyUnspecified,
	}

	_ = xr.Resource.SetValue("status.phase", PhaseReady)
	_ = xr.Resource.SetValue("status.tenantName", name)

	response.ConditionTrue(rsp, "Ready", "GitCommitted").
		WithMessage("Tenant configuration written to Git").
		TargetCompositeAndClaim()

	response.ConditionTrue(rsp, "Published", "GitWritten").
		WithMessage("Tenant config is available in Git repository").
		TargetCompositeAndClaim()

	xr.Resource.SetManagedFields(nil)

	_ = response.SetDesiredCompositeResource(rsp, xr)

	if err := response.SetDesiredComposedResources(rsp, desired); err != nil {
		response.Fatal(rsp, err)
		return rsp, nil
	}

	f.log.Info(
		"Reconciliation finished",
		"tenant", name,
		"duration", time.Since(start),
	)

	return rsp, nil
}
