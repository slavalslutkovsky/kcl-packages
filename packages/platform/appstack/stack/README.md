# appstack

The only backend for the `AppStack` XR (`platform.example.org/v1alpha1`,
Composition `appstack`). A composite of composites: instead of managed
resources it emits five child XRs in `cloud.example.org/v1alpha1` — a
`Network`, two `ServerlessApp`s, a `PostgresInstance` and a `RedisInstance` —
and wires them together from their observed status. Each capability keeps its
own cloud mapping. No `[dependencies]`: the children are untyped dicts their
own XRDs validate. Run by `function-kcl` from
`oci://docker.io/yurikrupnik/appstack`.

## Composed resources

| resource (API group) | composition-resource-name | name | notes |
| --- | --- | --- | --- |
| `Network` (`cloud.example.org`) | `network` | `<name>-net` | `cidr` default `10.0.0.0/16`, `natGateway` default `true` |
| `ServerlessApp` (`cloud.example.org`) | `api` | `<name>-api` | `public: true` |
| `ServerlessApp` (`cloud.example.org`) | `worker` | `<name>-worker` | `public: false` |
| `PostgresInstance` (`cloud.example.org`) | `database` | `<name>-db` | `database` / `username` default `app` |
| `RedisInstance` (`cloud.example.org`) | `cache` | `<name>-cache` | |

All five are always rendered. Every child gets the stack-wide `region`,
`deletionPolicy` (default `Delete`), `tags`, and
`crossplane.compositionSelector.matchLabels.provider: <spec.provider>`, so all
five resolve to the same cloud.

Wiring from observed child status (absent on the first reconcile):

| from | to | aws | gcp |
| --- | --- | --- | --- |
| Network | `PostgresInstance.spec.network` | `subnetGroupName` (from `dbSubnetGroupName`) + `securityGroupIds`, only once both are published | `id` = Network `selfLink`, falling back to `id` |
| Network | `RedisInstance.spec.network` | `subnetGroupName` (from `cacheSubnetGroupName`) + `securityGroupIds`, same rule | `id` as above + `reservedIpRange` = Network `serviceRange` |
| PostgresInstance, RedisInstance | both apps' `env` | `DATABASE_{HOST,PORT,NAME,USER,URL,PASSWORD_SECRET,PASSWORD_SECRET_KEY}`, `REDIS_{HOST,PORT,URL,AUTH_SECRET,AUTH_SECRET_KEY}` | same |

Each variable appears only once the child has published the value, and the
injected set overrides the user's `env`. Only Secret names and keys are passed,
never secret material.

## Spec fields read

Full schema: [`../xrd/xrd.yaml`](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `provider` | `aws` or `gcp`; every child's composition selector, and which placement shape is built |
| `region`, `deletionPolicy`, `tags` | copied onto all five children |
| `network.{cidr,natGateway,availabilityZones,serviceRange}` | Network spec; `availabilityZones` is required by the aws Network backend, `serviceRange` is gcp-only |
| `api`, `worker` | ServerlessApp `image`, `port` (default 8080), `env`, `serviceAccount`; `cpu`, `memoryMb`, `minInstances`, `maxInstances`, `timeoutSeconds` only when set, so the ServerlessApp defaults apply otherwise |
| `database.{name,username}` | PostgresInstance `database`, `username` |
| `database.{engineVersion,memoryGb,storageGb,highAvailability,snapshotRetentionDays,passwordSecret}` | PostgresInstance spec, only when set |
| `cache.{engineVersion,memoryGb,replicas,highAvailability,authEnabled}` | RedisInstance spec, only when set |

Status written back: `provider`, `ready` (all five children ready),
`components.{network,api,worker,database,cache}`, and, once published,
`apiUrl`, `workerUrl`, `databaseEndpoint`, `databaseUrl`, `cacheEndpoint`,
`cacheUrl`, `networkId` — copied from the children, never recomputed.

## Usage

`main.k` renders `render(oxr, ocds) + [status(oxr, ocds)]` under `items`.
Without `option("params")` it uses the built-in `_example` (gcp,
`us-central1`) and renders the unwired first pass:

```bash
kcl run packages/platform/appstack/stack
```

Pass a real XR the way function-kcl does (add `"ocds"` to see the wiring):

```bash
kcl run packages/platform/appstack/stack \
  -D params="{\"oxr\": $(yq -o=json -I=0 packages/platform/appstack/xrd/examples/appstack-aws.yaml)}"
```

`pnpm exec nx run appstack:render` (or `just render appstack`) renders
`composition.yaml` through function-kcl against the first `appstack-*.yaml`
example; `--example appstack-gcp` picks the other. Needs docker.

In a cluster (needs docker/kind): `just e2e appstack` publishes the package,
installs the XRD and Composition and applies the examples;
`just install-module appstack` applies only the XRD and the Composition,
repointed at the local registry. The module ships no providers: the children
only resolve once their own modules (`network`, `serverless`, `postgres`,
`redis`) are installed.

## Layout

| file | content |
| --- | --- |
| `main.k` | entrypoint: reads `option("params")`, falls back to `_example` |
| `appstack.k` | `render` (five child XRs and their wiring) and `status` |
| `appstack_test.k` | `kcl test` cases |
| `composition.yaml` | Composition running this package through function-kcl |

## Development

```bash
pnpm exec nx run appstack:test     # kcl test
pnpm exec nx run appstack:lint     # kcl lint
pnpm exec nx run appstack:render   # function-kcl render of composition.yaml (needs docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
