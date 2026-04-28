package main

import (
	"context"
	"fmt"

	xperrors "github.com/crossplane/crossplane-runtime/pkg/errors"
	"github.com/crossplane/function-sdk-go/logging"
	fnv1 "github.com/crossplane/function-sdk-go/proto/v1"
	"github.com/crossplane/function-sdk-go/request"
	"github.com/crossplane/function-sdk-go/resource"
	"github.com/crossplane/function-sdk-go/resource/composed"
	"github.com/crossplane/function-sdk-go/response"

	"github.com/crossplane/function-tenant-renderer/internal/github"
	"github.com/crossplane/function-tenant-renderer/internal/model"
	"github.com/crossplane/function-tenant-renderer/internal/render"
	"github.com/crossplane/function-tenant-renderer/internal/status"
)

type Function struct {
	fnv1.UnimplementedFunctionRunnerServiceServer
	log logging.Logger

	// Git export (final bundle destination)
	exportRepoURL      string
	exportRepoBranch   string
	exportRepoBasePath string

	// Crossplane namespace
	crossplaneNamespace string

	// Baseline Application source (ArgoCD)
	baselineRepoURL      string
	baselineRepoBranch   string
	baselineRepoBasePath string

	// GitOps Application source (ArgoCD)
	gitopsRepoURL      string
	gitopsRepoBranch   string
	gitopsRepoBasePath string

	// External dependency
	argocdAppID string
}

func NewFunction(l logging.Logger) *Function {
	return &Function{log: l}
}

func (f *Function) RunFunction(
	_ context.Context,
	req *fnv1.RunFunctionRequest,
) (*fnv1.RunFunctionResponse, error) {

	log := f.log.WithValues("tag", req.GetMeta().GetTag())
	log.Info("Running function-tenant-renderer")

	rsp := response.To(req, response.DefaultTTL)

	// ---------------------------------------------------------------------
	// Load XR
	// ---------------------------------------------------------------------
	observedXR, err := request.GetObservedCompositeResource(req)
	if err != nil {
		response.Fatal(rsp, xperrors.Wrap(err, "cannot get observed composite resource"))
		return rsp, nil
	}

	setPhase(observedXR, "Provisioning")

	// ---------------------------------------------------------------------
	// 2. Desired state
	// ---------------------------------------------------------------------
	desired, err := request.GetDesiredComposedResources(req)
	if err != nil {
		setPhase(observedXR, "Failed")
		response.Fatal(rsp, xperrors.Wrap(err, "cannot get desired composed resources"))
		return rsp, nil
	}

	// ---------------------------------------------------------------------
	// Parse Tenant
	// ---------------------------------------------------------------------
	tenant, err := model.FromObservedXR(observedXR)
	if err != nil {
		setPhase(observedXR, "Failed")
		response.Fatal(rsp, xperrors.Wrap(err, "cannot parse tenant spec"))
		return rsp, nil
	}

	// ---------------------------------------------------------------------
	// Parse input config
	// ---------------------------------------------------------------------
	var input model.PlatformConfig
	if err := request.GetInput(req, &input); err != nil {
		setPhase(observedXR, "Failed")
		response.Fatal(rsp, xperrors.Wrap(err, "cannot parse function input"))
		return rsp, nil
	}

	// Validate input
	if err := input.Validate(); err != nil {
		setPhase(observedXR, "Failed")
		response.Fatal(rsp, xperrors.Wrap(err, "invalid input"))
		return rsp, nil
	}

	// Manage RBAC and cluster resolution (defaults vs input)
	model.ResolveRBAC(&tenant, &input)
	clusters := input.ToClusters()
	log.Info("Resolved clusters", "clusters", clusters)
	log.Info("Resolved roles", "roles", tenant.Roles)

	// ---------------------------------------------------------------------
	// Render ArgoCD apps
	// ---------------------------------------------------------------------

	// Baseline apps (one per cluster)
	baselineApps, err := render.BuildBaselineApplications(
		tenant,
		clusters,
		f.baselineRepoURL,
		f.baselineRepoBranch,
		f.baselineRepoBasePath,
	)
	if err != nil {
		setPhase(observedXR, "Failed")
		response.Fatal(rsp, xperrors.Wrap(err, "cannot build baseline applications"))
		return rsp, nil
	}

	// GitOps app (management cluster)
	gitopsApp, err := render.BuildGitopsApplication(
		tenant,
		clusters,
		f.gitopsRepoURL,
		f.gitopsRepoBranch,
		f.gitopsRepoBasePath,
	)
	if err != nil {
		setPhase(observedXR, "Failed")
		response.Fatal(rsp, xperrors.Wrap(err, "cannot build gitops application"))
		return rsp, nil
	}

	// ---------------------------------------------------------------------
	// Combine resources (deterministic order)
	// ---------------------------------------------------------------------
	resources := []*composed.Unstructured{
		gitopsApp,
	}
	resources = append(resources, baselineApps...)

	// ---------------------------------------------------------------------
	// Bundle to YAML
	// ---------------------------------------------------------------------
	// Serializes all rendered resources into a single multi-document YAML string.
	content, err := render.BundleYAML(resources...)
	if err != nil {
		setPhase(observedXR, "Failed")
		response.Fatal(rsp, xperrors.Wrap(err, "cannot bundle resources"))
		return rsp, nil
	}

	// ---------------------------------------------------------------------
	// Git export (RepositoryFile)
	// ---------------------------------------------------------------------
	repoFile := github.BuildRepositoryFile(
		tenant,
		content,
		github.Config{
			Namespace:          f.crossplaneNamespace,
			ProviderConfigName: "github-rezakaramad",
			Repository:         f.exportRepoURL,
			Branch:             f.exportRepoBranch,
			BasePath:           f.exportRepoBasePath,
			CommitAuthor:       "Crossplane",
			CommitEmail:        "crossplane@local",
		},
	)

	// Set the rendered RepositoryFile as the desired composed resource.
	// This will instruct Crossplane to create/update the specified file in Git
	// with the rendered content, and then ArgoCD will pick up the changes and deploy
	// to the clusters.
	desired["tenant-rendered-manifests"] = &resource.DesiredComposed{
		Resource: repoFile,
	}

	// Update desired composed resources in the response
	if err := response.SetDesiredComposedResources(rsp, desired); err != nil {
		setPhase(observedXR, "Failed")
		response.Fatal(rsp, xperrors.Wrap(err, "cannot set desired composed resources"))
		return rsp, nil
	}

	// ---------------------------------------------------------------------
	// 8. Update XR status
	// ---------------------------------------------------------------------
	if err := status.SetXRRendered(rsp, observedXR, tenant, status.RenderSummary{
		Resources: len(resources),
	}); err != nil {
		setPhase(observedXR, "Failed")
		response.Fatal(rsp, xperrors.Wrap(err, "cannot set xr status"))
		return rsp, nil
	}

	// ---------------------------------------------------------------------
	// Done
	// ---------------------------------------------------------------------
	response.Normal(rsp, fmt.Sprintf("Rendered tenant %q manifests to Git", tenant.Name))

	return rsp, nil
}

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------
func setPhase(xr *resource.Composite, phase string) {
	_ = xr.Resource.SetValue("status.phase", phase)
}
