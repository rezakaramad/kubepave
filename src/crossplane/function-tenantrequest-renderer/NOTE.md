	// ---------------------------------------------------------------------
	// Validation
	// ---------------------------------------------------------------------
	// This function follows a GitOps-driven state machine.
	//
	// It does NOT wait for infrastructure readiness.
	// Its responsibility ends once the desired state is written to Git.
	//
	// Flow Overview:
	//
	// START
	//   ↓
	// Validating
	//   ↓ (validation fails, non-retryable)
	// Failed
	//   ↓ (validation fails, retryable)
	// Validating (retry)
	//   ↓ (validation passes)
	// PendingApproval
	//   ↓ (not approved)
	// PendingApproval (loop)
	//   ↓ (approved)
	// Publishing (Git desired state is generated)
	//   ↓
	// Ready
	//
	// Notes:
	// - "Ready" means the tenant configuration has been handed off for Git publication
	// - Argo CD is responsible for applying and reconciling actual infrastructure