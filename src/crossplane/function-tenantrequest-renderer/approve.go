package main

import "github.com/crossplane/function-sdk-go/resource"

func IsApproved(xr *resource.Composite) bool {
	conditions, err := xr.Resource.GetValue("status.conditions")
	if err != nil {
		return false
	}

	list, ok := conditions.([]any)
	if !ok {
		return false
	}

	for _, c := range list {
		m, ok := c.(map[string]any)
		if !ok {
			continue
		}

		if m["type"] == "Approved" && m["status"] == "True" {
			return true
		}
	}

	return false
}
