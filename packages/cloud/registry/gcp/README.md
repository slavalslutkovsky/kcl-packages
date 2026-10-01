# registry-gcp

GCP backend for the `Registry` XR (`cloud.example.org/v1alpha1`). Typed
against the `gcp-artifact` schema package (`../../../providers/gcp-artifact`),
it maps the portable registry onto one Artifact Registry repository in
`DOCKER` format, plus an IAM member when anonymous pull is asked for.
Retention uses the repository's own cleanup policies, so no extra MR is
needed. The Composition `registry-gcp` runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/registry-gcp`, followed by `function-auto-ready`.

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `RegistryRepository` (`artifact.gcp.m.upbound.io`) | always | `format: DOCKER`, `mode: STANDARD_REPOSITORY`; `crossplane.io/external-name` pins the repository id to the XR name |
| `RegistryRepositoryIAMMember` (`artifact.gcp.m.upbound.io`) | `publicAccess: true` | `allUsers` → `roles/artifactregistry.reader`; bound by repository name (the XR name), not by selector |

## Spec fields read

Full schema: [../xrd/xrd.yaml](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `region` | `location` on both MRs |
| `immutableTags` | `dockerConfig.immutableTags` (default `false`) |
| `scanOnPush` | `vulnerabilityScanningConfig.enablementConfig`: `INHERITED` (follow the project setting) / `DISABLED` (default `true`) |
| `untaggedRetentionDays` | cleanup policy `delete-untagged`: `DELETE`, `tagState: UNTAGGED`, `olderThan: <days*86400>s` |
| `keepLastImages` | cleanup policy `keep-recent`: `KEEP`, `mostRecentVersions.keepCount` |
| `encryptionKeyId` | `kmsKeyName` |
| `publicAccess` | `RegistryRepositoryIAMMember` |
| `deletionPolicy` | `Orphan` sets `managementPolicies: [Observe, Create, Update, LateInitialize]` on both MRs |
| `tags` | `forProvider.labels` |

With any cleanup policy present, `cleanupPolicyDryRun: false`. Ignored:
`tier`, `resourceGroup`, `encryptionIdentityClientId`, `replicationRegions`,
`forceDestroy`, `storageGb`, `htpasswdSecret`.

Status written back: `provider: gcp`, `ready` (id observed), `registryName`,
`region`, `endpoint` (`<location>-docker.pkg.dev`, known before observation),
`cloud-url`, `id`. `repository` and `url` need the project, which the XR does
not carry; they appear once it can be parsed from the observed id
(`projects/<project>/locations/…`).

## Usage

Without `option("params")`, `main.k` renders a built-in example XR
(`region: us-central1`):

```bash
kcl run packages/cloud/registry/gcp
```

Pass a real XR the way `function-kcl` does, as `params.oxr`:

```bash
kcl run packages/cloud/registry/gcp \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/registry/xrd/examples/registry-gcp.yaml)}"
```

`pnpm exec nx run registry-gcp:render` runs `crossplane render` against
`../xrd/examples/registry-gcp.yaml` (needs the Crossplane CLI and docker).
On a cluster: `just install-module registry` installs the XRD and every
backend Composition; `just e2e registry` runs the full kind e2e.

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / built-in example XR; `items` = `render` + `status` |
| `registry.k` | `render`, `status`, `docker_host`, `project_of` |
| `registry_test.k` | `kcl test` cases |
| `composition.yaml` | Crossplane `Composition` `registry-gcp` |

## Development

```bash
pnpm exec nx run registry-gcp:test     # kcl test
pnpm exec nx run registry-gcp:lint     # kcl lint
pnpm exec nx run registry-gcp:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
