package tenant

// Cluster is a shared platform primitive representing an ArgoCD destination cluster.
// It is used by both function-tenant-validator and function-tenant-renderer
// and is not part of the Tenant XR schema itself.
type Cluster struct {
	Name   string // ArgoCD cluster name
	Prefix string // Environment prefix for the cluster (dev, test, prod, wl, ...)
}
