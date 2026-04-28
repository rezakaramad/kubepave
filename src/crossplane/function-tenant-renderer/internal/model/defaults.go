package model

func ResolveRBAC(t *TenantSpec, input *PlatformConfig) {

	// 1. Input config takes highest priority
	if input != nil && len(input.RBAC.Roles) > 0 {
		t.Roles = fromInputRoles(input.RBAC.Roles)
		return
	}

	// 2. Otherwise fallback to defaults
	t.Roles = defaultRoles()
}

func defaultRoles() []RoleSpec {
	return []RoleSpec{
		{
			Name:     "admin",
			Policies: defaultPolicies("admin"),
		},
		{
			Name:     "viewer",
			Policies: defaultPolicies("viewer"),
		},
	}
}

func defaultPolicies(role string) []PolicySpec {
	switch role {
	case "admin":
		return []PolicySpec{
			{
				Resource: "applications",
				Actions: []string{
					"get", "update", "delete", "sync",
					"action/apps/Deployment/pause",
					"action/apps/Deployment/resume",
					"action/apps/Deployment/restart",
					"action/batch/CronJob/create-job",
				},
			},
			{
				Resource: "logs",
				Actions:  []string{"get"},
			},
		}

	case "viewer":
		return []PolicySpec{
			{
				Resource: "applications",
				Actions:  []string{"get"},
			},
			{
				Resource: "logs",
				Actions:  []string{"get"},
			},
		}
	}

	return nil
}

func fromInputRoles(in []RoleInput) []RoleSpec {
	var out []RoleSpec

	for _, r := range in {
		role := RoleSpec{
			Name: r.Name,
		}

		for _, p := range r.Policies {
			role.Policies = append(role.Policies, PolicySpec{
				Resource: p.Resource,
				Actions:  p.Actions,
			})
		}

		out = append(out, role)
	}

	return out
}

func CommonLabels(t TenantSpec) map[string]string {
	return map[string]string{
		"app.kubernetes.io/managed-by":  "crossplane",
		"platform.rezakara.demo/tenant": t.Name,
	}
}
