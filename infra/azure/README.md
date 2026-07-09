# Application registration

Defines Argo CD's identity in Microsoft Entra ID.

This represents the application itself (OIDC client), including:
- client ID used by Argo CD for authentication
- redirect URIs for login callbacks
- app roles (e.g. tenant-specific roles like tenant:<name>:argo)

It does NOT control who can access the app.

```
resource "azuread_application" "argocd" {
  display_name = "argocd"
}
```


# Enterprise Application (Service Principal)

**Controls access** to Argo CD in this tenant.

This is the tenant-local instance of the App Registration and is used for:
- assigning users/groups to the application
- enforcing login restrictions (app_role_assignment_required)
- linking users/groups to app roles

It does NOT define the app itself, only who can use it.
```
resource "azuread_service_principal" "argocd" {
  client_id = azuread_application.argocd.client_id
}
```

# Mental Model
**App Registration** = Argo CD talking to Entra
**Enterprise Application** = Entra deciding who can log into Argo CD

Microsoft split them because:
- One app can be used by many tenants (App Registration)
- Each tenant needs its own access control (Enterprise App)

## App Registration (Argo CD identity)

This is:

“What is Argo CD in Entra?”

It contains:

- client ID
- redirect URL
- app roles (tenant:acme:argo)

Used by **Argo CD**

## Enterprise Application (access control)

This is:

“Who is allowed to use Argo CD?”

It contains:

- user/group assignments
- role assignments
- login restrictions

Used by **Entra ID**

[Further reading](https://learn.microsoft.com/en-us/entra/identity-platform/app-objects-and-service-principals?tabs=browser) ...