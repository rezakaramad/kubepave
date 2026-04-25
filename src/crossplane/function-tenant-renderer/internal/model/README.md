# Model Layer

The model/ package defines the internal representation of inputs consumed by this function. 

It acts as a stable boundary between external APIs (e.g. Crossplane XRs) and the function’s business logic. All raw, unstructured input should be parsed and normalized here before being used elsewhere.

External input (e.g. XR):
```
apiVersion: idp.rezakara.demo/v1alpha1
kind: Tenant
spec:
  dnsName: ...
  owner:
    team: ...
```
You should not work with this structure directly across the codebase.

Instead, convert it once into a typed model:

```
type TenantSpec struct {
	Name              string
	DNSName           string
	EnvironmentPrefix string
	OwnerTeam         string
	...
}
```
That struct lives in `model/`.

# Why this matters

Without `model/`, you end up scattering field access logic
```
dns, _ := oxr.GetString("spec.dnsName")
team, _ := oxr.GetString("spec.owner.team")
repo := oxr.GetStringSlice("spec.argocd.syncRepos")[0]
```

Repeated in multiple places:
- `render`
- `status`
- `github`

With `model/`, you get
```
t := model.FromObservedXR(oxr)

BuildGitopsApplication(t)
BuildBaselineApplication(t)
```
All downstream logic operates on a clean, validated, and predictable structure.
