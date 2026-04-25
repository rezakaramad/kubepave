package render

// This file contains functions to build AppRole, Group, and RoleAssignment resources for ArgoCD applications in Entra ID.
// AppRole + Group + RoleAssignment = ONE logical unit (RBAC)

import (
	"fmt"
	"sort"

	"github.com/crossplane/function-sdk-go/resource/composed"
	"github.com/crossplane/function-tenant-renderer/internal/model"
)

// Role defines the structure for a role with its name and corresponding group name.
// We use this struct to assign both the AppRole name and the Group name in a consistent way.
type Role struct {
	Name      string
	GroupName string
}

// Admin role has permissions to manage ArgoCD application in the cluster,
// Viewer role has read-only access. We can add more roles later if needed.
var defaultRoles = []Role{
	{
		Name:      "admin",
		GroupName: "admins",
	},
	{
		Name:      "viewer",
		GroupName: "viewers",
	},
}

// A little about composed.Unstructured: this type comes from
// github.com/crossplane/function-sdk-go/resource/composed and is a helper for building Kubernetes resources in a dynamic way.
// It represents: A Kubernetes resource in a generic (unstructured) form,
// allowing us to set fields and metadata without needing a predefined Go struct for each resource type.
// []*composed.Unstructured is a list of pointers to Kubernetes resources that we will generate and return from our BuildAppRBAC function.
// BuildAppRBAC return:
//   - many resources (AppRole, Group, RoleAssignment...)
//   - OR an error

// BuildAppRBAC generates AppRole, Group, and RoleAssignment resources for the given tenant and clusters.
// It iterates over each cluster and role, creating a consistent naming convention for the resources based on the tenant name, cluster prefix, and role name.
// For example, for a tenant "payment", cluster prefix "dev", and role "admin", it will create:
// - AppRole: payment-dev-admin
// - Group: payment-dev-admins
// - RoleAssignment: payment-dev-admin
func BuildAppRBAC(
	t model.TenantSpec,
	clusters []model.Cluster,
	namespace string,
	providerConfigName string,
	argocdAppID string,
) ([]*composed.Unstructured, error) {

	var resources []*composed.Unstructured

	// For each cluster and role, we create AppRole, Group, and RoleAssignment.
	// 	payment-dev-admin (AppRole)
	// 	payment-dev-admins (Group)
	// 	payment-dev-admin (RoleAssignment)

	sortedClusters := append([]model.Cluster(nil), clusters...)

	sort.Slice(sortedClusters, func(i, j int) bool {
		return sortedClusters[i].Prefix < sortedClusters[j].Prefix
	})

	for _, c := range sortedClusters {
		prefix := c.Prefix

		for _, role := range defaultRoles {
			// Build AppRole
			appRole, err := buildAppRole(t, prefix, role, namespace, providerConfigName, argocdAppID)
			if err != nil {
				return nil, err
			}

			// Build Group
			group, err := buildGroup(t, prefix, role, namespace, providerConfigName)
			if err != nil {
				return nil, err
			}

			// Build RoleAssignment
			assignment, err := buildAppRoleAssignment(t, prefix, role, namespace, providerConfigName, argocdAppID)
			if err != nil {
				return nil, err
			}

			// Append resources to the list
			resources = append(resources,
				appRole,
				group,
				assignment,
			)
		}
	}

	return resources, nil
}

// buildAppRole creates an AppRole resource for the given tenant, cluster prefix, and role.
// The AppRole is associated with the ArgoCD application and defines the permissions for that role.
// For example, for tenant "payment", cluster prefix "dev", and role "admin", it will create an AppRole named "payment-dev-admin".
func buildAppRole(
	t model.TenantSpec,
	prefix string,
	role Role,
	namespace string,
	providerConfigName string,
	argocdAppID string,
) (*composed.Unstructured, error) {

	// The name of the AppRole is constructed using the tenant name, cluster prefix, and role name to ensure uniqueness and clarity.
	// For example, for tenant "payment", cluster prefix "dev", and role "admin", the AppRole will be named "payment-dev-admin".
	name := fmt.Sprintf("%s-%s-%s", t.Name, prefix, role.Name)

	// We create a new composed.Unstructured resource and set its API version, kind, name, and namespace.
	r := composed.New()
	r.SetAPIVersion("applications.azuread.m.upbound.io/v1beta1")
	r.SetKind("AppRole")
	r.SetName(name)
	r.SetNamespace(namespace)

	// We also set labels on the resource to help with identification and selection later.
	r.SetLabels(map[string]string{
		"tenant": t.Name,
		"prefix": prefix,
		"role":   role.Name,
	})

	// The spec of the AppRole defines the permissions and associations for that role. It includes:
	// - applicationId: the ID of the ArgoCD application this role is associated with.
	// - displayName: a human-readable name for the role.
	// - value: the value of the role, which can be used in RoleAssignments.
	// - description: a description of the role's purpose.
	// - allowedMemberTypes: specifies that both Users and Groups can be members of this role.
	err := r.SetValue("spec", map[string]any{
		"forProvider": map[string]any{
			"applicationId": argocdAppID,
			"displayName":   name,
			"value":         name,
			"description":   fmt.Sprintf("%s access for %s %s", role.Name, t.Name, prefix),
			"allowedMemberTypes": []any{
				"User",
				"Group",
			},
		},
		"providerConfigRef": map[string]any{
			"name": providerConfigName,
		},
	})
	if err != nil {
		return nil, err
	}

	return r, nil
}

