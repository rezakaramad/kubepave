package main

import "github.com/crossplane/function-sdk-go/resource"

// ---------------------------------------------------------------------
// Phases
// ---------------------------------------------------------------------

const (
	PhaseValidating      = "Validating"
	PhasePendingApproval = "PendingApproval"
	PhaseReady           = "Ready"
	PhaseFailed          = "Failed"
)

// ---------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------

// SetPhase sets status.phase on the XR
func SetPhase(xr *resource.Composite, phase string) {
	_ = xr.Resource.SetValue("status.phase", phase)
}
