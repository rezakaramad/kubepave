package main

import (
	"context"
	"fmt"
	"strings"

	xtenant "github.com/rezakaramad/kubepave/xr-types/tenant"
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
	Kube             ctrlclient.Client
	PDNSClient       PDNSClient
	BaseDomain       string
	WorkloadClusters []xtenant.Cluster
}

// Validate performs full validation of a Tenant.
func Validate(ctx context.Context, t xtenant.Tenant, d Deps) *Error {

	dnsName := t.Spec.DNSName

	// ---------------------------------------------------------------------
	// Multi-cluster DNS validation
	// ---------------------------------------------------------------------
	for _, cluster := range d.WorkloadClusters {
		fqdn := BuildFQDN(dnsName, cluster.Prefix, d.BaseDomain)

		res, err := d.PDNSClient.CheckDNSAvailable(ctx, fqdn)
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

func isRetryable(err error) bool {
	msg := err.Error()
	return contains(msg, "timeout") ||
		contains(msg, "connection") ||
		contains(msg, "refused")
}

func contains(s, substr string) bool {
	return strings.Contains(s, substr)
}
