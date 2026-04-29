package main

import xtenant "github.com/rezakaramad/kubepave/xr-types/tenant"

// IsApproved returns true if the Tenant has been approved by a platform engineer.
func IsApproved(t xtenant.Tenant) bool {
	return t.Spec.Approved
}
