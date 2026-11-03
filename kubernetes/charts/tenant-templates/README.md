# tenant-templates

Ships the Go templates that the `xtenant-gotemplating` Composition (in the `crossplane` chart) renders into each tenant's Argo CD `Application` and `ApplicationSet`.

Each template version is one `EnvironmentConfig` named `xtenant-argocd-<version>`, built from the files in `files/<version>/`.

## How the pieces fit

| Where | What |
| --- | --- |
| `tenant-templates/files/<version>/*.tmpl` | The template text, concatenated in file order. |
| `tenant-templates/templates/xtenant-environmentconfig-<version>.yaml` | The `EnvironmentConfig` for that version. |
| `crossplane/values-local.yaml` (`goTemplating.templateVersion`) | Which `EnvironmentConfig` the Composition loads. |
| `crossplane/values-local.yaml` (`goTemplating.channel`) | The `channel` label on the Composition, copied onto each `CompositionRevision`. |
| `spec.crossplane.compositionRevisionSelector` on an XR | The channel the XR follows. |

Settings (repo URL, project, environments, OIDC accessor) are not in the template. They are set in the `settings` step of `crossplane/templates/xtenant/composition-gotemplating.yaml`, so changing them creates a Composition revision.

## Introduce a new version

### 1. In `tenant-templates`

```fish
cd kubepave/kubernetes/charts/tenant-templates
cp -r files/v1 files/v2
cp templates/xtenant-environmentconfig-v1.yaml templates/xtenant-environmentconfig-v2.yaml
```

- Edit the files in `files/v2/` with your change.
- In `templates/xtenant-environmentconfig-v2.yaml`, change the name to `xtenant-argocd-v2` and every `files/v1/` path to `files/v2/`.
- Leave `v1` untouched. Revisions that still point at it need it.

### 2. In the `crossplane` chart, trial it on `next`

In `kubepave/kubernetes/charts/crossplane/values-local.yaml`:

```yaml
goTemplating:
  channel: next
  templateVersion: v2
```

This creates a new `CompositionRevision` labelled `next` that loads `xtenant-argocd-v2`. XRs following `stable` stay on their current revision.

### 3. Try it on a canary XR

Point one XR at the `next` channel:

```yaml
spec:
  crossplane:
    compositionRef:
      name: xtenant-gotemplating
    compositionRevisionSelector:
      matchLabels:
        channel: next
```

Check what it renders:

```fish
kubectl get xtenant <name> -o yaml
kubectl get application,applicationset -n argocd -l platform.rezakara.demo/tenant=<name>
```

### 4. Promote to `stable`

In `values-local.yaml`:

```yaml
goTemplating:
  channel: stable
  templateVersion: v2
```

A new `stable` revision is created that loads `v2`. XRs following `stable` move to it. Move the canary XR back to `channel: stable` as well.

### 5. Clean up

When no `stable` or `next` revision references `v1`, delete `files/v1/` and `templates/xtenant-environmentconfig-v1.yaml`. Argo CD does not prune with `automated: {}`, so also delete the old object:

```fish
kubectl delete environmentconfig xtenant-argocd-v1
```

## Roll back

Set `templateVersion` back to the previous version and `channel: stable`. If that spec and label match an older revision exactly, check whether Crossplane reuses that revision or creates a new one before relying on it.

## Inspect revisions

```fish
kubectl get compositionrevisions -l crossplane.io/composition-name=xtenant-gotemplating \
  -o custom-columns=NAME:.metadata.name,REV:.spec.revision,CHANNEL:.metadata.labels.channel
kubectl get xtenants -o custom-columns=NAME:.metadata.name,REV:.spec.crossplane.compositionRevisionRef.name,SELECTOR:.spec.crossplane.compositionRevisionSelector.matchLabels
```

## Things to watch

- An XR whose selector matches no revision has no revision and does not render. Create the `next` revision before pointing an XR at it.
- Change the `channel` label and the template version in the same commit. A label change on its own also creates a revision, but then points at the same template.
- `tenant-templates` must sync before the Composition uses a new version (sync wave `6`, after crossplane at `5`).
- Template files after the first start with `---` so each is its own YAML document. Variables defined in `00-variables.yaml.tmpl` are visible to the later files.
- Add new files in a version directory to its `EnvironmentConfig` template by hand, one `.Files.Get` line each.

## Check a template locally

```fish
cd kubepave/kubernetes/charts
set d (mktemp -d)
helm template t tenant-templates > $d/env.yaml
crossplane render <xr.yaml> <composition.yaml> <functions.yaml> --extra-resources=$d/env.yaml
```

The crossplane chart has an unbuilt subchart dependency, so render its Composition from a copy of the chart with that dependency removed from `Chart.yaml`.
