package validation

import (
	"context"
	"fmt"
	"strings"

	"github.com/crossplane/function-sdk-go/resource"
	"github.com/crossplane/function-tenantrequest-renderer/internal/model"
	"github.com/crossplane/function-tenantrequest-renderer/internal/pdns"
	ctrlclient "sigs.k8s.io/controller-runtime/pkg/client"
)

// Error represents a validation failure.
type Error struct {
	Reason    string
	Message   string
	Retryable bool
}

// Deps contains external dependencies required for validation.
type Deps struct {
	Kube       ctrlclient.Client
	PDNS       pdns.Client
	BaseDomain string
	Clusters   []model.Cluster
}

// Validate performs full validation of a TenantRequest.
func Validate(ctx context.Context, xr *resource.Composite, d Deps) *Error {

	// 1. Required fields
	if err := validateRequiredFields(xr); err != nil {
		return err
	}

	dnsName, _ := xr.Resource.GetString("spec.dnsName")

	// 2. Multi-cluster DNS validation
	for _, c := range d.Clusters {
		fqdn := pdns.BuildFQDN(dnsName, c.Prefix, d.BaseDomain)

		res, err := d.PDNS.CheckDNSAvailable(ctx, fqdn)
		if err != nil {
			return &Error{
				Reason:    "DnsCheckFailed",
				Message:   err.Error(),
				Retryable: isRetryable(err),
			}
		}

		if !res.Available {
			return &Error{
				Reason:    "DnsNameTaken",
				Message:   fmt.Sprintf("dns %q already in use", fqdn),
				Retryable: false,
			}
		}
	}

	return nil
}

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

func validateRequiredFields(xr *resource.Composite) *Error {
	name := xr.Resource.GetName()
	if name == "" {
		return &Error{"InvalidSpec", "metadata.name is required", false}
	}

	dnsName, _ := xr.Resource.GetString("spec.dnsName")
	if dnsName == "" {
		return &Error{"InvalidSpec", "spec.dnsName is required", false}
	}

	team, _ := xr.Resource.GetString("spec.owner.team")
	if team == "" {
		return &Error{"InvalidSpec", "spec.owner.team is required", false}
	}

	repos, err := xr.Resource.GetValue("spec.argocd.syncRepos")
	if err != nil || repos == nil {
		return &Error{"InvalidSpec", "spec.argocd.syncRepos is required", false}
	}

	list, ok := repos.([]any)
	if !ok || len(list) == 0 {
		return &Error{"InvalidSpec", "spec.argocd.syncRepos must not be empty", false}
	}

	return nil
}

func isRetryable(err error) bool {
	msg := err.Error()
	return contains(msg, "timeout") ||
		contains(msg, "connection") ||
		contains(msg, "refused")
}

func contains(s, substr string) bool {
	return strings.Contains(s, substr)
}
