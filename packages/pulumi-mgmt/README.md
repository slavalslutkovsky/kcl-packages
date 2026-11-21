# pulumi-mgmt

The infra repo's mgmt Pulumi stack (`apps/mgmt/index.ts`, `src/flux.ts`) as
data: a stack file in, a spec of every resource the program declares out, as
YAML or JSON.

```sh
just pulumi-mgmt                                         # YAML to stdout
just pulumi-mgmt ../infra/apps/mgmt/Pulumi.prod.yaml json mgmt.json
kcl run packages/pulumi-mgmt -D values=<Pulumi.<stack>.yaml> [--format json] [-o <file>]
```

## Input

A `Pulumi.<stack>.yaml`, read the way `pulumi.Config` reads it: `gcp:region`,
`org:*` (with `packages/org-config`'s shape checks) and `<project>:*` (`-D
project=`, default `mgmt`), every key with index.ts's default. Strings become
the types the program asks for (`getBoolean`, `getNumber`); an unknown
`mgmt:` key fails the render instead of being ignored. `<stack>` comes from the
file name unless `-D stack=` sets it. With no `-D values` a demo stack (placeholder
organization) renders, which is what `nx build pulumi-mgmt` runs.

## Output

| key | what |
| --- | --- |
| `config` | the resolved, typed stack config |
| `variables` | values computed from outputs, as Pulumi YAML builtins (`fn::select`/`fn::split` for the subnet names) |
| `resources` | map key → `{type, name, properties, options}` |
| `fluxBootstrap` | the `bootstrapFlux(args, opts)` call, only with `mgmt:fluxBootstrap: "true"` |
| `outputs` | the stack exports |

- `type` is the canonical Pulumi type token, the one in the URN
  (`gcp:projects/iAMMember:IAMMember`); the infra components keep theirs
  (`org:gcp-gke:GkeCluster`, `org:gcp-apis:EnableApis`,
  `app:db:PostgresInstance`, `app:db:PostgresDatabase`).
- `name` is the logical name index.ts passes, so a program built from the spec
  produces the same URNs and adopts the stack's state without replacements.
  Map keys are index.ts's variable names (`project`, `gke`, `nodeSa`, ...) or,
  where it has none, the logical name.
- `properties` are that type's Args: `gcp.organizations.ProjectArgs`,
  `GkeClusterArgs`, `PostgresInstanceArgs`, `FluxBootstrapArgs`. lib.k types
  them: a field the Args type lacks, a value outside its union, or a broken
  constructor check (an all-tainted node pool) fails the render.
- References are Pulumi YAML interpolations of map keys: `${project.projectId}`,
  `${network.outputs["networkHosts"]["mgmt"]["subnet"]}`, `dependsOn:
  ["${apis}"]`.

It is not a runnable Pulumi YAML program: Pulumi YAML cannot load the infra
repo's TypeScript components, and `bootstrapFlux` parses JSON out of Secret
Manager, which no Pulumi YAML builtin does. A consumer maps each `type` to its
class (`gcp.projects.IAMMember`, `GkeCluster`) and resolves the references.

## Keeping it in step with index.ts

lib.k mirrors index.ts by hand: a resource added there must be added to
`render`, with the same logical name. Check it against the stack's state:

```sh
just pulumi-mgmt ../infra/apps/mgmt/Pulumi.prod.yaml json /tmp/spec.json
(cd ../infra/apps/mgmt && pulumi stack export --stack prod --file /tmp/state.json)
comm -13 <(jq -r '.resources[] | "\(.type) \(.name)"' /tmp/spec.json | sort) \
  <(jq -r '.deployment.resources[] | select((.parent // "") | test("pulumi:pulumi:Stack::")) | "\(.type) \(.urn | split("::") | last)"' /tmp/state.json | sort)
```

No output: every resource in state is in the spec.
