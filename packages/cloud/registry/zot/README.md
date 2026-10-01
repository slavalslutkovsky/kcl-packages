# registry-zot

In-cluster backend for the `Registry` XR (`cloud.example.org/v1alpha1`): no
cloud account, no IAM. Typed against the `helm` schema package
(`../../../providers/helm`), it renders one namespaced provider-helm `Release`
that installs the zot chart (CNCF OCI-native
registry) into the XR's namespace, so a client that pushes to ECR, Artifact
Registry or ACR pushes here unchanged. The Composition `registry-zot` runs it
through `function-kcl` from `oci://docker.io/yurikrupnik/registry-zot`,
followed by `function-auto-ready`.

Needs provider-helm v1.x (namespaced `helm.m.crossplane.io` CRDs) and the
`default` `ClusterProviderConfig`, both shipped in
[../xrd/providers.yaml](../xrd/providers.yaml) and
[../xrd/providerconfigs.yaml](../xrd/providerconfigs.yaml).

## Composed resources

| resource | when | notes |
| --- | --- | --- |
| `Release` (`helm.m.crossplane.io`) | always | chart `zot` from `https://zotregistry.dev/helm-charts`, pinned in `registry.k`; `crossplane.io/external-name` and `fullnameOverride` are the XR name; `providerConfigRef: ClusterProviderConfig/default`; `wait: true`, `waitTimeout: 10m` |

Chart values: ClusterIP service on port 5000, `persistence: true` with a PVC
(the chart then runs a StatefulSet), and a generated `config.json` mounted via
`configFiles`. The config always enables storage `dedupe` and `gc`
(`gcDelay: 1h`); retention policies act only through the garbage collector.

## Spec fields read

Full schema: [../xrd/xrd.yaml](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `metadata.namespace` | Release target namespace (default `default`) |
| `storageGb` | PVC size `<n>Gi` (default `8`) |
| `untaggedRetentionDays` | `storage.retention` policy `deleteUntagged: true` with `delay: <days*24>h` |
| `keepLastImages` | `storage.retention` policy `keepTags: [{patterns: [".*"], mostRecentlyPushedCount}]` |
| `scanOnPush` | `extensions.search` with CVE scanning (`updateInterval: 2h`) (default `true`) |
| `htpasswdSecret` | Secret mounted at `/secret` via `externalSecrets`; `http.auth.htpasswd.path: /secret/htpasswd`, plus an access-control policy granting authenticated users read/create/update/delete |
| `publicAccess` | anonymous `read` in that access-control policy; only takes effect with `htpasswdSecret` |
| `deletionPolicy` | `Orphan` sets `managementPolicies: [Observe, Create, Update, LateInitialize]` |
| `tags` | chart `podLabels` |

Without `htpasswdSecret`, zot serves anonymous read/write, reachable only
in-cluster (ClusterIP, no ingress). Ignored: `region`, `tier`,
`resourceGroup`, `immutableTags`, `encryptionKeyId`,
`encryptionIdentityClientId`, `replicationRegions`, `forceDestroy`.

Status written back: `provider: zot`, `ready` (Release `state: deployed`),
`registryName`, and, deterministic from the release name before observation,
`endpoint` (`<name>.<namespace>.svc.cluster.local:5000`), `repository`
(`<endpoint>/<name>`), `url` (`oci://…`), `cloud-url`
(`kubernetes://<namespace>/statefulset/<name>`). `authSecret` when
`htpasswdSecret` is set; `id` (`<namespace>/<name>@<revision>`) once a revision
is observed.

## Usage

Without `option("params")`, `main.k` renders a built-in example XR
(`metadata.name: example`):

```bash
kcl run packages/cloud/registry/zot
```

Pass a real XR the way `function-kcl` does, as `params.oxr`:

```bash
kcl run packages/cloud/registry/zot \
  -D params="{\"oxr\": $(yq -o json -I0 packages/cloud/registry/xrd/examples/registry-zot.yaml)}"
```

`pnpm exec nx run registry-zot:render` runs `crossplane render` against
`../xrd/examples/registry-zot.yaml` (needs the Crossplane CLI and docker).
On a cluster: `just install-module registry` installs the XRD and every
backend Composition; `just e2e registry` runs the full kind e2e.

## Layout

| file | content |
| --- | --- |
| `main.k` | `params` / built-in example XR; `items` = `render` + `status` |
| `registry.k` | `render`, `status`, `config_json`, chart pin, `service_host` |
| `registry_test.k` | `kcl test` cases |
| `composition.yaml` | Crossplane `Composition` `registry-zot` |

## Development

```bash
pnpm exec nx run registry-zot:test     # kcl test
pnpm exec nx run registry-zot:lint     # kcl lint
pnpm exec nx run registry-zot:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
