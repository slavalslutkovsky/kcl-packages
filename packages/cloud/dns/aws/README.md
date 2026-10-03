# dns-aws

AWS backend for the `DnsZone` XR (`cloud.example.org/v1alpha1`): a public
Route53 hosted zone plus one record set per `spec.records[]` entry. Typed
against the vendored `aws-route53` schema package
([../../../providers/aws-route53](../../../providers/aws-route53)). The
`dns-aws` Composition runs it through `function-kcl` from
`oci://docker.io/yurikrupnik/dns-aws`, followed by `function-auto-ready`.

## Composed resources

| resource (API group) | when | notes |
| --- | --- | --- |
| `Zone` (`route53.aws.m.upbound.io`) | always | composition-resource-name `managed`; `forProvider.name` = `spec.domain`, comment `DnsZone <xr> (managed by Crossplane)`. Route53 creates and manages the apex NS/SOA itself |
| `Record` (`route53.aws.m.upbound.io`) | one per `spec.records[]` entry | binds the zone with `zoneIdSelector.matchControllerRef`, so it waits for the zone instead of racing it. Resource name `record-<name>-<type>` (see below) |

Record resource names are lowercased; `@`/`""` become `apex`, `*` becomes
`wildcard`, anything else outside `[a-z0-9-]` becomes `-`
(`*.dev` CNAME → `record-wildcard-dev-cname`). The same rule lives in
[../gcp/](../gcp/); keep them in lockstep.

## Spec fields read

Full schema: [../xrd/xrd.yaml](../xrd/xrd.yaml).

| field | maps to |
| --- | --- |
| `domain` | `Zone.forProvider.name`; record names are made FQDN against it (`api` → `api.example.com`, `@`/`""` → `example.com`, wildcards pass through) |
| `records[].name` / `.type` | `Record.forProvider.name` / `.type` |
| `records[].ttl` | `Record.forProvider.ttl`, `300` when unset |
| `records[].values` | `Record.forProvider.records`, verbatim: MX/SRV priorities stay inline, TXT gets no extra quoting |
| `deletionPolicy` | `Orphan` → `managementPolicies: [Observe, Create, Update, LateInitialize]` on every MR; otherwise the schema default `['*']` |
| `tags` | `Zone.forProvider.tags` only; Route53 records carry no tags |
| `region` | ignored: Route53 is global and neither model has `forProvider.region` |

Status written back to the XR (from the `managed` zone's `atProvider`):

| status | value |
| --- | --- |
| `provider` | `aws` |
| `ready` | `true` once the zone reports `nameServers` |
| `nameServers` | delegation set to put at the registrar; `[]` until observed |
| `zoneId` | `atProvider.zoneId`, else `atProvider.id`; absent until observed |
| `cloud-url` | Route53 console link for `zoneId`; absent until observed |
| `arn`, `id` | copied when observed |

## Usage

Without `option("params")`, `main.k` renders a built-in example XR
(`example.com`, one apex `A` record):

```bash
kcl run packages/cloud/dns/aws
```

`-D params=` takes the function-kcl input as JSON (`{"oxr": <XR>, "ocds": {…}}`;
`ocds` may be omitted), so a real XR renders like this:

```bash
kcl run packages/cloud/dns/aws \
    -D params="$(yq -o json -I0 '{"oxr": .}' packages/cloud/dns/xrd/examples/dns-aws.yaml)"
```

Through `crossplane render` against the working tree (needs `crossplane` and
docker; defaults to [../xrd/examples/dns-aws.yaml](../xrd/examples/dns-aws.yaml)):

```bash
pnpm exec nx run dns-aws:render
```

On a cluster: `just e2e dns` (Kind, Crossplane, local registry,
providers, examples), or `just install-module dns` to apply the XRD and both
Compositions repointed at the local registry.

## Layout

| file | content |
| --- | --- |
| `main.k` | entrypoint: reads `option("params")`, falls back to `_example`, emits `render` + `status` |
| `dns.k` | `render` (Zone + Records), `status`, name helpers `sanitize` / `res_name` / `fqdn` |
| `composition.yaml` | `dns-aws` Composition (`provider: aws` label) |

## Development

```bash
pnpm exec nx run dns-aws:lint     # kcl lint
pnpm exec nx run dns-aws:render   # crossplane render (docker)
```

`version` in `kcl.mod` is bumped by `nx release` in CI; do not edit it by hand.
