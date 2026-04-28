package model

import (
	"fmt"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

type PlatformConfig struct {
	metav1.TypeMeta `json:",inline"`

	Clusters []ClusterInput `json:"clusters,omitempty"`
	RBAC     RBACInput      `json:"rbac,omitempty"`
}

type ClusterInput struct {
	Name              string `json:"name"`
	EnvironmentPrefix string `json:"environmentPrefix"`
}

type RBACInput struct {
	Roles []RoleInput `json:"roles,omitempty"`
}

type RoleInput struct {
	Name     string        `json:"name"`
	Policies []PolicyInput `json:"policies,omitempty"`
}

type PolicyInput struct {
	Resource string   `json:"resource"`
	Actions  []string `json:"actions,omitempty"`
}

func (in *PlatformConfig) DeepCopyObject() runtime.Object {
	if in == nil {
		return nil
	}

	out := new(PlatformConfig)
	*out = *in

	out.Clusters = append([]ClusterInput(nil), in.Clusters...)

	if in.RBAC.Roles != nil {
		out.RBAC.Roles = make([]RoleInput, len(in.RBAC.Roles))
		for i := range in.RBAC.Roles {
			out.RBAC.Roles[i] = in.RBAC.Roles[i]
			out.RBAC.Roles[i].Policies = append([]PolicyInput(nil), in.RBAC.Roles[i].Policies...)

			for j := range in.RBAC.Roles[i].Policies {
				out.RBAC.Roles[i].Policies[j].Actions =
					append([]string(nil), in.RBAC.Roles[i].Policies[j].Actions...)
			}
		}
	}

	return out
}

func (in *PlatformConfig) ToClusters() []Cluster {
	var out []Cluster

	for _, c := range in.Clusters {
		out = append(out, Cluster{
			Name:   c.Name,
			Prefix: c.EnvironmentPrefix,
		})
	}

	return out
}

func (in *PlatformConfig) Validate() error {

	if len(in.Clusters) == 0 {
		return fmt.Errorf("at least one cluster must be provided")
	}

	for _, c := range in.Clusters {
		if c.Name == "" {
			return fmt.Errorf("cluster name cannot be empty")
		}
		if c.EnvironmentPrefix == "" {
			return fmt.Errorf("cluster %q has empty environmentPrefix", c.Name)
		}
	}

	for _, r := range in.RBAC.Roles {
		if r.Name == "" {
			return fmt.Errorf("role name cannot be empty")
		}
		for _, p := range r.Policies {
			if p.Resource == "" {
				return fmt.Errorf("role %q has policy with empty resource", r.Name)
			}
			if len(p.Actions) == 0 {
				return fmt.Errorf("role %q has policy with no actions", r.Name)
			}
		}
	}

	return nil
}