// buildGroup creates a Group resource for the given tenant, cluster prefix, and role.
// The Group is associated with the AppRole and defines the members for that role.
// For example, for tenant "payment", cluster prefix "dev", and role "admin", it will create a Group named "payment-dev-admins".
func buildGroup(
	t model.TenantSpec,
	prefix string,
	role Role,
	namespace string,
	providerConfigName string,
) (*composed.Unstructured, error) {

	// The name of the Group is constructed using the tenant name, cluster prefix, and role's group name to ensure uniqueness and clarity.
	// For example, for tenant "payment", cluster prefix "dev", and role "admin" (with group name "admins"), the Group will be named "payment-dev-admins".
	groupName := fmt.Sprintf("%s-%s-%s", t.Name, prefix, role.GroupName)

	// We create a new composed.Unstructured resource and set its API version, kind, name, and namespace.
	g := composed.New()
	g.SetAPIVersion("groups.azuread.m.upbound.io/v1beta1")
	g.SetKind("Group")
	g.SetName(groupName)
	g.SetNamespace(namespace)

	// We also set labels on the resource to help with identification and selection later.
	g.SetLabels(map[string]string{
		"tenant": t.Name,
		"prefix": prefix,
		"role":   role.Name,
	})

	// The spec of the Group defines its properties. It includes:
	// - displayName: a human-readable name for the group.
	// - securityEnabled: indicates that this group is a security group.
	err := g.SetValue("spec", map[string]any{
		"forProvider": map[string]any{
			"displayName":     groupName,
			"securityEnabled": true,
		},
		"providerConfigRef": map[string]any{
			"name": providerConfigName,
		},
	})
	if err != nil {
		return nil, err
	}

	return g, nil
}

// buildAppRoleAssignment creates a RoleAssignment resource for the given tenant, cluster prefix, and role.
// The RoleAssignment associates the AppRole with the Group, granting the group's members the permissions defined in the AppRole.
// For example, for tenant "payment", cluster prefix "dev", and role "admin", it will create a RoleAssignment named "payment-dev-admin".
func buildAppRoleAssignment(
	t model.TenantSpec,
	prefix string,
	role Role,
	namespace string,
	providerConfigName string,
	argocdAppID string,
) (*composed.Unstructured, error) {

	// The name of the RoleAssignment is constructed using the tenant name, cluster prefix, and role name to ensure uniqueness and clarity.
	// For example, for tenant "payment", cluster prefix "dev", and role "admin", the RoleAssignment will be named "payment-dev-admin".
	name := fmt.Sprintf("%s-%s-%s", t.Name, prefix, role.Name)

	// We create a new composed.Unstructured resource and set its API version, kind, name, and namespace.
	r := composed.New()
	r.SetAPIVersion("app.azuread.m.upbound.io/v1beta1")
	r.SetKind("RoleAssignment")
	r.SetName(name)
	r.SetNamespace(namespace)

	// We also set labels on the resource to help with identification and selection later.
	err := r.SetValue("spec", map[string]any{
		"forProvider": map[string]any{
			"appRoleIdSelector": map[string]any{
				"matchLabels": map[string]any{
					"tenant": t.Name,
					"prefix": prefix,
					"role":   role.Name,
				},
			},
			"principalObjectIdSelector": map[string]any{
				"matchLabels": map[string]any{
					"tenant": t.Name,
					"prefix": prefix,
					"role":   role.Name,
				},
			},
			"resourceObjectId": argocdAppID,
		},
		"providerConfigRef": map[string]any{
			"name": providerConfigName,
		},
	})
	if err != nil {
		return nil, err
	}

	return r, nil
}
