package main

import (
	"fmt"

	"github.com/crossplane/function-sdk-go/resource"
	"github.com/crossplane/function-sdk-go/resource/composed"
	inputv1beta1 "github.com/crossplane/function-tenant-renderer/input/v1beta1"
	"golang.org/x/text/cases"
	"golang.org/x/text/language"
)

const defaultUserPrincipalDomain = "rkaramadgmail.onmicrosoft.com"
const principalTypeUser = "user"
const principalTypeGroup = "group"

type ResolvedBinding struct {
	Role              string
	Cluster           string
	EnvironmentPrefix string
	PrincipalObjectID string
}

func usesUserPrincipal(azure inputv1beta1.AzureInput) bool {
	return azure.PrincipalType == principalTypeUser
}

func principalResourceName(azure inputv1beta1.AzureInput, binding inputv1beta1.BindingInput) resource.Name {
	if usesUserPrincipal(azure) {
		return resource.Name(fmt.Sprintf("entra-user-%s", binding.Name))
	}
	return resource.Name(fmt.Sprintf("entra-group-%s-%s-%s", binding.Name, binding.Cluster, binding.EnvironmentPrefix))
}

func userPasswordResourceName(binding inputv1beta1.BindingInput) resource.Name {
	return resource.Name(fmt.Sprintf("entra-user-password-%s", binding.Name))
}

func userPasswordSecretResourceName(binding inputv1beta1.BindingInput) resource.Name {
	return resource.Name(fmt.Sprintf("entra-user-password-secret-%s", binding.Name))
}

func userResourceNames(t TenantSpec, binding inputv1beta1.BindingInput) (resourceName resource.Name, secretName, principalName string) {
	principalName = fmt.Sprintf("%s-%s", t.GetName(), binding.Name)
	secretName = fmt.Sprintf("%s-initial-password", principalName)
	return principalResourceName(inputv1beta1.AzureInput{PrincipalType: principalTypeUser}, binding), secretName, principalName
}

func buildPrincipalGroup(t TenantSpec, binding inputv1beta1.BindingInput) *composed.Unstructured {
	group := composed.New()
	group.SetAPIVersion("groups.azuread.m.upbound.io/v1beta1")
	group.SetKind("Group")
	group.SetName(fmt.Sprintf("%s-%s-%s", t.GetName(), binding.Name, binding.EnvironmentPrefix))
	group.SetNamespace("crossplane")

	group.SetLabels(map[string]string{
		"app.kubernetes.io/managed-by":  "crossplane",
		"platform.rezakara.demo/tenant": t.GetName(),
		"platform.rezakara.demo/role":   binding.Name,
		"platform.rezakara.demo/prefix": binding.EnvironmentPrefix,
	})

	_ = group.SetValue("spec.forProvider.displayName", fmt.Sprintf("%s-%s-%s", t.Spec.DisplayName, cases.Title(language.English).String(binding.Name), cases.Title(language.English).String(binding.EnvironmentPrefix)))
	_ = group.SetValue("spec.forProvider.securityEnabled", true)
	_ = group.SetValue("spec.providerConfigRef.name", "azuread")
	_ = group.SetValue("spec.providerConfigRef.kind", "ProviderConfig")

	return group
}

func buildPrincipalUserPassword(binding inputv1beta1.BindingInput, secretName string) *composed.Unstructured {
	password := composed.New()
	password.SetAPIVersion("generators.external-secrets.io/v1alpha1")
	password.SetKind("Password")
	password.SetName(secretName)
	password.SetNamespace("crossplane")
	_ = password.SetValue("spec.length", int64(32))
	return password
}

func buildPrincipalUserPasswordSecret(binding inputv1beta1.BindingInput, secretName string) *composed.Unstructured {
	externalSecret := composed.New()
	externalSecret.SetAPIVersion("external-secrets.io/v1")
	externalSecret.SetKind("ExternalSecret")
	externalSecret.SetName(secretName)
	externalSecret.SetNamespace("crossplane")
	_ = externalSecret.SetValue("spec.target.name", secretName)
	_ = externalSecret.SetValue("spec.dataFrom", []any{
		map[string]any{
			"sourceRef": map[string]any{
				"generatorRef": map[string]any{
					"kind": "Password",
					"name": secretName,
				},
			},
		},
	})
	return externalSecret
}

func buildPrincipalUser(t TenantSpec, binding inputv1beta1.BindingInput, azure inputv1beta1.AzureInput) *composed.Unstructured {
	_, secretName, principalName := userResourceNames(t, binding)
	domain := azure.UserPrincipalDomain
	if domain == "" {
		domain = defaultUserPrincipalDomain
	}

	user := composed.New()
	user.SetAPIVersion("users.azuread.m.upbound.io/v1beta1")
	user.SetKind("User")
	user.SetName(principalName)
	user.SetNamespace("crossplane")

	user.SetLabels(map[string]string{
		"app.kubernetes.io/managed-by":          "crossplane",
		"platform.rezakara.demo/tenant":         t.GetName(),
		"platform.rezakara.demo/role":           binding.Name,
		"platform.rezakara.demo/principal-type": principalTypeUser,
	})

	_ = user.SetValue("spec.forProvider.userPrincipalName", fmt.Sprintf("%s@%s", principalName, domain))
	_ = user.SetValue("spec.forProvider.displayName", fmt.Sprintf("%s %s", t.Spec.DisplayName, cases.Title(language.English).String(binding.Name)))
	_ = user.SetValue("spec.forProvider.passwordSecretRef.key", "password")
	_ = user.SetValue("spec.forProvider.passwordSecretRef.name", secretName)
	_ = user.SetValue("spec.providerConfigRef.name", "azuread")
	_ = user.SetValue("spec.providerConfigRef.kind", "ProviderConfig")

	return user
}

func buildPrincipalResources(t TenantSpec, binding inputv1beta1.BindingInput, azure inputv1beta1.AzureInput) map[resource.Name]*resource.DesiredComposed {
	if !usesUserPrincipal(azure) {
		return map[resource.Name]*resource.DesiredComposed{
			principalResourceName(azure, binding): {
				Resource: buildPrincipalGroup(t, binding),
			},
		}
	}

	_, secretName, _ := userResourceNames(t, binding)
	return map[resource.Name]*resource.DesiredComposed{
		userPasswordResourceName(binding): {
			Resource: buildPrincipalUserPassword(binding, secretName),
		},
		userPasswordSecretResourceName(binding): {
			Resource: buildPrincipalUserPasswordSecret(binding, secretName),
		},
		principalResourceName(azure, binding): {
			Resource: buildPrincipalUser(t, binding, azure),
		},
	}
}

func resolveBindingPrincipalObjectID(observed map[resource.Name]resource.ObservedComposed, azure inputv1beta1.AzureInput, binding inputv1beta1.BindingInput) (string, bool, error) {
	observedResource, ok := observed[principalResourceName(azure, binding)]
	if !ok || observedResource.Resource == nil {
		return "", false, nil
	}

	objectID, err := observedResource.Resource.GetString("status.atProvider.objectId")
	if err == nil && objectID != "" {
		return objectID, true, nil
	}

	providerID, idErr := observedResource.Resource.GetString("status.atProvider.id")
	if idErr == nil && providerID != "" {
		return providerID, true, nil
	}

	// Neither field is populated yet — provider hasn't synced the resource.
	// Signal "not ready" so the caller waits rather than treating this as fatal.
	return "", false, nil
}
