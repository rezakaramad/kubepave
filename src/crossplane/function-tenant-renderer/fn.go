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

	inputv1beta1 "github.com/crossplane/function-tenant-renderer/input/v1beta1"
	xtenant "github.com/rezakaramad/kubepave/src/crossplane/xr-types/tenant"
	"k8s.io/apimachinery/pkg/runtime"
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


	// ---------------------------------------------------------------------
	// 2. Desired state
	// ---------------------------------------------------------------------
	desired, err := request.GetDesiredComposedResources(req)
	if err != nil {
		response.Fatal(rsp, xperrors.Wrap(err, "cannot get desired composed resources"))
		return rsp, nil
	}

	// ---------------------------------------------------------------------
	// Parse Tenant
	// ---------------------------------------------------------------------
	var xd xtenant.Tenant
	if err := runtime.DefaultUnstructuredConverter.FromUnstructured(
		observedXR.Resource.UnstructuredContent(), &xd,
	); err != nil {
		response.Fatal(rsp, xperrors.Wrap(err, "cannot convert XR to Tenant"))
		return rsp, nil
	}

	if xd.Spec.DisplayName == "" {
		xd.Spec.DisplayName = xd.GetName()
	}
	tenant := TenantSpec{
		Tenant:    xd,
		SyncRepos: []string{fmt.Sprintf("https://github.com/fluxdojo/platform-deploy-%s", xd.GetName())},
	}

	log = log.WithValues("tenant", tenant.GetName())

	// ---------------------------------------------------------------------
	// Parse input config
	// ---------------------------------------------------------------------
	var input inputv1beta1.Input
	if err := request.GetInput(req, &input); err != nil {
		response.Fatal(rsp, xperrors.Wrap(err, "cannot parse function input"))
		return rsp, nil
	}

	// Manage RBAC and cluster resolution
	tenant.Roles = input.RBAC.Roles
	clusters := make([]xtenant.Cluster, 0, len(input.Clusters))
	for _, c := range input.Clusters {
		clusters = append(clusters, xtenant.Cluster{Name: c.Name, Prefix: c.EnvironmentPrefix})
	}
	log.Info("Resolved clusters", "clusters", clusters)
	log.Info("Resolved roles", "roles", tenant.Roles)

	// ---------------------------------------------------------------------
	// Render ArgoCD apps
	// ---------------------------------------------------------------------

	// Baseline apps (one per cluster)
	baselineApps, err := buildBaselineApplications(
		tenant,
		clusters,
		f.baselineRepoURL,
		f.baselineRepoBranch,
		f.baselineRepoBasePath,
	)
	if err != nil {
		response.Fatal(rsp, xperrors.Wrap(err, "cannot build baseline applications"))
		return rsp, nil
	}

	// GitOps app (management cluster)
	gitopsApp, err := buildGitopsApplication(
		tenant,
		clusters,
		f.gitopsRepoURL,
		f.gitopsRepoBranch,
		f.gitopsRepoBasePath,
	)
	if err != nil {
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
	content, err := bundleYAML(resources...)
	if err != nil {
		response.Fatal(rsp, xperrors.Wrap(err, "cannot bundle resources"))
		return rsp, nil
	}

	// ---------------------------------------------------------------------
	// Git export (RepositoryFile)
	// ---------------------------------------------------------------------
	repoFile := buildRepositoryFile(
		tenant,
		content,
		RepositoryFileConfig{
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
		response.Fatal(rsp, xperrors.Wrap(err, "cannot set desired composed resources"))
		return rsp, nil
	}

	response.ConditionTrue(rsp, "Rendered", "Available").
		WithMessage(fmt.Sprintf("Rendered %d resources for tenant %q", len(resources), tenant.GetName())).
		TargetCompositeAndClaim()

	return rsp, nil
}
