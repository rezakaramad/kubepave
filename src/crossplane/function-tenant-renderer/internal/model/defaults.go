package model

func ApplyDefaults(t *TenantSpec) {

	if len(t.Roles) == 0 {
		t.Roles = []RoleSpec{
			{Name: "admin"},
			{Name: "viewer"},
		}
	}

	for i, r := range t.Roles {

		if len(r.Policies) == 0 {
			t.Roles[i].Policies = defaultPolicies(r.Name)
		}
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

func CommonLabels(t TenantSpec) map[string]string {

	return map[string]string{
		"app.kubernetes.io/managed-by":  "crossplane",
		"platform.rezakara.demo/tenant": t.Name,
	}
}
