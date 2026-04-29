// Package v1beta1 contains the input type for this Function
// +kubebuilder:object:generate=true
// +groupName=template.fn.crossplane.io
// +versionName=v1beta1
package v1beta1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// This isn't a custom resource, in the sense that we never install its CRD.
// It is a KRM-like object, so we generate a CRD to describe its schema.

// Input is the configuration passed to this Function from the Composition
// pipeline step. It configures which workload clusters to deploy to and the
// RBAC roles applied to the ArgoCD project for the tenant.
//
// +kubebuilder:object:root=true
// +kubebuilder:storageversion
// +kubebuilder:resource:categories=crossplane
type Input struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	// Clusters is the list of workload clusters this function deploys to.
	// At least one cluster must be provided.
	// +kubebuilder:validation:MinItems=1
	Clusters []ClusterInput `json:"clusters"`

	// RBAC configures the ArgoCD project roles applied to the tenant.
	// If omitted, default admin and viewer roles are applied.
	// +optional
	RBAC RBACInput `json:"rbac,omitempty"`
}

// ClusterInput identifies a single workload cluster.
type ClusterInput struct {
	// Name is the ArgoCD destination cluster name.
	// +kubebuilder:validation:MinLength=1
	Name string `json:"name"`

	// EnvironmentPrefix is the short environment label used in resource naming
	// (e.g. dev, test, prod).
	// +kubebuilder:validation:MinLength=1
	EnvironmentPrefix string `json:"environmentPrefix"`
}

// RBACInput configures the ArgoCD project roles for the tenant.
type RBACInput struct {
	// Roles is the list of ArgoCD project roles to create.
	// +optional
	Roles []RoleInput `json:"roles,omitempty"`
}

// RoleInput defines an ArgoCD project role.
type RoleInput struct {
	// Name is the role name.
	// +kubebuilder:validation:MinLength=1
	Name string `json:"name"`

	// Policies defines the ArgoCD RBAC policies attached to this role.
	// +optional
	Policies []PolicyInput `json:"policies,omitempty"`
}

// PolicyInput defines a single ArgoCD RBAC policy entry.
type PolicyInput struct {
	// Resource is the ArgoCD resource type (e.g. applications, logs).
	// +kubebuilder:validation:MinLength=1
	Resource string `json:"resource"`

	// Actions is the list of permitted actions on the resource.
	// +kubebuilder:validation:MinItems=1
	Actions []string `json:"actions"`
}
