// Package tenant contains the Go types for the Tenant Composite Resource Definition (XRD).
//
// These types are the single source of truth for the Tenant XR shape.
// Both function-tenant-validator and function-tenant-renderer import this module
// to parse the observed XR via a simple JSON unmarshal instead of brittle
// unstructured field traversal.
//
// controller-gen markers on the types can generate the OpenAPI schema for the XRD YAML:
//
//	controller-gen crd paths=./... output:crd:dir=./crds
//
// +groupName=idp.rezakara.demo
package tenant
