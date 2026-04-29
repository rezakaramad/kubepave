package tenant

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

// Phase represents the lifecycle state of a Tenant.
//
// +kubebuilder:validation:Enum=Validating;PendingApproval;Provisioning;Ready;Failed
type Phase string

const (
	PhaseValidating      Phase = "Validating"
	PhasePendingApproval Phase = "PendingApproval"
	PhaseProvisioning    Phase = "Provisioning"
	PhaseReady           Phase = "Ready"
	PhaseFailed          Phase = "Failed"
)

// Tenant is the strongly-typed representation of the Tenant Composite Resource.
// It embeds metav1.ObjectMeta so that standard Kubernetes accessors (GetName,
// GetLabels, etc.) work directly, and runtime.DefaultUnstructuredConverter can
// deserialize the XR without a JSON round-trip.
//
// +kubebuilder:object:root=true
type Tenant struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              TenantSpec   `json:"spec"`
	Status            TenantStatus `json:"status,omitempty"`
}

// TenantSpec defines the desired state of a Tenant.
type TenantSpec struct {
	// dnsName is the base DNS label for the tenant. Immutable after creation.
	//
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=63
	// +kubebuilder:validation:Pattern=`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`
	DNSName string `json:"dnsName"`

	// displayName is a human-readable name shown in UIs.
	//
	// +kubebuilder:validation:MaxLength=128
	DisplayName string `json:"displayName,omitempty"`

	// owner identifies the team responsible for this tenant. Immutable after creation.
	Owner OwnerSpec `json:"owner"`

	// argocd contains ArgoCD-specific configuration.
	ArgoCD ArgoCDSpec `json:"argocd,omitempty"`

	// options contains optional metadata and cost allocation fields.
	Options OptionsSpec `json:"options,omitempty"`

	// approved gates provisioning. Must be set to true by a platform engineer
	// before function-tenant-renderer will create any resources.
	// Once set to true it cannot be reverted.
	//
	// +kubebuilder:default=false
	Approved bool `json:"approved,omitempty"`
}

// OwnerSpec identifies the team responsible for the tenant.
type OwnerSpec struct {
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:MaxLength=128
	Team string `json:"team"`

	// +kubebuilder:validation:MaxLength=256
	Email string `json:"email,omitempty"`
}

// ArgoCDSpec contains ArgoCD-specific configuration for the tenant.
type ArgoCDSpec struct {
	SyncPolicy SyncPolicySpec `json:"syncPolicy,omitempty"`
}

// SyncPolicySpec configures ArgoCD automated sync behaviour.
type SyncPolicySpec struct {
	// +kubebuilder:default=true
	AutomatedSync bool `json:"automatedSync,omitempty"`

	// +kubebuilder:default=true
	Prune bool `json:"prune,omitempty"`

	// +kubebuilder:default=true
	SelfHeal bool `json:"selfHeal,omitempty"`
}

// OptionsSpec contains optional metadata and cost allocation fields.
type OptionsSpec struct {
	// +kubebuilder:validation:MaxLength=64
	CostCenter  string            `json:"costCenter,omitempty"`
	Labels      map[string]string `json:"labels,omitempty"`
	Annotations map[string]string `json:"annotations,omitempty"`
}

// TenantStatus defines the observed state of a Tenant.
type TenantStatus struct {
	Phase    Phase           `json:"phase,omitempty"`
	Rendered *RenderedStatus `json:"rendered,omitempty"`
}

// RenderedStatus summarises the resources exported to Git.
type RenderedStatus struct {
	Resources int    `json:"resources,omitempty"`
	Message   string `json:"message,omitempty"`
}

