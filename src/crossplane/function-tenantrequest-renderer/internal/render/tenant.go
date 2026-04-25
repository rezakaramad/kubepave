package render

import "github.com/crossplane/function-tenantrequest-renderer/internal/model"

// BuildTenantObject builds the Tenant resource as a generic map
func BuildTenantObject(t model.TenantRequest) map[string]any {
	return map[string]any{
		"apiVersion": "idp.rezakara.demo/v1alpha1",
		"kind":       "Tenant",
		"metadata": map[string]any{
			"name": t.Name,
		},
		"spec": map[string]any{
			"dnsName":     t.DNSName,
			"displayName": t.DisplayName,
			"owner": map[string]any{
				"team":  t.OwnerTeam,
				"email": t.OwnerEmail,
			},
			"argocd": map[string]any{
				"syncRepos": t.ArgoCDSyncRepos,
			},
		},
	}
}
