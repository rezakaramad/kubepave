package model

import (
	"fmt"

	"github.com/crossplane/function-sdk-go/resource"
)

type TenantRequest struct {
	Name        string
	DNSName     string
	DisplayName string
	OwnerTeam   string
	OwnerEmail  string

	ArgoCDSyncRepos []string
}

// FromObservedXR extracts a strongly-typed TenantRequest from XR
func FromObservedXR(xr *resource.Composite) (TenantRequest, error) {
	var out TenantRequest

	u := &xr.Resource.Unstructured

	out.Name = u.GetName()
	if out.Name == "" {
		return out, fmt.Errorf("metadata.name is required")
	}

	dns, err := getRequiredString(u, "spec", "dnsName")
	if err != nil {
		return out, err
	}
	out.DNSName = dns

	display, _ := getOptionalString(u, "spec", "displayName")
	if display == "" {
		display = out.Name
	}
	out.DisplayName = display

	team, err := getRequiredString(u, "spec", "owner", "team")
	if err != nil {
		return out, err
	}
	out.OwnerTeam = team

	email, _ := getOptionalString(u, "spec", "owner", "email")
	out.OwnerEmail = email

	repos, err := getRequiredStringSlice(u, "spec", "argocd", "syncRepos")
	if err != nil {
		return out, err
	}
	out.ArgoCDSyncRepos = repos

	return out, nil
}
