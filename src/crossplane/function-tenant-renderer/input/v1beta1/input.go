// Package v1beta1 contains the input type for this Function
// +kubebuilder:object:generate=true
// +groupName=platform.rezakara.demo
// +versionName=v1beta1
package v1beta1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// This isn't a custom resource, in the sense that we never install its CRD.
// It is a KRM-like object, so we generate a CRD to describe its schema.

// Input is the configuration passed to this Function from the Composition
// pipeline step. It configures the tenant bindings that should be rendered
// into the GitOps application.
//
// +kubebuilder:object:root=true
// +kubebuilder:storageversion
// +kubebuilder:resource:categories=crossplane
type Input struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	// Github configures how rendered manifests are written to the export repository.
	// +optional
	Github GithubInput `json:"github,omitempty"`

	// Azure configures Entra-specific rendering behavior.
	// +optional
	Azure AzureInput `json:"azure,omitempty"`

	// Tenant contains the binding assignments rendered into the GitOps chart.
	Tenant TenantInput `json:"tenant"`
}

// GithubInput configures the Crossplane RepositoryFile resource written by this function.
type GithubInput struct {
	// ProviderConfigName references the GitHub provider config used for RepositoryFile resources.
	// +optional
	ProviderConfigName string `json:"providerConfigName,omitempty"`

	// CommitAuthor is the git author name used for rendered commits.
	// +optional
	CommitAuthor string `json:"commitAuthor,omitempty"`

	// CommitEmail is the git author email used for rendered commits.
	// +optional
	CommitEmail string `json:"commitEmail,omitempty"`
}

// AzureInput configures how Entra principals are provisioned.
type AzureInput struct {
	// PrincipalType selects whether the function creates Entra groups or users.
	// +kubebuilder:validation:Enum=group;user
	// +optional
	PrincipalType string `json:"principalType,omitempty"`

	// UserPrincipalDomain is used when principalType=user and the function creates
	// AzureAD users.
	// +optional
	UserPrincipalDomain string `json:"userPrincipalDomain,omitempty"`
}

// TenantInput configures tenant-specific bindings rendered by the function.
type TenantInput struct {
	// Bindings associates a role with a cluster/environment pair.
	// +kubebuilder:validation:MinItems=1
	Bindings []BindingInput `json:"bindings"`
}

// BindingInput identifies a single tenant binding.
type BindingInput struct {
	// Name is the logical role name for the binding.
	// +kubebuilder:validation:MinLength=1
	Name string `json:"name"`

	// Cluster is the ArgoCD destination cluster name.
	// +kubebuilder:validation:MinLength=1
	Cluster string `json:"cluster"`

	// EnvironmentPrefix is the short environment label used in resource naming
	// (e.g. dev, test, prod).
	// +kubebuilder:validation:MinLength=1
	EnvironmentPrefix string `json:"environmentPrefix"`
}
