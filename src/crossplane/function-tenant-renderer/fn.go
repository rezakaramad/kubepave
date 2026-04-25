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

	// Git configuration where we will export the rendered tenant manifests.
	exportRepoURL      string
	exportRepoBranch   string
	exportRepoBasePath string

	// Crossplane control plane namespace
	crossplaneNamespace string

	// Tenant clusters so we know what cluster names to use in the rendered ArgoCD Applications
	// Let's say we have to deploy baseline-<tenant> apps to the tenant clusters, we need to know the cluster names to set in the Application destinations.
	workloadClusters []model.Cluster

	// Git configuration where we will get the baseline-tenant helm chart to render with tenant spec values.
	baselineRepoURL      string
	baselineRepoBranch   string
	baselineRepoBasePath string

	// Git configuration where we will get the gitops-tenant helm chart to render with tenant spec values.
	gitopsRepoURL      string
	gitopsRepoBranch   string
	gitopsRepoBasePath string

	// ArgoCD Azure AD Application ID (external resource)
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

	// 1. Get observed XR
	observedXR, err := request.GetObservedCompositeResource(req)
	if err != nil {
		response.Fatal(rsp, xperrors.Wrap(err, "cannot get observed composite resource"))
		return rsp, nil
	}

	setPhase(observedXR, "Provisioning")

	// 2. Get desired state so far
	desired, err := request.GetDesiredComposedResources(req)
	if err != nil {
		setPhase(observedXR, "Failed")
		response.Fatal(rsp, xperrors.Wrap(err, "cannot get desired composed resources"))
		return rsp, nil
	}

	// 3. Parse Tenant
	tenant, err := model.FromObservedXR(observedXR)
	if err != nil {
		setPhase(observedXR, "Failed")
		response.Fatal(rsp, xperrors.Wrap(err, "cannot parse tenant spec"))
		return rsp, nil
	}

	// 4. Render resources
	// baseline application
	baselineApps, err := render.BuildBaselineApplications(
		tenant,
		f.workloadClusters,
		f.baselineRepoURL,
		f.baselineRepoBranch,
		f.baselineRepoBasePath,
	)
	if err != nil {
		setPhase(observedXR, "Failed")
		response.Fatal(rsp, xperrors.Wrap(err, "cannot build baseline applications"))
		return rsp, nil
	}

	// App RBAC (AppRole + Group + RoleAssignment)
	appRBACResources, err := render.BuildAppRBAC(
		tenant,
		f.workloadClusters,
		f.crossplaneNamespace,
		"azuread",
		f.argocdAppID,
	)
	if err != nil {
		setPhase(observedXR, "Failed")
		response.Fatal(rsp, xperrors.Wrap(err, "cannot build app rbac resources"))
		return rsp, nil
	}

	// GitOps Application (management cluster)
	gitopsApp, err := render.BuildGitopsApplication(
		tenant,
		f.gitopsRepoURL,
		f.gitopsRepoBranch,
		f.gitopsRepoBasePath,
	)
	if err != nil {
		setPhase(observedXR, "Failed")
		response.Fatal(rsp, xperrors.Wrap(err, "cannot build gitops application"))
		return rsp, nil
	}

	// 5. Combine all resources
	resources := []*composed.Unstructured{
		gitopsApp,
	}
	resources = append(resources, appRBACResources...)
	resources = append(resources, baselineApps...)

	// 6. Bundle into YAML
	content, err := render.BundleYAML(resources...)
	if err != nil {
		setPhase(observedXR, "Failed")
		response.Fatal(rsp, xperrors.Wrap(err, "cannot bundle resources"))
		return rsp, nil
	}

	// 7. Create Git RepositoryFile
	repoFile := github.BuildRepositoryFile(
		tenant,
		content,
		github.Config{
			Namespace:          f.crossplaneNamespace,
			ProviderConfigName: "github",
			Repository:         f.exportRepoURL,
			Branch:             f.exportRepoBranch,
			BasePath:           f.exportRepoBasePath,
			CommitAuthor:       "Crossplane",
			CommitEmail:        "crossplane@local",
		},
	)

	// 8. Add to desired state
	desired["tenant-rendered-manifests"] = &resource.DesiredComposed{
		Resource: repoFile,
	}

	if err := response.SetDesiredComposedResources(rsp, desired); err != nil {
		setPhase(observedXR, "Failed")
		response.Fatal(rsp, xperrors.Wrap(err, "cannot set desired composed resources"))
		return rsp, nil
	}

	// 9. Mark XR ready
	if err := status.SetXRRendered(rsp, observedXR, tenant, status.RenderSummary{
		Resources: len(resources),
	}); err != nil {
		setPhase(observedXR, "Failed")
		response.Fatal(rsp, xperrors.Wrap(err, "cannot set xr status"))
		return rsp, nil
	}

	// 10. Done
	response.Normal(rsp, fmt.Sprintf("Rendered tenant %q manifests to Git", tenant.Name))

	return rsp, nil
}

// setPhase is a helper function to set the status.phase of the XR.
// We use it to update the phase in case of errors or to set it to Ready when everything is successful.
func setPhase(xr *resource.Composite, phase string) {
	_ = xr.Resource.SetValue("status.phase", phase)
}
