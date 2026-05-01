// Package v1beta1 contains the input type for this Function
// +kubebuilder:object:generate=true
// +groupName=platform.rezakara.demo
// +versionName=v1beta1
package v1beta1

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

// Input is the configuration passed to this Function from the Composition
// pipeline step. It configures the platform validation settings used by the
// tenant validator.
//
// +kubebuilder:object:root=true
// +kubebuilder:storageversion
// +kubebuilder:resource:categories=crossplane
type Input struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	// DNS configures DNS validation behavior.
	DNS DNSInput `json:"dns"`

	// Clusters lists the workload clusters and prefixes the platform exposes.
	// +kubebuilder:validation:MinItems=1
	Clusters []ClusterInput `json:"clusters"`
}

// DNSInput configures DNS validation behavior.
type DNSInput struct {
	// BaseDomain is the DNS suffix used when validating tenant hostnames.
	// +kubebuilder:validation:MinLength=1
	BaseDomain string `json:"baseDomain"`
}

// ClusterInput identifies a workload cluster and its prefix.
type ClusterInput struct {
	// Name is the logical workload cluster name.
	// +kubebuilder:validation:MinLength=1
	Name string `json:"name"`

	// Prefix is the DNS/environment prefix associated with the cluster.
	// +kubebuilder:validation:MinLength=1
	Prefix string `json:"prefix"`
}
