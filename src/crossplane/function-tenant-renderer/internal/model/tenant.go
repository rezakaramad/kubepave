package model

import (
	"fmt"
	"strings"

	"github.com/crossplane/function-sdk-go/resource"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// TenantSpec represents the normalized, internal view of a Tenant used across the function.
type TenantSpec struct {
	Name        string
	DNSName     string
	DisplayName string
	OwnerTeam   string
	OwnerEmail  string

	SyncRepos []string

	Roles []RoleSpec

	AutomatedSync bool
	Prune         bool
	SelfHeal      bool

	CostCenter  string
	Labels      map[string]string
	Annotations map[string]string
}

type RoleSpec struct {
	Name     string
	EntraId  EntraIdSpec
	Policies []PolicySpec
}

type EntraIdSpec struct {
	AppRoleUUID string
	Assignment  AssignmentSpec
}

type AssignmentSpec struct {
	PrincipalObjectIds []string
	SelectorEnabled    bool
}

type PolicySpec struct {
	Resource string
	Actions  []string
}

// Context
// Crossplane calls RunFunction with a gRPC message roughly structured like this:
// meta:
//   tag: "some-id"
//
// observed:
//   composite:
//     resource:
//       apiVersion: idp.rezakara.demo/v1alpha1
//       kind: Tenant
//       metadata:
//         name: acme
//         uid: 1234-5678
//         generation: 1
//       spec:
//         dnsName: acme.com
//         owner:
//           team: platform
//           email: platform@example.com
//         argocd:
//           syncRepos:
//             - https://github.com/org/repo
//       status:
//         phase: Provisioning
//
//   composed:
//     # existing composed resources (empty in your new model)
//     resources: {}
//
// desired:
//   composite:
//     resource:
//       # what previous steps wanted the XR to look like
//       # (often empty in first step)
//   composed:
//     resources: {}
//
// context: {}
//
// Every function receives a request with three main sections:
// 	observed → what currently exists
// 	desired  → what should exist (so far in pipeline)
// 	context  → shared data between steps
//
//
// observed and desired sections have two subsections:
// 	composite.resource → the XR itself (Tenant in this case)
// 	composed.resources → the child resources that have been created so far (empty in your case)
//
// Your function's main job is to look at observed.composite.resource, extract the relevant data,
// and then create new composed.resources based on that data.

// Extracts and normalizes data from the observed Tenant XR resource into a TenantSpec.
func FromObservedXR(oxr *resource.Composite) (TenantSpec, error) {
	var out TenantSpec
	var err error

	u := &unstructured.Unstructured{
		Object: oxr.Resource.Object,
	}

	out.Name = u.GetName()
	if out.Name == "" {
		return out, fmt.Errorf("metadata.name is required")
	}

	dns, err := getRequiredString(u, "spec", "dnsName")
	if err != nil {
		return out, err
	}
	out.DNSName = strings.ToLower(strings.TrimSpace(dns))

	display, _ := getOptionalString(u, "spec", "displayName")
	display = strings.TrimSpace(display)
	if display == "" {
		display = out.Name
	}
	out.DisplayName = display

	team, err := getRequiredString(u, "spec", "owner", "team")
	if err != nil {
		return out, err
	}
	out.OwnerTeam = strings.TrimSpace(team)

	if v, err := getOptionalString(u, "spec", "owner", "email"); err != nil {
		return out, err
	} else {
		out.OwnerEmail = strings.TrimSpace(v)
	}

	out.SyncRepos = []string{fmt.Sprintf("https://github.com/fluxdojo/platform-deploy-%s", out.Name)}

	if v, err := getOptionalBoolDefault(u, true, "spec", "argocd", "syncPolicy", "automatedSync"); err != nil {
		return out, err
	} else {
		out.AutomatedSync = v
	}

	if v, err := getOptionalBoolDefault(u, true, "spec", "argocd", "syncPolicy", "prune"); err != nil {
		return out, err
	} else {
		out.Prune = v
	}

	if v, err := getOptionalBoolDefault(u, true, "spec", "argocd", "syncPolicy", "selfHeal"); err != nil {
		return out, err
	} else {
		out.SelfHeal = v
	}

	if v, err := getOptionalString(u, "spec", "options", "costCenter"); err != nil {
		return out, err
	} else {
		out.CostCenter = v
	}

	if v, err := getOptionalStringMap(u, "spec", "options", "labels"); err != nil {
		return out, err
	} else {
		out.Labels = v
	}

	if v, err := getOptionalStringMap(u, "spec", "options", "annotations"); err != nil {
		return out, err
	} else {
		out.Annotations = v
	}

	return out, nil
}

// Navigates a nested path like:
//
//	"spec", "owner", "team"
//
// Looks inside:
// spec:
//
//	owner:
//	  team: platform
//
// Possible outcomes:
//
//	Field exists and valid						v="platform", found=true, err=nil
//	Field missing								found=false
//	Wrong type (e.g. number instead of string)	err != nil
func getRequiredString(u *unstructured.Unstructured, fields ...string) (string, error) {
	v, found, err := unstructured.NestedString(u.Object, fields...)
	if err != nil {
		// The field exists, but it’s the wrong type
		// team: 123   # ❌ expected string
		return "", fmt.Errorf("invalid field %s: %w", fieldPath(fields...), err)
	}
	if !found || v == "" {
		// field not present ❌ or present but empty ❌
		// Example:
		// 	missing 	owner: {}
		// 	empty		team: ""
		return "", fmt.Errorf("required field missing: %s", fieldPath(fields...))
	}
	return v, nil
}

// getOptional... functions follow a similar pattern but return default values instead of errors when fields are missing or invalid.
// Missing field → ✅ OK (use default)
// Empty value → ⚠️ depends on your rules
// Wrong type → ❌ still an error (don’t silently ignore)

// getOptionalString returns a string if present, or empty string if missing or invalid.
func getOptionalString(u *unstructured.Unstructured, fields ...string) (string, error) {
	v, found, err := unstructured.NestedString(u.Object, fields...)
	if err != nil {
		return "", fmt.Errorf("invalid field %s: %w", fieldPath(fields...), err)
	}
	if !found {
		return "", nil
	}
	return v, nil
}

// getOptionalBoolDefault returns a boolean if present, otherwise falls back to the provided default.
func getOptionalBoolDefault(u *unstructured.Unstructured, def bool, fields ...string) (bool, error) {
	v, found, err := unstructured.NestedBool(u.Object, fields...)
	if err != nil {
		return def, fmt.Errorf("invalid field %s: %w", fieldPath(fields...), err)
	}
	if !found {
		return def, nil
	}
	return v, nil
}

// fieldPath joins nested field names into a dot-separated path for readable errors.
func fieldPath(fields ...string) string {
	return strings.Join(fields, ".")
}

// getOptionalStringMap returns a map[string]string if present, or nil if missing.
func getOptionalStringMap(u *unstructured.Unstructured, fields ...string) (map[string]string, error) {
	raw, found, err := unstructured.NestedStringMap(u.Object, fields...)
	if err != nil {
		return nil, fmt.Errorf("invalid field %s: %w", fieldPath(fields...), err)
	}
	if !found {
		return nil, nil
	}
	return raw, nil
}
