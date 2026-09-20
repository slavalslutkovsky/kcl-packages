# function-package-registry

The Crossplane composition function behind `packages/cloud/package-registry`:
it turns one `PackageRegistry` XR (`cloud.example.org/v1alpha1`) into the
registry resources of one backend, for OCI containers **and** language package
managers.

The Compositions are all the same two-step pipeline and differ only in the
function input:

```yaml
- step: render
  functionRef: {name: function-package-registry}
  input:
    apiVersion: packageregistry.fn.example.org/v1beta1
    kind: Input
    backend: gcp      # aws | gcp | azure | zot | forgejo
- step: ready
  functionRef: {name: function-auto-ready}
```

## Backend support matrix

| backend | oci | npm | pypi | maven | go | cargo | nuget | generic | composed resources |
|---|---|---|---|---|---|---|---|---|---|
| gcp | DOCKER | NPM | PYTHON | MAVEN | GO | — | — | GENERIC | one `RegistryRepository` per format (+ `RegistryRepositoryIAMMember` per format when public) |
| aws | ECR | CA | CA | CA | — | CA | CA | CA | ECR `Repository` (+ `LifecyclePolicy`, `RepositoryPolicy`); one CodeArtifact `Domain` + one `Repository` for every language format |
| azure | ACR | — | — | — | — | — | — | — | one `Registry` |
| zot | yes | — | — | — | — | — | — | — | one provider-helm `Release` (zot chart) |
| forgejo | yes | yes | yes | yes | yes | yes | yes | yes | one provider-helm `Release` (Forgejo chart) |

A `spec.formats` entry a backend cannot serve is a `SEVERITY_FATAL` function
result naming the format — never a silently dropped repository.

## Development

```
just pkgreg-test                 # ruff + unit tests
just pkgreg-serve                # serve :9443 for `crossplane render`
just pkgreg-render gcp           # render an example against the served function
just pkgreg-image                # build the runtime image
just pkgreg-install              # image -> kind nodes, xpkg -> local registry
```
