
# xr-types

Shared Go types for Crossplane composite resource (XR) schemas.
Each subdirectory is an independent Go module consumed by the functions in this repository.

| Module | Path |
|---|---|
| `tenant` | `github.com/rezakaramad/kubepave/src/crossplane/xr-types/tenant` |

## How it works

Modules here are published via **git tags** only — there is no build artifact.
The Go module proxy resolves the tag directly from this repository.

CI runs `go build`, `go vet`, and `go test` automatically on every push to `main`
that touches `src/crossplane/xr-types/`, and again when a release tag is pushed.

## Releasing a new version

1. Merge your changes to `main`.
2. Tag the commit and push:

```sh
git tag src/crossplane/xr-types/tenant/v0.2.0
git push origin src/crossplane/xr-types/tenant/v0.2.0
```

CI will run the verification suite against the tag.

3. Update consumers (`go.mod` in any function that depends on this module):

```sh
cd src/crossplane/function-tenant-renderer
GOWORK=off go get github.com/rezakaramad/kubepave/src/crossplane/xr-types/tenant@v0.2.0
GOWORK=off go mod tidy
```

Repeat for any other function, then commit the updated `go.mod` / `go.sum` files.
